// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IProposalHatter
/// @notice Interface for ProposalHatter: proposal lifecycle and funding allowances (no post-deploy admin surface).
interface IProposalHatter {
  /// --------------------
  /// Errors
  /// --------------------
  error NotAuthorized();
  error InvalidState(ProposalState current);
  error TooEarly(uint64 eta, uint64 nowTs);
  error AllowanceExceeded(uint256 remaining, uint256 requested);
  error AlreadyUsed(bytes32 proposalId);
  error ZeroAddress();
  error InvalidReservedHatId();
  error InvalidReservedHatBranch();

  /// --------------------
  /// Types
  /// --------------------
  enum ProposalState {
    None,
    Active,
    Succeeded,
    Escalated,
    Canceled,
    Defeated,
    Executed
  }

  /// @dev Storage-optimized struct (5 slots + dynamic bytes):
  /// Slot 0: submitter (20) + fundingAmount (11) + state (1) = 32 bytes
  /// Slot 1: fundingToken (20) + eta (8) + timelockSec (4) = 32 bytes
  /// Slot 2: recipientHatId (32 bytes)
  /// Slot 3: approverHatId (32 bytes)
  /// Slot 4: reservedHatId (32 bytes)
  /// Slot 5+: hatsMulticall (dynamic)
  struct ProposalData {
    address submitter;         // 20 bytes
    uint88 fundingAmount;      // 11 bytes
    ProposalState state;       // 1 byte
    address fundingToken;      // 20 bytes
    uint64 eta;                // 8 bytes (queue time: now + timelockSec)
    uint32 timelockSec;        // 4 bytes (per-proposal delay; 0 = none)
    uint256 recipientHatId;    // 32 bytes
    uint256 approverHatId;     // 32 bytes
    uint256 reservedHatId;     // 32 bytes (0 if none)
    bytes hatsMulticall;       // dynamic (full encoded payload for Hats Protocol execution & UI surfaces)
  }

  /// --------------------
  /// Events
  /// --------------------
  event Proposed(
    bytes32 indexed proposalId,
    bytes32 indexed hatsMulticallHash,
    address indexed submitter,
    uint256 recipientHatId,
    address fundingToken,
    uint256 fundingAmount,
    uint32 timelockSec,
    uint256 approverHatId,
    uint256 reservedHatId,
    bytes32 salt
  );

  event Succeeded(bytes32 indexed proposalId, address indexed by, uint64 eta);

  event Executed(
    bytes32 indexed proposalId,
    uint256 indexed recipientHatId,
    address indexed fundingToken,
    uint256 fundingAmount,
    uint256 allowanceRemaining
  );

  event Escalated(bytes32 indexed proposalId, address indexed by);
  event Canceled(bytes32 indexed proposalId, address indexed by);
  event Defeated(bytes32 indexed proposalId, address indexed by);

  event AllowanceConsumed(
    uint256 indexed recipientHatId, address indexed token, uint256 amount, uint256 remaining, address indexed to
  );

  event ProposalHatterDeployed(
    address hatsProtocol,
    address indexed safe,
    address indexed allowanceModule,
    uint256 indexed proposerHatId,
    uint256 executorHatId,
    uint256 escalatorHatId,
    uint256 approverBranchId,
    uint256 opsBranchId
  );

  // ---- Lifecycle ----
  /// @notice Create a proposal with fixed Hats multicall bytes and a funding allowance.
  /// @dev `hatsMulticall` may be empty for funding-only proposals. The returned ID is deterministic.
  /// @param hatsMulticall ABI-encoded `bytes[]` for `IMulticallable.multicall` on the Hats Protocol.
  /// @param recipientHatId Recipient hat ID allowed to withdraw funds for this proposal.
  /// @param fundingToken Token to fund (use address(0) for ETH).
  /// @param fundingAmount Amount to add to internal allowance upon execution.
  /// @param timelockSec Per-proposal timelock in seconds (0 for none).
  /// @param reservedHatId Optional exact id of the per-proposal reserved hat to create (0 = none).
  /// @param salt Optional salt to de-duplicate identical inputs.
  /// @return proposalId Deterministic ID for the proposal.
  function propose(
    bytes calldata hatsMulticall,
    uint256 recipientHatId,
    address fundingToken,
    uint88 fundingAmount,
    uint32 timelockSec,
    uint256 reservedHatId,
    bytes32 salt
  ) external returns (bytes32 proposalId);

  /// @notice Approve an active proposal and set its ETA to `block.timestamp + timelockSec`.
  /// @param proposalId The proposal to queue for execution.
  function approve(bytes32 proposalId) external;

