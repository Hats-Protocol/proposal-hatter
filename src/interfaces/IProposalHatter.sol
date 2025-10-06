// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IProposalHatterTypes
/// @notice Types for ProposalHatter.
interface IProposalHatterTypes {
  enum ProposalState {
    None,
    Active,
    Approved,
    Escalated,
    Canceled,
    Rejected,
    Executed
  }

  /// @dev Storage-optimized struct (5 slots + dynamic bytes):
  /// Slot 0: submitter (20) + fundingAmount (11) + state (1) = 32 bytes
  /// Slot 1: fundingToken (20) + eta (8) + timelockSec (4) = 32 bytes
  /// Slot 2: safe (20)
  /// Slot 3: recipientHatId (32 bytes)
  /// Slot 4: approverHatId (32 bytes)
  /// Slot 5: reservedHatId (32 bytes)
  /// Slot 6: hatsMulticall (dynamic)
  struct ProposalData {
    address submitter; // 20 bytes
    uint88 fundingAmount; // 11 bytes
    ProposalState state; // 1 byte
    address fundingToken; // 20 bytes
    uint64 eta; // 8 bytes (queue time: now + timelockSec)
    uint32 timelockSec; // 4 bytes (per-proposal delay; 0 = none)
    address safe; // 20 bytes
    uint256 recipientHatId; // 32 bytes
    uint256 approverHatId; // 32 bytes
    uint256 reservedHatId; // 32 bytes (0 if none)
    bytes hatsMulticall; // dynamic (full encoded payload for Hats Protocol execution & UI surfaces)
  }
}

/// @title IProposalHatterErrors
/// @notice Errors for ProposalHatter.
interface IProposalHatterErrors is IProposalHatterTypes {
  error NotAuthorized();
  error InvalidState(ProposalState current);
  error TooEarly(uint64 eta, uint64 nowTs);
  error AllowanceExceeded(uint256 remaining, uint256 requested);
  error AlreadyUsed(bytes32 proposalId);
  error ZeroAddress();
  error InvalidReservedHatId();
  error InvalidReservedHatBranch();
  error ProposalsArePaused();
  error WithdrawalsArePaused();
  error SafeExecutionFailed(bytes returnData);
  error ERC20TransferReturnedFalse(address token, bytes returnData);
  error ERC20TransferMalformedReturn(address token, bytes returnData);
}

/// @title IProposalHatterEvents
/// @notice Events for ProposalHatter.
interface IProposalHatterEvents is IProposalHatterTypes {
  event Proposed(
    bytes32 indexed proposalId,
    bytes32 indexed hatsMulticallHash,
    address indexed submitter,
    uint256 fundingAmount,
    address fundingToken,
    uint32 timelockSec,
    address safe,
    uint256 recipientHatId,
    uint256 approverHatId,
    uint256 reservedHatId,
    bytes32 salt
  );

  event Approved(bytes32 indexed proposalId, address indexed by, uint64 eta);

  event Executed(
    bytes32 indexed proposalId,
    uint256 indexed recipientHatId,
    address indexed safe,
    address fundingToken,
    uint256 fundingAmount,
    uint256 allowanceRemaining
  );

  event Escalated(bytes32 indexed proposalId, address indexed by);
  event Canceled(bytes32 indexed proposalId, address indexed by);
  event Rejected(bytes32 indexed proposalId, address indexed by);

  event AllowanceConsumed(
    uint256 indexed recipientHatId,
    address safe,
    address indexed token,
    uint256 amount,
    uint256 remaining,
    address indexed to
  );

  event ProposalHatterDeployed(address hatsProtocol, uint256 ownerHatId, uint256 approverBranchId, uint256 opsBranchId);

  // Admin + pause events
  event ProposalsPaused(bool paused);
  event WithdrawalsPaused(bool paused);
  event ProposerHatSet(uint256 hatId);
  event EscalatorHatSet(uint256 hatId);
  event ExecutorHatSet(uint256 hatId);
  event SafeSet(address safe);
}

