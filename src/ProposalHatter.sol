// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IHats } from "../lib/hats-protocol/src/Interfaces/IHats.sol";
import { HatsIdUtilities } from "../lib/hats-protocol/src/HatsIdUtilities.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { Strings } from "../lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import { IAllowanceModule } from "./interfaces/IAllowanceModule.sol";
import { IMulticallable } from "./interfaces/IMulticallable.sol";
import { EfficientHashLib } from "../lib/solady/src/utils/EfficientHashLib.sol";
import { IProposalHatter } from "./interfaces/IProposalHatter.sol";

/// @title ProposalHatter
/// @notice Minimal executor and funding gate for Hats-managed proposals with Safe Spending Limits integration.
/// @dev This implementation assumes all relevant hats live within a single Hats tree branch.
/// Linked tree topologies are not supported; branch membership checks rely on
/// local-level hat utilities and will not traverse linkedTreeAdmins.
/// Operationally, the contract MUST wear (or be the admin of) both the `approverBranchId` and
/// `opsBranchId` hats so it can create per-proposal hats and toggle reserved hats during
/// cancellation or rejection flows.
contract ProposalHatter is ReentrancyGuard, IProposalHatter, HatsIdUtilities {
  // --------------------
  // Types & Storage
  // --------------------

  mapping(bytes32 proposalId => IProposalHatter.ProposalData proposal) public proposals;

  // Public sentinel for indicating "no hat required" for a role
  uint256 internal constant PUBLIC_SENTINEL = 1; // never a valid Hats ID
  // Sentinel non-zero address for Hats modules (eligibility/toggle)
  address internal constant EMPTY_SENTINEL = address(1);

  // Internal, canonical allowance ledger
  mapping(uint256 recipientHatId => mapping(address fundingToken => uint88 allowanceRemaining)) public
    allowanceRemaining;

  // External integration addresses
  address public immutable HATS_PROTOCOL_ADDRESS;
  address public immutable SAFE;
  address public immutable ALLOWANCE_MODULE;

  // Role hats
  uint256 public immutable PROPOSER_HAT;
  uint256 public immutable EXECUTOR_HAT; // PUBLIC_SENTINEL => public execution
  uint256 public immutable ESCALATOR_HAT;

  // Branch hats
  uint256 public immutable APPROVER_BRANCH_ID;
  uint256 public immutable OPS_BRANCH_ID;

  // events are imported from IProposalHatter
  // --------------------
  // Constructor
  // --------------------
  /// @notice Initializes external dependencies and role hats for ProposalHatter.
  /// @param hatsProtocol The Hats Protocol core contract address.
  /// @param safe_ The DAO Safe that custodians funds.
  /// @param allowanceModule_ The Safe AllowanceModule (Spending Limits) address.
  /// @param proposer The Proposer Hat ID required to propose.
  /// @param executor The Executor Hat ID. Set to PUBLIC_SENTINEL (1) to allow public execution.
  /// @param escalator The Escalator Hat ID allowed to escalate.
  /// @param approverBranchId_ Branch root/admin for per-proposal approver ticket hats.
  /// @param opsBranchId_ Branch root used for reserved hat validation (ancestor of reserved hat parent).
  constructor(
    address hatsProtocol,
    address safe_,
    address allowanceModule_,
    uint256 proposer,
    uint256 executor,
    uint256 escalator,
    uint256 approverBranchId_,
    uint256 opsBranchId_
  ) {
    if (hatsProtocol == address(0) || safe_ == address(0) || allowanceModule_ == address(0)) revert ZeroAddress();
    HATS_PROTOCOL_ADDRESS = hatsProtocol;
    SAFE = safe_;
    ALLOWANCE_MODULE = allowanceModule_;
    PROPOSER_HAT = proposer;
    EXECUTOR_HAT = executor;
    ESCALATOR_HAT = escalator;
    APPROVER_BRANCH_ID = approverBranchId_;
    OPS_BRANCH_ID = opsBranchId_;

    emit ProposalHatterDeployed(
      hatsProtocol, safe_, allowanceModule_, proposer, executor, escalator, approverBranchId_, opsBranchId_
    );
  }

  // --------------------
  // Internal Helpers
  // --------------------

  /// @dev Require that msg.sender wears the given hat; hatId=PUBLIC_SENTINEL allows any caller.
  /// @param hatId The required hat ID (PUBLIC_SENTINEL to skip enforcement).
  function _requireHat(uint256 hatId) internal view {
    if (hatId == PUBLIC_SENTINEL) return; // PUBLIC_SENTINEL denotes public access
    if (!IHats(HATS_PROTOCOL_ADDRESS).isWearerOfHat(msg.sender, hatId)) revert IProposalHatter.NotAuthorized();
  }

  /// @dev Internal helper to compute the deterministic proposalId.
  /// @param hatsMulticall ABI-encoded bytes[] for IMulticallable.multicall.
  /// @param recipientHatId_ Recipient hat ID.
  /// @param fundingToken_ Token address (address(0) for ETH).
  /// @param fundingAmount_ Funding amount to approve on execute.
  /// @param timelockSec_ Per-proposal delay in seconds.
  /// @param salt Optional salt for de-duplication.
  function _computeProposalId(
    bytes calldata hatsMulticall,
    uint256 recipientHatId_,
    address fundingToken_,
    uint88 fundingAmount_,
    uint32 timelockSec_,
    bytes32 salt
  ) internal view returns (bytes32) {
    // Pre-hash the dynamic bytes
    bytes32 multicallHash = EfficientHashLib.hash(hatsMulticall);

    // Hash the static tuple with Solady
    return EfficientHashLib.hash(
      bytes32(block.chainid),
      bytes32(uint256(uint160(address(this)))),
      bytes32(uint256(uint160(HATS_PROTOCOL_ADDRESS))),
      multicallHash,
      bytes32(recipientHatId_),
      bytes32(uint256(uint160(fundingToken_))),
      bytes32(uint256(fundingAmount_)),
      bytes32(uint256(timelockSec_)),
      salt
    );
  }

  /// @dev Returns true if `node` is in the branch rooted at `root`.
  /// @param node The node to check.
  /// @param root The root of the branch to check.
  /// @return True if `node` is in the branch rooted at `root`.
  function _isInBranch(uint256 node, uint256 root) internal pure returns (bool) {
    // shortcut if nodes are the same
    if (node == root) return true;
    uint32 level = getLocalHatLevel(node);
    for (uint32 i; i < level; i++) {
      if (getAdminAtLocalLevel(node, i) == root) return true;
    }
    return false;
  }

  /// @dev Returns the admin hat of `node`.
  /// @param node The node to get the admin hat of.
  /// @return The admin hat of `node`.
  function _getAdminHat(uint256 node) internal pure returns (uint256) {
    // Ensure the node is not a top hat to protect against underflows
    if (isLocalTopHat(node)) revert InvalidReservedHatId();

    return getAdminAtLocalLevel(node, getLocalHatLevel(node) - 1);
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
    // increase internal allowance ledger
    uint88 current = allowanceRemaining[p.recipientHatId][p.fundingToken];
    uint88 newAllowance = current + p.fundingAmount; // reverts on overflow in ^0.8
    allowanceRemaining[p.recipientHatId][p.fundingToken] = newAllowance;

    // Advance the proposal state to Executed
    p.state = IProposalHatter.ProposalState.Executed;

    // Interactions: execute Hats Protocol multicall (skip if funding-only)
    if (p.hatsMulticall.length > 0) {
      // Decode stored bytes into bytes[] expected by Multicallable
      bytes[] memory calls = abi.decode(p.hatsMulticall, (bytes[]));
      // Execute the multicall. If Hats reverts, the entire tx reverts (atomicity)
      IMulticallable(HATS_PROTOCOL_ADDRESS).multicall(calls);
    }

    // Log the execution with the new allowance
    emit IProposalHatter.Executed(proposalId, p.recipientHatId, p.fundingToken, p.fundingAmount, newAllowance);
  }

  /// @dev Internal helper to toggle off a reserved hat to clean up after its proposal is rejected or canceled
  /// @param reservedHatId The id of the reserved hat to toggle off
  function _toggleOffReservedHat(uint256 reservedHatId) internal {
    // Set this contract as the toggle module
    IHats(HATS_PROTOCOL_ADDRESS).changeHatToggle(reservedHatId, address(this));

    // Set the hat status to false
    IHats(HATS_PROTOCOL_ADDRESS).setHatStatus(reservedHatId, false);
  }

  // --------------------
  // Lifecycle
  // --------------------
  /// @inheritdoc IProposalHatter
  function propose(
    bytes calldata hatsMulticall,
    uint256 recipientHatId_,
    address fundingToken_,
    uint88 fundingAmount_,
    uint32 timelockSec_,
    uint256 reservedHatId_,
    bytes32 salt
  ) external returns (bytes32 proposalId) {
    // Only callable by the Proposer
    _requireHat(PROPOSER_HAT);

    // Compute the proposal ID
    proposalId = _computeProposalId(hatsMulticall, recipientHatId_, fundingToken_, fundingAmount_, timelockSec_, salt);

    // New proposals must be unique
    if (proposals[proposalId].state != IProposalHatter.ProposalState.None) {
      revert IProposalHatter.AlreadyUsed(proposalId);
    }

    // Create per-proposal approver ticket hat under approverBranchId
    uint256 approverHatId_ = IHats(HATS_PROTOCOL_ADDRESS).createHat(
      APPROVER_BRANCH_ID, Strings.toHexString(uint256(proposalId), 32), 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, ""
    );

    // Optionally create the reserved hat with exact id
    if (reservedHatId_ != 0) _createReservedHat(reservedHatId_, proposalId);

    // Store the proposal
    proposals[proposalId] = IProposalHatter.ProposalData({
      submitter: msg.sender,
      fundingAmount: fundingAmount_,
      state: IProposalHatter.ProposalState.Active,
      fundingToken: fundingToken_,
      eta: 0,
      timelockSec: timelockSec_,
      recipientHatId: recipientHatId_,
      approverHatId: approverHatId_,
      reservedHatId: reservedHatId_,
      hatsMulticall: hatsMulticall
    });

    // Log the proposal
    emit IProposalHatter.Proposed(
      proposalId,
      EfficientHashLib.hash(hatsMulticall),
      msg.sender,
      recipientHatId_,
      fundingToken_,
      fundingAmount_,
      timelockSec_,
      approverHatId_,
      reservedHatId_,
      salt
    );
  }

  /// @inheritdoc IProposalHatter
  function approve(bytes32 proposalId) external {
    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Only active proposals can be approved
    if (p.state != IProposalHatter.ProposalState.Active) revert IProposalHatter.InvalidState(p.state);
    // Must wear per-proposal approver hat
    if (!IHats(HATS_PROTOCOL_ADDRESS).isWearerOfHat(msg.sender, p.approverHatId)) {
      revert IProposalHatter.NotAuthorized();
    }

    // Set the ETA as now + timelockSec
    uint64 eta = uint64(block.timestamp) + p.timelockSec;
    p.eta = eta;

    // Advance the proposal state to Succeeded
    p.state = IProposalHatter.ProposalState.Succeeded;

    // Log the approval
    emit IProposalHatter.Succeeded(proposalId, msg.sender, eta);
  }

  /// @inheritdoc IProposalHatter
  function execute(bytes32 proposalId) external nonReentrant {
    // Only callable by the Executor (unless execution is public, ie is set to PUBLIC_SENTINEL)
    _requireHat(EXECUTOR_HAT);

    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Proposals are only executable...
    // - if they have state Succeeded
    // - if current time is after the ETA
    if (p.state != IProposalHatter.ProposalState.Succeeded) revert IProposalHatter.InvalidState(p.state);
    if (uint64(block.timestamp) < p.eta) revert IProposalHatter.TooEarly(p.eta, uint64(block.timestamp));

    // Execute the proposal
    _execute(p, proposalId);
  }

  /// @inheritdoc IProposalHatter
  function approveAndExecute(bytes32 proposalId) external nonReentrant returns (bytes32 id) {
    // Only callable by Executor (unless execution is public) and Approver Ticket Hat wearer
    _requireHat(EXECUTOR_HAT);

    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Only callable by Approver Ticket Hat wearer
    if (!IHats(HATS_PROTOCOL_ADDRESS).isWearerOfHat(msg.sender, p.approverHatId)) {
      revert IProposalHatter.NotAuthorized();
    }

    // Proposals can only be approved and executed atomically...
    // - if they are Active
    // - when there is no timelock
    IProposalHatter.ProposalState state = p.state;
    if (state != IProposalHatter.ProposalState.Active) revert IProposalHatter.InvalidState(state);
    if (p.timelockSec != 0) revert IProposalHatter.InvalidState(state);

    // Log the approval
    uint64 eta = uint64(block.timestamp);
    p.eta = eta;
    emit IProposalHatter.Succeeded(proposalId, msg.sender, eta);

    // Execute the proposal
    _execute(p, proposalId);
    return proposalId;
  }

  /// @inheritdoc IProposalHatter
  function escalate(bytes32 proposalId) external {
    // Only callable by the Escalator
    _requireHat(ESCALATOR_HAT);

    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Proposals can only be escalated when Active or Succeeded
    if (p.state != IProposalHatter.ProposalState.Active && p.state != IProposalHatter.ProposalState.Succeeded) {
      revert IProposalHatter.InvalidState(p.state);
    }

    // Set the proposal state to Escalated
    p.state = IProposalHatter.ProposalState.Escalated;

    // Log the escalation
    emit IProposalHatter.Escalated(proposalId, msg.sender);
  }

  /// @inheritdoc IProposalHatter
  function reject(bytes32 proposalId) external {
    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Only callable by Approver Ticket Hat wearer
    _requireHat(p.approverHatId);

    // Proposals can only be rejected when Active
    if (p.state != IProposalHatter.ProposalState.Active) revert IProposalHatter.InvalidState(p.state);

    // Set the proposal state to Defeated
    p.state = IProposalHatter.ProposalState.Defeated;

    // If it exists, toggle off the reserved hat to clean up
    if (p.reservedHatId != 0) _toggleOffReservedHat(p.reservedHatId);

    // Log the rejection
    emit IProposalHatter.Defeated(proposalId, msg.sender);
  }

  /// @inheritdoc IProposalHatter
  function cancel(bytes32 proposalId) external {
    // Get the proposal storage pointer
    IProposalHatter.ProposalData storage p = proposals[proposalId];

    // Only callable by the original submitter
    if (msg.sender != p.submitter) revert IProposalHatter.NotAuthorized();

    // Proposals can only be canceled when Active or Succeeded
    if (p.state != IProposalHatter.ProposalState.Active && p.state != IProposalHatter.ProposalState.Succeeded) {
      revert IProposalHatter.InvalidState(p.state);
    }

    // Set the proposal state to Canceled
    p.state = IProposalHatter.ProposalState.Canceled;

    // If it exists, toggle off the reserved hat to clean up
    if (p.reservedHatId != 0) _toggleOffReservedHat(p.reservedHatId);

    // Log the cancellation
    emit IProposalHatter.Canceled(proposalId, msg.sender);
  }

  // --------------------
  // Funding pull (via Safe AllowanceModule)
  // --------------------

  /// @inheritdoc IProposalHatter
  function withdraw(uint256 recipientHatId_, address token, uint88 amount) external nonReentrant {
    // Only callable by the Recipient Hat wearer
    _requireHat(recipientHatId_);

    // Check if the remaining allowance is sufficient
    uint88 rem = allowanceRemaining[recipientHatId_][token];

    if (rem < amount) revert IProposalHatter.AllowanceExceeded(rem, amount);

    // Decrement the allowance
    uint88 newAllowance = rem - amount;
    unchecked {
      allowanceRemaining[recipientHatId_][token] = newAllowance;
    }

    // interactions: call AllowanceModule to move funds from Safe to msg.sender
    // Any revert from the module will bubble up and revert the entire transaction (including allowance decrement)
    IAllowanceModule(ALLOWANCE_MODULE).executeAllowanceTransfer(
      SAFE, token, msg.sender, uint96(amount), address(0), 0, address(this), new bytes(0)
    );

    // Log the allowance consumption
    emit IProposalHatter.AllowanceConsumed(recipientHatId_, token, amount, newAllowance, msg.sender);
  }

  // --------------------
  // Public Getters
  // --------------------

  /// @inheritdoc IProposalHatter
  function allowanceOf(uint256 hatId, address token) external view returns (uint88) {
    return allowanceRemaining[hatId][token];
  }

  /// @inheritdoc IProposalHatter
  function computeProposalId(
    bytes calldata hatsMulticall,
    uint256 recipientHatId_,
    address fundingToken_,
    uint88 fundingAmount_,
    uint32 timelockSec_,
    bytes32 salt
  ) external view returns (bytes32) {
    return _computeProposalId(hatsMulticall, recipientHatId_, fundingToken_, fundingAmount_, timelockSec_, salt);
  }
}
