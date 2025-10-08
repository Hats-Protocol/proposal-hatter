// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IHats } from "../lib/hats-protocol/src/Interfaces/IHats.sol";
import { HatsIdUtilitiesAbridged as HatsIdUtilities } from "./lib/HatsIdUtilitiesAbridged.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { Strings } from "../lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IMulticallable } from "./interfaces/IMulticallable.sol";
import { EfficientHashLib } from "../lib/solady/src/utils/EfficientHashLib.sol";
import {
  IProposalHatter,
  IProposalHatterErrors,
  IProposalHatterEvents,
  IProposalHatterTypes
} from "./interfaces/IProposalHatter.sol";
import { ModuleManager } from "../lib/safe-smart-account/contracts/base/ModuleManager.sol";
import { Enum } from "../lib/safe-smart-account/contracts/common/Enum.sol";

/// @title ProposalHatter
/// @notice Minimal executor and funding gate for Hats-managed proposals using Safe module execution for withdrawals.
/// @dev This implementation assumes all relevant hats live within a single Hats tree branch.
/// Linked tree topologies are not supported; branch membership checks rely on
/// local-level hat utilities and will not traverse linkedTreeAdmins.
///
/// OPERATIONAL ASSUMPTIONS (must be satisfied and maintained during operation):
/// 1. ProposalHatter MUST be an admin of `APPROVER_BRANCH_ID` to create per-proposal approver ticket hats
/// 2. ProposalHatter MUST be an admin of `OPS_BRANCH_ID` (if configured) to create and toggle reserved hats
/// 3. ProposalHatter MUST be enabled as a module on the Safe to execute withdrawals
/// 4. The provided `APPROVER_BRANCH_ID` and `OPS_BRANCH_ID` (if non-zero) MUST be valid, existing hat IDs
/// 5. Role hat IDs (`proposerHat`, `executorHat`, `escalatorHat`) MUST be valid when set, or operations will fail
/// 6. If ProposalHatter loses admin rights over branch IDs, proposal creation and hat toggling will fail
/// 7. If Safe owners disable ProposalHatter as a module, withdrawals will fail (allowances remain intact)
///
/// ALLOWANCE CONSTRAINTS (uint88 type limits):
/// - Maximum allowance per (safe, recipientHat, token): type(uint88).max = ~3.09 × 10^26 wei
/// - For 18-decimal tokens (ETH, DAI): ~309 million tokens maximum
/// - For 6-decimal tokens (USDC, USDT): ~309 quadrillion tokens maximum
/// - Cumulative allowances across multiple proposals to the same recipient can accumulate
/// - If total allowance would exceed type(uint88).max, execute() reverts (protective, not exploitable)
/// - This limit is sufficient for all realistic DAO treasury operations
///
/// SECURITY PROPERTIES:
/// - Each proposal's allowance is bound to the Safe address at proposal-time (stored in ProposalData.safe)
/// - Changing the global `safe` via setSafe() does NOT affect existing proposal allowances
/// - Withdrawals require exact Safe parameter match to allowance ledger (multi-Safe support)
/// - Front-running prevention: proposalId includes submitter address, chainid, and this contract address
/// - Atomicity: Hats multicall failure reverts entire execution; no partial allowance grants
/// - Reentrancy protection on execute() and withdraw() via nonReentrant modifier
contract ProposalHatter is ReentrancyGuard, IProposalHatter, HatsIdUtilities {
  // --------------------
  // Internal Constants
  // --------------------

  // Public sentinel for indicating "no hat required" for a role
  uint256 internal constant PUBLIC_SENTINEL = 1; // never a valid Hats ID
  // Sentinel non-zero address for Hats modules (eligibility/toggle)
  address internal constant EMPTY_SENTINEL = address(1);
  // keccak256("Proposed(bytes32,bytes32,address,uint256,address,uint32,address,uint256,uint256,uint256,bytes32)")
  bytes32 private constant _PROPOSED_EVENT_SIGNATURE =
    0xf6d1b6d79196970a10149b547ab0f6c675ce1d689f3afc40834aea929244437d;

  // --------------------
  // Storage
  // --------------------

  /// @inheritdoc IProposalHatter
  address public immutable HATS_PROTOCOL_ADDRESS;
  /// @inheritdoc IProposalHatter
  uint256 public immutable APPROVER_BRANCH_ID;
  /// @inheritdoc IProposalHatter
  uint256 public immutable OPS_BRANCH_ID;
  /// @inheritdoc IProposalHatter
  address public safe;
  /// @inheritdoc IProposalHatter
  uint256 public proposerHat;
  /// @inheritdoc IProposalHatter
  uint256 public executorHat; // PUBLIC_SENTINEL => public execution
  /// @inheritdoc IProposalHatter
  uint256 public escalatorHat;
  /// @inheritdoc IProposalHatter
  uint256 public immutable OWNER_HAT;
  /// @inheritdoc IProposalHatter
  bool public proposalsPaused;
  /// @inheritdoc IProposalHatter
  bool public withdrawalsPaused;

  /// @inheritdoc IProposalHatter
  mapping(bytes32 proposalId => IProposalHatter.ProposalData proposal) public proposals;

  // Internal ledger: remaining allowance by recipient hat and token.
  // @custom-member safe The address of the Safe for which this allowance is valid.
  // @custom-member recipientHatId The recipient hat ID.
  // @custom-member fundingToken The token address (address(0) for ETH).
  // @custom-member allowanceRemaining The allowance amount in wei.
  mapping(address safe => mapping(uint256 recipientHatId => mapping(address fundingToken => uint88 allowanceRemaining)))
    internal _allowanceRemaining;

  // events are imported from IProposalHatter
  // --------------------
  // Constructor
  // --------------------
  /// @notice Initializes external dependencies and role hats for ProposalHatter.
  /// @param hatsProtocol The Hats Protocol core contract address.
  /// @param safe_ The DAO Safe that custodians funds.
  /// @param ownerHatId The Owner Hat ID authorized for admin functions.
  /// @param proposerHatId The Proposer Hat ID required to propose.
  /// @param executorHatId The Executor Hat ID. Set to PUBLIC_SENTINEL (1) to allow public execution.
  /// @param escalatorHatId The Escalator Hat ID allowed to escalate.
  /// @param approverBranchId_ Branch root/admin for per-proposal approver ticket hats.
  /// @param opsBranchId_ Branch root used for reserved hat validation (ancestor of reserved hat parent).
  constructor(
    address hatsProtocol,
    address safe_,
    uint256 ownerHatId,
    uint256 proposerHatId,
    uint256 executorHatId,
    uint256 escalatorHatId,
    uint256 approverBranchId_,
    uint256 opsBranchId_
  ) {
    // Ensure key addresses are non-empty
    if (hatsProtocol == address(0) || safe_ == address(0) || ownerHatId == 0) {
      revert IProposalHatterErrors.ZeroAddress();
    }

    // Set the immutable storage
    HATS_PROTOCOL_ADDRESS = hatsProtocol;
    OWNER_HAT = ownerHatId;
    APPROVER_BRANCH_ID = approverBranchId_;
    OPS_BRANCH_ID = opsBranchId_;

    // Set the public storage
    safe = safe_;
    proposerHat = proposerHatId;
    executorHat = executorHatId;
    escalatorHat = escalatorHatId;

    // Log the deployment
    emit ProposalHatterDeployed(hatsProtocol, ownerHatId, approverBranchId_, opsBranchId_);
    emit ProposerHatSet(proposerHatId);
    emit EscalatorHatSet(escalatorHatId);
    emit ExecutorHatSet(executorHatId);
    emit SafeSet(safe_);
  }

  // --------------------
  // Proposal Lifecycle
  // --------------------

  /// @inheritdoc IProposalHatter
  function propose(
    uint88 fundingAmount_,
    address fundingToken_,
    uint32 timelockSec_,
    uint256 recipientHatId_,
    uint256 reservedHatId_,
    bytes calldata hatsMulticall,
    bytes32 salt
  ) external returns (bytes32 proposalId) {
    // Only callable when proposals are not paused
    _checkProposalsPaused();

    // Only callable by the Proposer
    _checkAuth(proposerHat);

    // Get the Safe address
    address safe_ = safe;

    // Compute the proposal ID
    proposalId = _computeProposalId(
      msg.sender, fundingAmount_, fundingToken_, timelockSec_, safe_, recipientHatId_, hatsMulticall, salt
    );

    // New proposals must be unique
    if (proposals[proposalId].state != IProposalHatterTypes.ProposalState.None) {
      revert IProposalHatterErrors.AlreadyUsed(proposalId);
    }

    // Create per-proposal approver ticket hat under approverBranchId
    uint256 approverHatId_ = IHats(HATS_PROTOCOL_ADDRESS).createHat(
      APPROVER_BRANCH_ID, Strings.toHexString(uint256(proposalId), 32), 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, ""
    );

    // Optionally create the reserved hat with exact id
    if (reservedHatId_ != 0) _createReservedHat(reservedHatId_, proposalId);

    // Store the proposal
    proposals[proposalId] = IProposalHatterTypes.ProposalData({
      submitter: msg.sender,
      fundingAmount: fundingAmount_,
      state: IProposalHatterTypes.ProposalState.Active,
      fundingToken: fundingToken_,
      eta: 0,
      timelockSec: timelockSec_,
      safe: safe_,
      recipientHatId: recipientHatId_,
      approverHatId: approverHatId_,
      reservedHatId: reservedHatId_,
      hatsMulticall: hatsMulticall
    });

    // // Log the proposal
    // emit IProposalHatterEvents.Proposed(
    //   proposalId,
    //   EfficientHashLib.hash(hatsMulticall),
    //   msg.sender,
    //   fundingAmount_,
    //   fundingToken_,
    //   timelockSec_,
    //   safe_,
    //   recipientHatId_,
    //   approverHatId_,
    //   reservedHatId_,
    //   salt
    // );

    // Log the proposal without re-introducing stack pressure
    // TODO remove this once we decide how to handle stack too deep errors with the above vanilla emit
    bytes32 hatsMulticallHash = EfficientHashLib.hash(hatsMulticall);
    assembly {
      let dataPtr := mload(0x40)
      mstore(dataPtr, fundingAmount_)
      mstore(add(dataPtr, 0x20), and(fundingToken_, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
      mstore(add(dataPtr, 0x40), timelockSec_)
      mstore(add(dataPtr, 0x60), and(safe_, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
      mstore(add(dataPtr, 0x80), recipientHatId_)
      mstore(add(dataPtr, 0xa0), approverHatId_)
      mstore(add(dataPtr, 0xc0), reservedHatId_)
      mstore(add(dataPtr, 0xe0), salt)
      mstore(0x40, add(dataPtr, 0x100))
      log4(
        dataPtr,
        0x100,
        _PROPOSED_EVENT_SIGNATURE,
        proposalId,
        hatsMulticallHash,
        and(caller(), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
      )
    }
  }

  /// @inheritdoc IProposalHatter
  function approve(bytes32 proposalId) external {
    // Only callable when proposals are not paused
    _checkProposalsPaused();

    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Only active proposals can be approved
    if (p.state != IProposalHatterTypes.ProposalState.Active) revert IProposalHatterErrors.InvalidState(p.state);
    // Must wear per-proposal approver hat
    if (!IHats(HATS_PROTOCOL_ADDRESS).isWearerOfHat(msg.sender, p.approverHatId)) {
      revert IProposalHatterErrors.NotAuthorized();
    }

    // Set the ETA as now + timelockSec
    uint64 eta = uint64(block.timestamp) + p.timelockSec;
    p.eta = eta;

    // Advance the proposal state to Approved
    p.state = IProposalHatterTypes.ProposalState.Approved;

    // Log the approval
    emit IProposalHatterEvents.Approved(proposalId, msg.sender, eta);
  }

  /// @inheritdoc IProposalHatter
  function execute(bytes32 proposalId) external nonReentrant {
    // Only callable when proposals are not paused
    _checkProposalsPaused();

    // Only callable by the Executor (unless execution is public, ie is set to PUBLIC_SENTINEL)
    _checkAuth(executorHat);

    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Proposals are only executable...
    // - if they have state Approved
    // - if current time is after the ETA
    if (p.state != IProposalHatterTypes.ProposalState.Approved) revert IProposalHatterErrors.InvalidState(p.state);
    if (uint64(block.timestamp) < p.eta) revert IProposalHatterErrors.TooEarly(p.eta, uint64(block.timestamp));

    // Execute the proposal
    _execute(p, proposalId);
  }

  /// @inheritdoc IProposalHatter
  function approveAndExecute(bytes32 proposalId) external nonReentrant returns (bytes32 id) {
    // Only callable when proposals are not paused
    _checkProposalsPaused();

    // Only callable by Executor (unless execution is public) and Approver Ticket Hat wearer
    _checkAuth(executorHat);

    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Only callable by Approver Ticket Hat wearer
    if (!IHats(HATS_PROTOCOL_ADDRESS).isWearerOfHat(msg.sender, p.approverHatId)) {
      revert IProposalHatterErrors.NotAuthorized();
    }

    // Proposals can only be approved and executed atomically...
    // - if they are Active
    // - when there is no timelock
    IProposalHatter.ProposalState state = p.state;
    if (state != IProposalHatterTypes.ProposalState.Active) revert IProposalHatterErrors.InvalidState(state);
    uint64 nowTs = uint64(block.timestamp);
    uint32 timelockSec = p.timelockSec;
    if (timelockSec != 0) revert IProposalHatterErrors.TooEarly(nowTs + timelockSec, nowTs);

    // Log the approval
    uint64 eta = nowTs;
    p.eta = eta;
    emit IProposalHatterEvents.Approved(proposalId, msg.sender, eta);

    // Execute the proposal
    _execute(p, proposalId);
    return proposalId;
  }

  /// @inheritdoc IProposalHatter
  function escalate(bytes32 proposalId) external {
    // Only callable by the Escalator
    _checkAuth(escalatorHat);

    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Proposals can only be escalated when Active or Approved
    if (p.state != IProposalHatterTypes.ProposalState.Active && p.state != IProposalHatterTypes.ProposalState.Approved)
    {
      revert IProposalHatterErrors.InvalidState(p.state);
    }

    // Set the proposal state to Escalated
    p.state = IProposalHatterTypes.ProposalState.Escalated;

    // Log the escalation
    emit IProposalHatterEvents.Escalated(proposalId, msg.sender);
  }

  /// @inheritdoc IProposalHatter
  function reject(bytes32 proposalId) external {
    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Only callable by Approver Ticket Hat wearer
    _checkAuth(p.approverHatId);

    // Proposals can only be rejected when Active
    if (p.state != IProposalHatterTypes.ProposalState.Active) revert IProposalHatterErrors.InvalidState(p.state);

    // Set the proposal state to Rejected
    p.state = IProposalHatterTypes.ProposalState.Rejected;

    // If it exists, toggle off the reserved hat to clean up
    if (p.reservedHatId != 0) _toggleOffHat(p.reservedHatId);

    // Log the rejection
    emit IProposalHatterEvents.Rejected(proposalId, msg.sender);
  }

  /// @inheritdoc IProposalHatter
  function cancel(bytes32 proposalId) external {
    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Only callable by the original submitter
    if (msg.sender != p.submitter) revert IProposalHatterErrors.NotAuthorized();

    // Proposals can only be canceled when Active or Approved
    if (p.state != IProposalHatterTypes.ProposalState.Active && p.state != IProposalHatterTypes.ProposalState.Approved)
    {
      revert IProposalHatterErrors.InvalidState(p.state);
    }

    // Set the proposal state to Canceled
    p.state = IProposalHatterTypes.ProposalState.Canceled;

    // If it exists, toggle off the reserved hat to clean up
    if (p.reservedHatId != 0) _toggleOffHat(p.reservedHatId);

    // Log the cancellation
    emit IProposalHatterEvents.Canceled(proposalId, msg.sender);
  }

  // --------------------
  // Funding pull (via Safe Module)
  // --------------------

  /// @inheritdoc IProposalHatter
  function withdraw(uint256 recipientHatId_, address safe_, address token, uint88 amount) external nonReentrant {
    // Only callable when withdrawals are not paused
    _checkWithdrawPaused();

    // Only callable by the Recipient Hat wearer
    _checkAuth(recipientHatId_);

    // The caller cannot withdraw more than their remaining allowance
    uint88 rem = _allowanceRemaining[safe_][recipientHatId_][token];
    if (rem < amount) revert IProposalHatterErrors.AllowanceExceeded(rem, amount);

    // Decrement the allowance
    uint88 newAllowance = rem - amount;
    unchecked {
      _allowanceRemaining[safe_][recipientHatId_][token] = newAllowance;
    }

    // Execute the transfer from the Safe, reverting if it fails.
    _execTransferFromSafe(safe_, token, amount);

    // Log the allowance consumption
    emit IProposalHatterEvents.AllowanceConsumed(recipientHatId_, safe_, token, amount, newAllowance, msg.sender);
  }

  // --------------------
  // Admin (Owner Hat)
  // --------------------

  /// @inheritdoc IProposalHatter
  function pauseProposals(bool paused) external {
    // Only callable by Owner Hat wearer
    _checkAuth(OWNER_HAT);

    // Set the pause
    proposalsPaused = paused;

    // Log the pause
    emit IProposalHatterEvents.ProposalsPaused(paused);
  }

  /// @inheritdoc IProposalHatter
  function pauseWithdrawals(bool paused) external {
    // Only callable by Owner Hat wearer
    _checkAuth(OWNER_HAT);

    // Set the pause
    withdrawalsPaused = paused;

    // Log the pause
    emit IProposalHatterEvents.WithdrawalsPaused(paused);
  }

  /// @inheritdoc IProposalHatter
  function setProposerHat(uint256 hatId) external {
    // Only callable by Owner Hat wearer
    _checkAuth(OWNER_HAT);

    // Set the hat
    proposerHat = hatId;

    // Log the setting
    emit IProposalHatterEvents.ProposerHatSet(hatId);
  }

  /// @inheritdoc IProposalHatter
  function setEscalatorHat(uint256 hatId) external {
    // Only callable by Owner Hat wearer
    _checkAuth(OWNER_HAT);

    // Set the hat
    escalatorHat = hatId;

    // Log the setting
    emit IProposalHatterEvents.EscalatorHatSet(hatId);
  }

  /// @inheritdoc IProposalHatter
  function setExecutorHat(uint256 hatId) external {
    // Only callable by Owner Hat wearer
    _checkAuth(OWNER_HAT);

    // Set the hat
    executorHat = hatId;

    // Log the setting
    emit IProposalHatterEvents.ExecutorHatSet(hatId);
  }

  /// @inheritdoc IProposalHatter
  function setSafe(address safe_) external {
    // Only callable by Owner Hat wearer
    _checkAuth(OWNER_HAT);

    // Ensure the Safe address is valid
    if (safe_ == address(0)) revert IProposalHatterErrors.ZeroAddress();

    // Set the safe
    safe = safe_;

    // Log the setting
    emit IProposalHatterEvents.SafeSet(safe_);
  }

  // --------------------
  // Public Getters
  // --------------------

  /// @inheritdoc IProposalHatter
  function allowanceOf(address safe_, uint256 hatId, address token) external view returns (uint88) {
    return _allowanceRemaining[safe_][hatId][token];
  }

  /// @inheritdoc IProposalHatter
  function computeProposalId(
    address submitter_,
    uint88 fundingAmount_,
    address fundingToken_,
    uint32 timelockSec_,
    address safe_,
    uint256 recipientHatId_,
    bytes calldata hatsMulticall,
    bytes32 salt
  ) external view returns (bytes32) {
    return _computeProposalId(
      submitter_, fundingAmount_, fundingToken_, timelockSec_, safe_, recipientHatId_, hatsMulticall, salt
    );
  }

  /// @inheritdoc IProposalHatter
  function getProposalState(bytes32 proposalId) external view returns (IProposalHatterTypes.ProposalState) {
    return proposals[proposalId].state;
  }

  // --------------------
  // Internal Helpers
  // --------------------

  /// @dev Require that msg.sender wears the given hat; hatId=PUBLIC_SENTINEL allows any caller.
  /// @param hatId The required hat ID (PUBLIC_SENTINEL to skip enforcement).
  function _checkAuth(uint256 hatId) internal view {
    // PUBLIC_SENTINEL denotes public access
    if (hatId == PUBLIC_SENTINEL) return;

    // Callers must wear the specified hat to be authorized
    if (!IHats(HATS_PROTOCOL_ADDRESS).isWearerOfHat(msg.sender, hatId)) revert IProposalHatterErrors.NotAuthorized();
  }

  /// @dev Require that proposals are not paused
  function _checkProposalsPaused() internal view {
    if (proposalsPaused) revert IProposalHatterErrors.ProposalsArePaused();
  }

  /// @dev Require that withdrawals are not paused
  function _checkWithdrawPaused() internal view {
    if (withdrawalsPaused) revert IProposalHatterErrors.WithdrawalsArePaused();
  }

  /// @dev Internal helper to compute the deterministic proposalId for the current caller.
  /// @param submitter_ The address that proposed.
  /// @param hatsMulticall ABI-encoded bytes[] for IMulticallable.multicall.
  /// @param fundingAmount_ Funding amount to approve on execute.
  /// @param fundingToken_ Token address (address(0) for ETH).
  /// @param timelockSec_ Per-proposal delay in seconds.
  /// @param safe_ The Safe for which this allowance is valid.
  /// @param recipientHatId_ Recipient hat ID.
  /// @param salt Optional salt for de-duplication.
  function _computeProposalId(
    address submitter_,
    uint88 fundingAmount_,
    address fundingToken_,
    uint32 timelockSec_,
    address safe_,
    uint256 recipientHatId_,
    bytes calldata hatsMulticall,
    bytes32 salt
  ) internal view returns (bytes32) {
    // Pre-hash the dynamic bytes
    bytes32 multicallHash = EfficientHashLib.hash(hatsMulticall);

    // Hash the static tuple with Solady
    return EfficientHashLib.hash(
      bytes32(block.chainid),
      bytes32(uint256(uint160(address(this)))),
      bytes32(uint256(uint160(HATS_PROTOCOL_ADDRESS))),
      bytes32(uint256(uint160(submitter_))),
      bytes32(uint256(fundingAmount_)),
      bytes32(uint256(uint160(fundingToken_))),
      bytes32(uint256(timelockSec_)),
      bytes32(uint256(uint160(safe_))),
      bytes32(recipientHatId_),
      multicallHash,
      salt
    );
  }

  /// @dev Creates a reserved hat with the exact id `reservedHatId_` under the admin hat.
  /// @param reservedHatId_ The id of the reserved hat to create.
  /// @param proposalId The id of the proposal.
  function _createReservedHat(uint256 reservedHatId_, bytes32 proposalId) internal {
    // Get the admin hat of the reserved hat
    uint256 admin = _getAdminHat(reservedHatId_);

    // If opsBranchId is configured, the admin hat (and therefore the reserved hat) must reside within that branch
    if (OPS_BRANCH_ID != 0 && !_isInBranch(admin, OPS_BRANCH_ID)) revert InvalidReservedHatBranch();

    // Prevent index races: ensure the next id under admin matches expectation
    if (IHats(HATS_PROTOCOL_ADDRESS).getNextId(admin) != reservedHatId_) revert InvalidReservedHatId();

    // Create the reserved hat
    uint256 returnedHatId = IHats(HATS_PROTOCOL_ADDRESS).createHat(
      admin, Strings.toHexString(uint256(proposalId), 32), 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, ""
    );

    // Sanity check: ensure the returned hat id matches the input
    if (reservedHatId_ != returnedHatId) revert InvalidReservedHatId();
  }

  /// @dev Internal helper to execute a proposal. Updates the allowance ledger and executes the Hats Protocol multicall.
  /// Does not advance proposal state.
  /// @param p Storage pointer to the proposal.
  /// @param proposalId The proposal ID.
  function _execute(IProposalHatter.ProposalData storage p, bytes32 proposalId) internal {
    // Effects
    // Increase internal allowance ledger
    address safe_ = p.safe;
    uint88 current = _allowanceRemaining[safe_][p.recipientHatId][p.fundingToken];
    uint88 newAllowance = current + p.fundingAmount; // reverts on overflow in ^0.8
    _allowanceRemaining[safe_][p.recipientHatId][p.fundingToken] = newAllowance;

    // Advance the proposal state to Executed
    p.state = IProposalHatterTypes.ProposalState.Executed;

    // Load the hats multicall into memory
    bytes memory hatsMulticall = p.hatsMulticall;

    // Interactions: execute Hats Protocol multicall (skip if funding-only)
    if (hatsMulticall.length > 0) {
      // Delete the hats multicall from storage for some gas savings
      delete p.hatsMulticall;

      // Decode stored bytes into bytes[] expected by Multicallable
      bytes[] memory calls = abi.decode(hatsMulticall, (bytes[]));
      // Execute the multicall. If Hats reverts, the entire tx reverts (atomicity)
      IMulticallable(HATS_PROTOCOL_ADDRESS).multicall(calls);
    }

    // Log the execution with the new allowance
    emit IProposalHatterEvents.Executed(
      proposalId, p.recipientHatId, safe_, p.fundingToken, p.fundingAmount, newAllowance
    );
  }

  /// @dev Internal helper to toggle off a hat
  /// Useful for toggling off approver hats after a proposal is approved, rejected, or canceled; and reserved hats after
  /// a proposal is rejected or canceled
  /// @param hatId The id of the hat to toggle off
  function _toggleOffHat(uint256 hatId) internal {
    // Set this contract as the toggle module
    IHats(HATS_PROTOCOL_ADDRESS).changeHatToggle(hatId, address(this));

    // Set the hat status to false
    IHats(HATS_PROTOCOL_ADDRESS).setHatStatus(hatId, false);
  }

  /// @dev Internal helper to execute an ETH or ERC20 transfer from the Safe to the caller. This contract must be an
  /// enabled module on the Safe. Follows the OpenZeppelin SafeERC20 library patterns for Safe ERC20 transfers.
  /// @param safe_ The Safe to transfer from.
  /// @param token The token to transfer (address(0) for ETH)
  /// @param amount The amount to transfer
  function _execTransferFromSafe(address safe_, address token, uint256 amount) internal {
    address to;
    uint256 value;
    bytes memory data;

    // Encode a Safe module call to move funds to msg.sender
    // If the token is ETH, we have the Safe do a direct transfer to the msg.sender
    if (token == address(0)) {
      to = msg.sender;
      value = amount;
      data = "";
    } else {
      // If the token is not ETH, we have the Safe do an ERC20 transfer to the msg.sender
      to = token;
      value = 0;
      data = abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, amount);
    }

    // Try the Safe module call, reverting if it fails, following the OpenZeppelin SafeERC20 library patterns for ERC20
    // transfers.
    // If ProposalHatter is not enabled as a module on the Safe, the Safe will revert the tx with string "GS104"
    (bool success, bytes memory ret) =
      ModuleManager(safe_).execTransactionFromModuleReturnData(to, value, data, Enum.Operation.Call);
    if (!success) revert IProposalHatterErrors.SafeExecutionFailed(ret);
    // Assume success if return data is empty, and revert if the return data is malformed or false
    if (token != address(0) && ret.length > 0) {
      if (ret.length != 32) revert IProposalHatterErrors.ERC20TransferMalformedReturn(token, ret);
      if (abi.decode(ret, (bool)) != true) revert IProposalHatterErrors.ERC20TransferReturnedFalse(token, ret);
    }
  }
}