/// @title IProposalHatter
/// @notice Interface for ProposalHatter: proposal lifecycle, funding allowances, owner-admin setters, and pausability.
interface IProposalHatter is IProposalHatterEvents, IProposalHatterErrors {
  // ---- Lifecycle ----
  /// @notice Create a proposal with fixed Hats multicall bytes and a funding allowance.
  /// @dev `hatsMulticall` may be empty for funding-only proposals. The returned ID is deterministic.
  ///       Only callable by a wearer of the Proposer Hat and when proposals are not paused.
  /// @param fundingAmount Amount to add to internal allowance upon execution.
  /// @param fundingToken Token to fund (use address(0) for ETH).
  /// @param timelockSec Per-proposal timelock in seconds (0 for none).
  /// @param recipientHatId Recipient hat ID allowed to withdraw funds for this proposal.
  /// @param reservedHatId Optional exact id of the per-proposal reserved hat to create (0 = none).
  /// @param hatsMulticall ABI-encoded `bytes[]` for `IMulticallable.multicall` on the Hats Protocol.
  /// @param salt Optional salt to de-duplicate identical inputs.
  /// @return proposalId Deterministic ID for the proposal bound to the caller address.
  function propose(
    uint88 fundingAmount,
    address fundingToken,
    uint32 timelockSec,
    uint256 recipientHatId,
    uint256 reservedHatId,
    bytes calldata hatsMulticall,
    bytes32 salt
  ) external returns (bytes32 proposalId);

  /// @notice Approve an active proposal and set its ETA to `block.timestamp + timelockSec`.
  /// @dev Only callable by a wearer of the proposal's Approver Hat and when proposals are not paused.
  /// @param proposalId The proposal to queue for execution.
  function approve(bytes32 proposalId) external;

  /// @notice Execute an approved proposal after ETA; applies Hats multicall (if any) and increases allowance.
  /// @dev If `executorHatId == PUBLIC_SENTINEL`, anyone can execute; otherwise the caller must wear the executor hat.
  ///      Only callable when proposals are not paused.
  /// Reverts if now < eta.
  /// @param proposalId The proposal to execute.
  function execute(bytes32 proposalId) external;

  /// @notice Approve and immediately execute an existing zero-timelock proposal.
  /// @dev Caller must wear the Approver Ticket Hat for this proposal; if `executorHatId != PUBLIC_SENTINEL`, caller
  /// must also wear Executor hat.
  ///      Only callable when proposals are not paused.
  /// @param proposalId The proposal to approve and execute.
  /// @return id The proposal id (echoed).
  function approveAndExecute(bytes32 proposalId) external returns (bytes32 id);

  /// @notice Escalate an `Active` or `Approved` proposal to block execution by this contract.
  /// @param proposalId The proposal to escalate.
  function escalate(bytes32 proposalId) external;

  /// @notice Mark an `Active` proposal as `Rejected` (committee rejection).
  /// @param proposalId The proposal to reject.
  function reject(bytes32 proposalId) external;

  /// @notice Cancel a pre-execution proposal. Only callable by the original submitter.
  /// @param proposalId The proposal to cancel.
  function cancel(bytes32 proposalId) external;

  // ---- Funding pull ----
  /// @notice Withdraw funds via Safe module call. Funds are sent to `msg.sender`.
  /// @dev Requires the caller to wear `recipientHatId`. Uses Safe v1.4.1 `execTransactionFromModuleReturnData`
  ///      with `Enum.Operation.Call`. For ERC-20s, treats empty return as success; if boolean is returned, it must be
  /// true.
  ///      Reverts with `SafeExecutionFailed` or `ERC20TransferReturnedFalse` on failure.
  ///      Only callable when withdrawals are not paused.
  /// @param recipientHatId The hat ID the caller must wear.
  /// @param safe The Safe for which this allowance is valid.
  /// @param token Token to withdraw (address(0) for ETH).
  /// @param amount Amount to withdraw.
  function withdraw(uint256 recipientHatId, address safe, address token, uint88 amount) external;