  /// @notice Execute a succeeded proposal after ETA; applies Hats multicall (if any) and increases allowance.
  /// @dev If `executorHatId == PUBLIC_SENTINEL`, anyone can execute; otherwise the caller must wear the executor hat.
  /// Reverts if now < eta.
  /// @param proposalId The proposal to execute.
  function execute(bytes32 proposalId) external;

  /// @notice Approve and immediately execute an existing zero-timelock proposal.
  /// @dev Caller must wear the Approver Ticket Hat for this proposal; if `executorHatId != PUBLIC_SENTINEL`, caller
  /// must also wear Executor hat.
  /// @param proposalId The proposal to approve and execute.
  /// @return id The proposal id (echoed).
  function approveAndExecute(bytes32 proposalId) external returns (bytes32 id);

  /// @notice Escalate an `Active` or `Succeeded` proposal to block execution by this contract.
  /// @param proposalId The proposal to escalate.
  function escalate(bytes32 proposalId) external;

  /// @notice Mark an `Active` proposal as `Defeated` (committee rejection).
  /// @param proposalId The proposal to reject.
  function reject(bytes32 proposalId) external;

  /// @notice Cancel a pre-execution proposal. Only callable by the original submitter.
  /// @param proposalId The proposal to cancel.
  function cancel(bytes32 proposalId) external;

  // ---- Funding pull ----
  /// @notice Withdraw funds via Safe AllowanceModule. Funds are sent to `msg.sender`.
  /// @dev Requires the caller to wear `recipientHatId`. Any revert from AllowanceModule will bubble up
  /// and revert the transaction (including allowance changes). Emits `AllowanceConsumed` on success.
  /// @param recipientHatId The hat ID the caller must wear.
  /// @param token Token to withdraw (address(0) for ETH).
  /// @param amount Amount to withdraw.
  function withdraw(uint256 recipientHatId, address token, uint88 amount) external;

  /// @notice Get remaining internal allowance for a hat/token.
  /// @param hatId Recipient hat ID.
  /// @param token Token address (address(0) for ETH).
  /// @return remaining Remaining allowance amount.
  function allowanceOf(uint256 hatId, address token) external view returns (uint88 remaining);

  /// @notice Compute proposalId for given inputs (for pre-call checks/UI display).
  /// @param hatsMulticall ABI-encoded `bytes[]` for `IMulticallable.multicall`.
  /// @param recipientHatId Recipient hat ID.
  /// @param fundingToken Token address (address(0) for ETH).
  /// @param fundingAmount Funding amount to be added on execution.
  /// @param timelockSec Delay in seconds.
  /// @param salt Optional salt.
  /// @return proposalId The deterministic proposal id.
  function computeProposalId(
    bytes calldata hatsMulticall,
    uint256 recipientHatId,
    address fundingToken,
    uint88 fundingAmount,
    uint32 timelockSec,
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
      uint256 recipientHatId,
      uint256 approverHatId,
      uint256 reservedHatId,
      bytes memory hatsMulticall
    );

  /// @notice Internal ledger: remaining allowance by recipient hat and token.
  /// @param hatId The recipient hat ID.
  /// @param token The token address (address(0) for ETH).
  /// @return remaining Current remaining allowance.
  function allowanceRemaining(uint256 hatId, address token) external view returns (uint88 remaining);

  /// forge-lint: disable-start(mixed-case-function)

  /// @notice Hats Protocol core contract address used for wearer checks and multicall.
  function HATS_PROTOCOL_ADDRESS() external view returns (address);

  /// @notice The DAO Safe that custodians funds.
  function SAFE() external view returns (address);

  /// @notice The Safe AllowanceModule (Spending Limits) address.
  function ALLOWANCE_MODULE() external view returns (address);

  /// @notice Proposer Hat ID required to propose.
  function PROPOSER_HAT() external view returns (uint256);

  /// @notice Approver branch root hat id.
  function APPROVER_BRANCH_ID() external view returns (uint256);

  /// @notice Ops branch root hat id used for reserved hat validation.
  function OPS_BRANCH_ID() external view returns (uint256);

  /// @notice Executor Hat ID. Set to `PUBLIC_SENTINEL` (1) to allow public execution.
  function EXECUTOR_HAT() external view returns (uint256);

  /// @notice Escalator Hat ID allowed to escalate proposals.
  function ESCALATOR_HAT() external view returns (uint256);

  /// forge-lint: disable-end(mixed-case-function)
}