  /// @notice Get remaining internal allowance for a hat/token.
  /// @param safe The Safe for which this allowance is valid.
  /// @param hatId Recipient hat ID.
  /// @param token Token address (address(0) for ETH).
  /// @return remaining Remaining allowance amount.
  function allowanceOf(address safe, uint256 hatId, address token) external view returns (uint88 remaining);

  /// @notice Compute proposalId for given inputs (for pre-call checks/UI display).
  /// @dev Includes `msg.sender` in the hash to prevent front-running by other submitters.
  /// @param submitter The address that proposed.
  /// @param fundingAmount Funding amount to be added on execution.
  /// @param fundingToken Token address (address(0) for ETH).
  /// @param timelockSec Delay in seconds.
  /// @param safe The Safe for which this allowance is valid.
  /// @param recipientHatId Recipient hat ID.
  /// @param hatsMulticall ABI-encoded `bytes[]` for `IMulticallable.multicall`.
  /// @param salt Optional salt.
  /// @return proposalId The deterministic proposal id for the calling address.
  function computeProposalId(
    address submitter,
    uint88 fundingAmount,
    address fundingToken,
    uint32 timelockSec,
    address safe,
    uint256 recipientHatId,
    bytes calldata hatsMulticall,
    bytes32 salt
  ) external view returns (bytes32);

  // ---- Storage getters ----
  /// @notice Proposal data by id.
  /// @param proposalId The proposal id.
  /// @return submitter Address that proposed.
  /// @return fundingAmount Amount to add to internal allowance upon execution.
  /// @return state Current proposal state.
  /// @return fundingToken Token to fund (address(0) for ETH).
  /// @return eta Execution unlock timestamp.
  /// @return timelockSec Per-proposal timelock seconds.
  /// @return safe The Safe for which this allowance is valid.
  /// @return recipientHatId Hat ID allowed to withdraw.
  /// @return approverHatId Approver hat ID.
  /// @return reservedHatId Reserved hat ID.
  /// @return hatsMulticall ABI-encoded bytes[] for Hats multicall.
  function proposals(bytes32 proposalId)
    external
    view
    returns (
      address submitter,
      uint88 fundingAmount,
      ProposalState state,
      address fundingToken,
      uint64 eta,
      uint32 timelockSec,
      address safe,
      uint256 recipientHatId,
      uint256 approverHatId,
      uint256 reservedHatId,
      bytes memory hatsMulticall
    );

  /// @notice Get the state of a proposal.
  /// @param proposalId The proposal id.
  /// @return state The state of the proposal.
  function getProposalState(bytes32 proposalId) external view returns (ProposalState);

  /// forge-lint: disable-start(mixed-case-function)

  /// @notice Hats Protocol core contract address used for wearer checks and multicall.
  function HATS_PROTOCOL_ADDRESS() external view returns (address);

  /// @notice The DAO Safe that custodians funds.
  function safe() external view returns (address);

  /// @notice Proposer Hat ID required to propose.
  function proposerHat() external view returns (uint256);

  /// @notice Approver branch root hat id.
  function APPROVER_BRANCH_ID() external view returns (uint256);

  /// @notice Ops branch root hat id used for reserved hat validation.
  function OPS_BRANCH_ID() external view returns (uint256);

  /// @notice Executor Hat ID. Set to `PUBLIC_SENTINEL` (1) to allow public execution.
  function executorHat() external view returns (uint256);

  /// @notice Escalator Hat ID allowed to escalate proposals.
  function escalatorHat() external view returns (uint256);

  /// @notice Owner hat id.
  function OWNER_HAT() external view returns (uint256);

  /// @notice Proposals paused flag.
  function proposalsPaused() external view returns (bool);

  /// @notice Withdrawals paused flag.
  function withdrawalsPaused() external view returns (bool);

  // ---- Admin (owner hat required) ----
  function pauseProposals(bool paused) external;
  function pauseWithdrawals(bool paused) external;
  function setProposerHat(uint256 hatId) external;
  function setEscalatorHat(uint256 hatId) external;
  function setExecutorHat(uint256 hatId) external;

  /// @notice The DAO Safe that custodians funds. Settable by owner, applied to future proposals.
  function setSafe(address safe) external;
}
