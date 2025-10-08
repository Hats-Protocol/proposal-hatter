# Test Plan for ProposalHatter.sol

**Status:** Draft v1.0  
**Date:** October 6, 2025
**Purpose:** This document outlines a comprehensive test plan for ProposalHatter.sol using Foundry best practices. The plan emphasizes fork testing on Ethereum mainnet to leverage production deployments of dependencies (e.g., Hats Protocol, Safe) without mocks, ensuring realistic integration. Tests are structured for unit, integration/E2E, and invariant coverage, drawing inspiration from Sablier Protocol's handler-based invariants, Foundry docs (e.g., fuzzing, forking cheatcodes), Hats Protocol docs (e.g., hat creation patterns), and hats-zodiac repo (e.g., Safe setup in fork tests).

Tests assume Solidity ^0.8.30, Forge v1.3.0+, and adhere to best practices: descriptive assertions, vm.assume for input filtering, bound() for fuzz ranges, handler contracts for invariants, and verbose logging (-vvv).

**Key Principles:**
- **Fork-Centric**: All tests fork mainnet at a pinned block (23000000, post-Dencun, with Hats Protocol and Safe deployed). Use `vm.createSelectFork` for isolation.
- **No Mocks**: Interact with real Hats Protocol (address: 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137) and Safe v1.4.1 instances.
- **Reusability & DRY**: A base `ForkTestBase` contract defines shared setup (hats, accounts, Safes, tokens) and comprehensive helper functions to eliminate duplication:
  - **Lifecycle Helpers**: `_createTestProposal()` (with multiple overloads), `_approveProposal()`, `_executeProposal()`, `_rejectProposal()`, `_executeFullProposalLifecycle()` encapsulate common workflows
  - **Custom Assertions**: `_assertProposalData()`, `_assertHatCreated()`, `_assertHatToggle()` provide semantic, reusable verification with descriptive failure messages
  - **State Builders**: `_buildExpectedProposal()` constructs expected state structs with contract-provided defaults
  - **Test Data Helpers**: `_getNextHatId()`, `_getFundingToken()`, `_getTestActor()`, `_buildSingleHatCreationMulticall()` provide deterministic test data
  - **Utility Functions**: `_getProposalData()`, `_warpPastETA()`, `_dealTokens()`, `_getBalance()` abstract common operations
  - Tests inherit these helpers to focus on scenario logic, not boilerplate setup/verification
- **Coverage Goals**: 100% line/branch coverage via `forge coverage`; gas snapshots with `forge snapshot`.
- **CI Integration**: Run with `forge test --fuzz-runs 10000 --invariant-runs 1000 --invariant-depth 50` in GitHub Actions, caching RPC responses.
- **Security Focus**: Test edge cases (reverts, overflows, reentrancy), inspired by known exploits (e.g., TOCTOU races, allowance manipulations).
- **Arrange-Act-Assert Pattern**: Every test follows clear three-phase structure with inline comments explaining each logical step.
- **State-Aware Testing**: For state-dependent functions, exhaustively test all possible state transitions (None, Active, Approved, Executed, Escalated, Canceled, Rejected).
- **Event-Driven Verification**: Always use `vm.expectEmit` before state-changing operations to verify correct event emission with exact parameters.
- **Expected Data Structures**: Build expected state structs before operations, then update and assert against actual state after actions complete.
- **Comprehensive Authorization**: Every privileged function has corresponding `test_RevertIf_Not{Role}` tests using dedicated `maliciousActor` account.
- **Unique Test Isolation**: Use unique salt values (magic numbers, descriptive strings, or derived from parameters) for each test to prevent proposal ID collisions.
- **Descriptive Naming**: Test names follow strict conventions: `test_{Action}{Scenario}` for happy paths, `test_RevertIf_{Condition}` for reverts, `testFuzz_{Scenario}` for fuzz tests.
- **State Persistence Verification**: After revert tests, always verify that state remains unchanged from pre-action expectations.
- **Helper Function Leverage**: Maximize use of base contract helpers for consistency and readability.
- **Pause Mechanism Testing**: Verify pause checks where required, and explicitly test that `escalate()`, `reject()`, and `cancel()` bypass pause checks.
- **Multi-Safe Isolation**: Test that proposal-bound safe addresses persist correctly and changes to global safe don't affect existing proposals.
- **Deterministic Fuzz Testing**: Use helper functions to select from predefined arrays for consistent, reproducible fuzz behavior.
- **TODO Transparency**: Unimplemented tests marked with clear TODO comments in body describing expected behavior, enabling incremental development.
- **Assertion Clarity**: Every assertion includes descriptive failure messages for rapid debugging when tests fail.
- **Descriptive Comments**: Every test includes comments explaining the test and each step along the way.

## Base Test Environment

All tests inherit from a base contract (`ProposalHatterTest`) that sets up a consistent fork environment. This follows Foundry's `setUp()` pattern and hats-zodiac's fork-based Safe/hat creation (e.g., deploying test Safes via `SafeSetupLib`).

### Fork Configuration
- Fork URL: Ethereum mainnet (e.g., Alchemy/Infura endpoint defined in `foundry.toml` under `[rpc_endpoints]`).
- Pinned Block: 23000000 (recent block with Hats Protocol and Safe v1.4.1 deployed; update as needed for archive access).
- Hats Protocol: 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137 (verified mainnet deployment)
- Safe v1.4.1 Factory: 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2
- Safe v1.4.1 Singleton: 0x41675C099F32341bf84BFc5382aF534df5C7461a
- Cheatcodes: Use `vm.createSelectFork("mainnet", BLOCK_NUMBER)` in `setUp()` for isolation. Enable caching with `vm.makePersistent` for repeated runs.

foundry.toml snippet:
```toml
[profile.default]
src = 'src'
out = 'out'
libs = ['lib']
test = 'test'
cache = true
cache_path = 'cache'
ffi = true
fuzz = { runs = 10000, max_test_rejects = 100000 }
invariant = { runs = 1000, depth = 50, fail_on_revert = false }
gas_reports = ["ProposalHatter"]
gas_snapshots = true

[rpc_endpoints]
mainnet = "${MAINNET_RPC_URL}"

# Longer CI runs
[profile.ci]
fuzz = { runs = 50000 }
invariant = { runs = 5000, depth = 100 }

# Quick local testing
[profile.lite]
fuzz = { runs = 256 }
invariant = { runs = 10, depth = 10 }
```

### Test Accounts
- Use labeled addresses via `makeAddr` for readability (Forge Std best practice).
- Defined in `setUp()`:
  - `deployer`: makeAddr("deployer") – Deploys ProposalHatter.
  - `org`: makeAddr("org") – Wears top hat; represents the organization.
  - `proposer`: makeAddr("proposer") – Wears proposer hat.
  - `approver`: makeAddr("approver") – Receives per-proposal approver ticket hats.
  - `executor`: makeAddr("executor") – Wears executor hat (or test public execution).
  - `escalator`: makeAddr("escalator") – Wears escalator hat.
  - `recipient`: makeAddr("recipient") – Wears recipient hats for withdrawals.
  - `maliciousActor`: makeAddr("malicious") – For unauthorized/attack simulations.
- Fund accounts with ETH via `deal(address(this), 100 ether)` and prank as needed.

### Test Hats Tree
- Create hats on the forked Hats Protocol instance in `setUp()`, following Hats Protocol docs (e.g., `createHat` with details, maxSupply=1 for most).
- Tree Structure (as specified):
  - `topHatId` (x): Created as top hat, minted to `org`.
  - `approverBranchId` (x.1): Admin: topHatId; details: "Approver Branch"; maxSupply: 1; eligibility/toggle: sentinel (address(1)); mutable: true. Mint to `proposalHatterWearer`.
  - `opsBranchId` (x.2): Admin: topHatId; details: "Ops Branch"; maxSupply: 1; eligibility/toggle: sentinel; mutable: true. Mint to `proposalHatterWearer`.
  - `proposerHat` (x.3): Admin: topHatId; details: "Proposer"; maxSupply: 1; eligibility/toggle: sentinel; mutable: true. Mint to `proposer`.
  - `executorHat` (x.4): Admin: topHatId; details: "Executor"; maxSupply: 1; eligibility/toggle: sentinel; mutable: true. Mint to `executor`. (Test variants: set to PUBLIC_SENTINEL for public execution).
  - `escalatorHat` (x.5): Admin: topHatId; details: "Escalator"; maxSupply: 1; eligibility/toggle: sentinel; mutable: true. Mint to `escalator`.
- Use `vm.prank(org)` for hat creation/minting to simulate admin flows.
- Helper: `function _createTestProposal()` to generate per-proposal hats (approver ticket, reserved).

### Test Safes
- Deploy test Safes on fork using Safe v1.4.1 production deployment.
- In `setUp()` (inspired by hats-zodiac):
  - Deploy new Safes via `SafeProxyFactory` (0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2).
  - Enable ProposalHatter as module: Prank as Safe owner (`org`), call `enableModule(address(ProposalHatter))`.
  - Fund Safe with ETH/tokens via `deal`.
- Variants:
  - `primarySafe`: Owned by `org`, module enabled, funded with 100 ETH + tokens.
  - `secondarySafe`: Separate Safe for multi-Safe tests.
  - `disabledSafe`: Module disabled for failure tests.
  - `underfundedSafe`: Low balance for revert tests.

### Test Tokens
- Use mainnet token addresses (no mocks):
  - ETH: address(0)
  - USDC: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
  - USDT: 0xdAC17F958D2ee523a2206206994597C13D831ec7
  - DAI: 0x6B175474E89094C44Da98b954EedeAC495271d0F
- In `setUp()`: Fund Safe/accounts via `deal(token, safe, 1e18)` (adjust decimals: USDC/USDT=6, DAI=18).
- Test transfers/reverts with `vm.expectRevert`.

## 1. Unit Tests

Unit tests isolate functions/features, using fuzzing for parametric inputs (e.g., funding amounts). Prefix: `test_[RevertIf/When]_Condition`. Use `vm.expectRevert`, `bound`, `vm.assume`. Structure like Sablier's unit tests (e.g., positive/negative cases per function).

- **Deployment/Constructor**:
  - test_DeployWithValidParams: Verify immutables (HATS_PROTOCOL_ADDRESS, OWNER_HAT, etc.), mutable variables, and events emitted (ProposalHatterDeployed, role hat set events, SafeSet).
  - test_RevertIf_ZeroHatsProtocol: Specifically test hatsProtocol = address(0).
  - test_RevertIf_ZeroSafe: Specifically test safe = address(0).
  - test_RevertIf_ZeroOwnerHat: Specifically test ownerHat = 0.
  - test_DeployWithZeroOpsBranchId: opsBranchId = 0 is valid (disables branch check).
  - testFuzz_DeployWithRoles: Fuzz hat IDs, verify storage.

- **Propose**:
  - test_ProposeValid: Create proposal, verify proposal ID determinism, approver hat created under APPROVER_BRANCH_ID, proposal data stored correctly (including p.safe = current safe), and Proposed event emitted with correct parameters.
  - test_RevertIf_NotProposer: Unauthorized caller.
  - test_RevertIf_ProposalsPaused: After owner pauses.
  - testFuzz_ProposeWithParams: Fuzz fundingAmount (uint88 bounds), token, timelock, hatsMulticall, salt; verify proposal created.
  - test_ProposeFundingOnly: Empty hatsMulticall.
  - test_ProposeRolesOnly: Empty fundingAmount, fundingToken.
  - test_RevertIf_DuplicateProposal: Same inputs/salt.
  - testFuzz_ProposeFundingAmountBoundary: Test full uint88 range.

- **Reserved Hat**:
  - test_ProposeWithReservedHat: Create proposal with valid reservedHatId, verify hat created. Then test lifecycle: execute keeps it active, reject/cancel toggle it off.
  - test_RevertIf_InvalidReservedHatId: ReservedHatId doesn't match getNextId(admin).
  - test_RevertIf_InvalidReservedHatBranch: ReservedHat admin not in OPS_BRANCH_ID when OPS_BRANCH_ID != 0.
  - test_ProposeWithoutReservedHat: reservedHatId = 0, verify no hat created.

- **Approve**:
  - test_ApproveActiveProposal: Sets ETA, state to Approved, event.
  - test_RevertIf_NotApprover: Non-wearer.
  - testFuzz_ApproveTimelock: Fuzz timelockSec, verify ETA.
  - test_RevertIf_Approve_None: Try to approve a proposal that doesn't exist.
  - test_RevertIf_Approve_AlreadyApproved: Approve twice, second should revert with InvalidState.
  - test_RevertIf_Approve_Executed: Try to approve an executed proposal.
  - test_RevertIf_Approve_Escalated: Try to approve an escalated proposal.
  - test_RevertIf_Approve_Canceled: Try to approve a canceled proposal.
  - test_RevertIf_Approve_Rejected: Try to approve a rejected proposal.

- **ApproveAndExecute**:
  - test_ApproveAndExecuteZeroTimelock: Atomic approve+execute.
  - test_RevertIf_NonZeroTimelock: Should revert if timelock != 0.
  - test_RevertIf_NotApprover: Non-approver tries approveAndExecute.
  - test_RevertIf_NotExecutor: When executorHat != PUBLIC_SENTINEL, non-executor reverts.
  - test_RevertIf_ApproveAndExecute_None: Try to approve and execute a proposal that doesn't exist.
  - test_RevertIf_ApproveAndExecute_Approved: Try to approve and execute an approved proposal.
  - test_RevertIf_ApproveAndExecute_Executed: Try to approve and execute an executed proposal.
  - test_RevertIf_ApproveAndExecute_Canceled: Try to approve and execute a canceled proposal.
  - test_RevertIf_ApproveAndExecute_Rejected: Try to approve and execute a rejected proposal.
  - test_RevertIf_ApproveAndExecute_ProposalsPaused: Pause check.

- **Execute**:
  - test_ExecuteApprovedAfterETA: Full execution flow - verify allowance increased correctly, state changed to Executed, and Executed event emitted.
  - test_RevertIf_TooEarly: Timing check.
  - test_RevertIf_NotExecutor: Auth check.
  - testFuzz_ExecuteAllowance: Fuzz fundingAmount near uint88.max, check overflow revert.
  - test_ExecuteUsesProposalSafe: Allowance recorded for p.safe, not global safe (important security property).
  - test_ExecuteAtExactETA: block.timestamp == p.eta should succeed (uses >= check).
  - test_ExecuteWithMulticall: Non-empty hatsMulticall, verify multicall is executed and hatsMulticall storage is deleted after execution.
  - test_ExecuteWithoutMulticall: Empty hatsMulticall, verify no multicall executed and hatsMulticall storage remains empty.
  - test_RevertIf_MulticallFails: Hats multicall reverts, entire tx should revert (atomicity).
  - test_RevertIf_Execute_None: Try to execute a proposal that doesn't exist.
  - test_RevertIf_Execute_Escalated: Cannot execute escalated proposal.
  - test_RevertIf_Execute_Canceled: Cannot execute canceled proposal.
  - test_RevertIf_Execute_Rejected: Cannot execute rejected proposal.
  - test_RevertIf_Execute_AlreadyExecuted: Cannot execute twice.

- **Public Execution**:
  - test_ExecutePublic: Set executorHat to PUBLIC_SENTINEL, verify anyone can execute.
  - test_ApproveAndExecutePublic: Public execution for approveAndExecute.
  - test_RevertIf_Execute_NotPublicAndNotExecutor: When executorHat != PUBLIC_SENTINEL, non-executor reverts.

- **Escalate**:
  - test_EscalateActive: Sets state, event; blocks execute.
  - test_EscalateApproved: Sets state, event; blocks execute.
  - test_RevertIf_NotEscalator: Auth check.
  - test_RevertIf_Escalate_None: Try to escalate a proposal that doesn't exist.
  - test_RevertIf_Escalate_Escalated: Try to escalate an escalated proposal.
  - test_RevertIf_Escalate_Canceled: Try to escalate a canceled proposal.
  - test_RevertIf_Escalate_Rejected: Try to escalate a rejected proposal.
  - test_EscalateDoesNotCheckPause: Escalate works even when proposals paused (by design).

- **Reject**:
  - test_RejectActive: Reject proposal with reserved hat, verify state changes to Rejected, reserved hat is toggled off (if reservedHatId != 0), and Rejected event emitted.
  - test_RevertIf_Reject_NotApprover: Only approver ticket holder can reject.
  - test_RevertIf_Reject_None: Try to reject a proposal that doesn't exist.
  - test_RevertIf_Reject_Approved: Try to reject an approved proposal.
  - test_RevertIf_Reject_Escalated: Try to reject an escalated proposal.
  - test_RevertIf_Reject_Canceled: Try to reject a canceled proposal.
  - test_RevertIf_Reject_Rejected: Try to reject a rejected proposal.
  - test_RejectWithoutReservedHat: Reject when reservedHatId = 0, should succeed.
  - test_RejectDoesNotCheckPause: Reject works even when proposals paused (by design).

- **Cancel**:
  - test_CancelActive: Cancel proposal with reserved hat, verify state changes to Canceled, reserved hat is toggled off (if reservedHatId != 0), and Canceled event emitted.
  - test_CancelApproved: Submitter can cancel approved proposals, verify state changes to Canceled, reserved hat is toggled off (if reservedHatId != 0), and Canceled event emitted.
  - test_RevertIf_Cancel_NotSubmitter: Auth check.
  - test_CancelWithoutReservedHat: Cancel when reservedHatId = 0, should succeed.
  - test_RevertIf_Cancel_None: Try to cancel a proposal that doesn't exist.
  - test_RevertIf_Cancel_Executed: Try to cancel an executed proposal.
  - test_RevertIf_Cancel_Escalated: Try to cancel an escalated proposal.
  - test_RevertIf_Cancel_Rejected: Try to cancel a rejected proposal.
  - test_RevertIf_Cancel_Canceled: Try to cancel an already canceled proposal.
  - test_CancelDoesNotCheckPause: Cancel works even when proposals paused (by design).

- **Withdraw**:
  - test_WithdrawValid: Decrements allowance, executes Safe transfer (ETH/ERC20), event.
  - test_RevertIf_NotRecipient: Auth check.
  - test_RevertIf_InsufficientAllowance: Allowance check.
  - test_RevertIf_Paused: Pause check.
  - test_RevertIf_SafeFailure: Safe execution failure.
  - testFuzz_WithdrawAmount: Fuzz amount <= allowance, verify post-balance.
  - test_WithdrawUsesParameterSafe: Module call targets the safe_ parameter, not global safe.
  - test_ERC20_NoReturn: USDT-style token (0 bytes return) should succeed.
  - test_RevertIf_ERC20_ReturnsFalse: Token returns `false` should revert with ERC20TransferReturnedFalse.
  - test_RevertIf_ERC20_MalformedReturn: Return data not exactly 32 bytes should revert with ERC20TransferMalformedReturn.
  - test_ERC20_ExactlyTrue: Token returns exactly 32 bytes = `true` should succeed.
  - test_WithdrawETH: Specifically test ETH withdrawal.
  - test_WithdrawERC20: Specifically test ERC20 withdrawal.
  - test_WithdrawMultipleTimes: Partial withdrawals until allowance exhausted.
  - test_WithdrawFromSecondaryAccount: Multiple addresses wearing same hat can withdraw.

- **Admin Functions**:
  - test_SetProposerHat: Owner sets proposer hat, verify event + storage.
  - test_RevertIf_SetProposerHat_NotOwner: Non-owner cannot set.
  - test_SetExecutorHat: Owner sets executor hat, verify event + storage.
  - test_RevertIf_SetExecutorHat_NotOwner: Non-owner cannot set.
  - test_SetEscalatorHat: Owner sets escalator hat, verify event + storage.
  - test_RevertIf_SetEscalatorHat_NotOwner: Non-owner cannot set.
  - test_SetSafe: Owner sets safe, verify event + storage.
  - test_RevertIf_SetSafe_NotOwner: Non-owner cannot set.
  - test_RevertIf_SetSafe_ZeroAddress: Cannot set safe to address(0).
  - test_PauseProposals: Owner pauses proposals, verify event + storage.
  - test_UnpauseProposals: Owner unpauses proposals.
  - test_RevertIf_PauseProposals_NotOwner: Non-owner cannot pause.
  - test_PauseWithdrawals: Owner pauses withdrawals, verify event + storage.
  - test_UnpauseWithdrawals: Owner unpauses withdrawals.
  - test_RevertIf_PauseWithdrawals_NotOwner: Non-owner cannot pause.
  - test_SafeMigrationIsolation: Change global safe via setSafe(), verify existing proposals use original p.safe.

- **Views**:
  - test_AllowanceOf: Matches internal ledger for correct (safe, hatId, token) tuple.
  - test_ComputeProposalId_MatchesOnChain: Compare computeProposalId() with actual proposal creation.
  - test_ComputeProposalId_Determinism: Same inputs = same ID when called multiple times.
  - test_ComputeProposalId_DifferentSubmitters: Same params, different submitters = different IDs.
  - test_ComputeProposalId_IncludesChainId: Verify chainid in hash for replay protection.
  - test_ComputeProposalId_IncludesSafe: Different Safes with same other params = different IDs.
  - test_ComputeProposalId_IncludesContractAddress: Verify address(this) in hash.
  - test_ComputeProposalId_IncludesHatsProtocol: Verify HATS_PROTOCOL_ADDRESS in hash.
  - testFuzz_ComputeProposalId_AllParams: Fuzz all non-address parameters, verify determinism and uniqueness.
  - test_ComputeProposalId_ChangingEachParam: Change each param individually, verify different IDs each time.
  - test_ComputeProposalId_EmptyVsNonEmptyMulticall: Empty hatsMulticall vs non-empty = different IDs.
  - test_GetProposalState: Returns correct state for various proposal IDs.

Fuzz Config: Use `bound` for ranges (e.g., `fundingAmount = bound(amount, 1, type(uint88).max)`); `vm.assume` for valid states (e.g., `assume(proposal.state == Active)`).

## 2. Integration/E2E Tests

E2E tests simulate full lifecycles on fork, verifying interactions with real Hats/Safe (like hats-zodiac's integration tests).

- **Full Proposal Lifecycle**:
  - testFork_EndToEnd_HappyPath: Propose → Approve → Wait ETA → Execute → Withdraw (ETH/USDC). Verify hats minted, allowance updated, Safe balance changed.
  - testFork_EndToEnd_ReservedHat: Include reserved hat creation/toggle on reject/cancel.
  - testFork_EndToEnd_FundingOnly: Empty multicall.
  - testFork_EndToEnd_ApproveAndExecute: Zero timelock.
  - testFork_EndToEnd_PublicExecution: Set executorHat to PUBLIC_SENTINEL.

- **Failure Scenarios**:
  - testFork_RevertOnEscalate/Reject/Cancel: Lifecycle blocks execute.
  - testFork_SafeMigration: Set new Safe, verify old allowances persist but fail if module disabled.
  - testFork_TokenVariants: Withdraw USDT/DAI (different decimals/revert behaviors).
  - testFork_Reentrancy: Simulate reentry attempts during execute/withdraw (expect ReentrancyGuard revert).

- **Multi-Proposal**:
  - testFork_MultipleProposals_SameRecipient: Accumulate allowances, withdraw partially.
  - testFork_MultiSafeSupport: Create proposals for different Safes, verify isolated allowances.

- **Chaos / State Manipulation**:
  - testFork_RandomPauseSequences: Fuzz pause/unpause at random lifecycle points, verify no stuck states.
  - testFork_SafeSwapMidLifecycle: Change safe between approve and execute, verify proposal uses original safe.
  - testFork_ApproverHatRevoked: Revoke approver's hat after approval but before execute, verify execute still works.
  - testFork_RecipientHatRevoked: Revoke recipient's hat after execute, verify withdrawal fails with NotAuthorized.
  - testFork_100ProposalsSameRecipient: Accumulate allowances for realistic amounts, verify no uint88 overflow.

Use `vm.warp` for timelock simulation, `vm.prank` for role-based calls.

## 3. Invariant Tests

Invariant tests use handler contracts (like Sablier's) to fuzz stateful interactions. Prefix: `invariant_PropertyName`. Config: 1000 runs, depth 50. Define handlers for actions (propose, approve, etc.), ghost variables for tracking (e.g., totalAllowances).

**Outlined Invariants** (from spec Section 7 + analysis):

**Core Financial Invariants:**
1. **Allowance Monotonicity**: Allowances only increase on successful execute, decrease on withdraw. Never negative. (Ghost: track pre/post per (safe, hat, token) tuple).
2. **Allowance Conservation**: Sum of all allowances across (safe, hat, token) == sum of all executed proposal fundingAmounts for that tuple. (Ghost: track executed proposals per tuple).
3. **Funding Custody**: Safe balance decreases only on successful withdraw; internal allowance matches pulled amounts. (Ghost: sum of withdrawals == Safe balance delta per tuple).
4. **Overflow Protection**: Allowance arithmetic never overflows (reverts on overflow) or underflows (protected by checks). (Handler: fuzz large amounts near type(uint88).max).
5. **No Orphaned Allowances**: Every non-zero allowance has at least one corresponding executed proposal. (Ghost: map allowances to proposals).

**State Machine Invariants:**
6. **State Machine Integrity**: Proposals follow valid transitions (e.g., can't execute Escalated/Canceled; eta respected). (Handler: fuzz lifecycle calls, assert state).
7. **Terminal State Immutability**: Once a proposal reaches Executed, Rejected, or Canceled state, it can never transition to any other state. (Ghost: track terminal state entries).
8. **ETA Temporal Invariant**: Once a proposal's ETA is set (on approve), it never decreases or changes. ETA is only set once per proposal. (Ghost: track ETA changes).
9. **No Stuck States**: Every non-terminal state has at least one valid transition path. (Handler: attempt all transitions from all states).

**Authorization & Security Invariants:**
10. **Hat Auth**: Unauthorized calls always revert. (Fuzz callers without hats).
11. **Authorization Consistency**: Changes to role hats (proposer, executor, escalator) do not affect authorization checks for existing active proposals. (Handler: change roles mid-lifecycle).
12. **Approver Hat Uniqueness**: Each proposal gets a unique approver hat ID that cannot be reused by other proposals. (Ghost: track all created approver hats).

**Proposal Data Integrity:**
13. **Proposal ID Uniqueness**: Identical inputs+salt+submitter yield same ID; no overwrites. Different submitters yield different IDs. (Fuzz inputs, assert no collisions).
14. **Safe Address Immutability Per Proposal**: Once proposed, p.safe never changes. (Ghost: track all proposals, assert p.safe == original).
15. **Proposal Data Immutability**: Core proposal fields (submitter, fundingAmount, fundingToken, timelockSec, recipientHatId) remain unchanged after creation. (Ghost: track initial values).

**System Behavior Invariants:**
16. **Atomicity**: If multicall fails, no allowance change/state advance. (Handler: simulate failing multicalls).
17. **Pausability Exception**: escalate(), reject(), and cancel() work even when proposals are paused; all other proposal operations revert when paused. (Handler: fuzz pause states).
18. **Multicall Storage Consistency**: hatsMulticall storage is deleted if and only if execution succeeds with non-empty multicall. (Ghost: track multicall deletion events).
19. **Reserved Hat Lifecycle**: Reserved hats (when reservedHatId != 0) are only toggled off on cancel/reject, never on execute. Reserved hats with id=0 are ignored. (Ghost: track reserved hat toggle events).
20. **Reserved Hat Branch Validation**: When OPS_BRANCH_ID != 0, reserved hat admins must be within that branch. (Handler: fuzz invalid branch combinations).
21. **Multi-Safe Isolation**: Allowances for (safeA, hat, token) are independent of (safeB, hat, token). (Handler: fuzz operations across multiple safes).

**Enhanced Handler Design** (ProposalHatterHandler.sol):

**Core Actions:**
- `propose()`: Fuzz fundingAmount, timelock, reservedHatId; track proposal creation
- `approve()`: Target active proposals; track ETA setting
- `execute()`: Target approved proposals past ETA; track allowance changes
- `withdraw()`: Target recipients with allowances; track balance changes
- `escalate()`, `reject()`, `cancel()`: Target appropriate proposal states
- `adminActions()`: Fuzz role changes, pause toggles, Safe updates

**Advanced Fuzzing:**
- **Temporal Actions**: `warpTime()` to test ETA enforcement and timelock behavior
- **Role Changes**: `changeRoles()` mid-lifecycle to test authorization consistency
- **Multi-Safe**: Actions across different Safe addresses for isolation testing
- **Edge Cases**: Large amounts near type(uint88).max, zero values, malformed inputs

**Ghost Variables:**
- `ghost_proposalInitialData`: Track immutable proposal fields at creation
- `ghost_allowanceHistory`: Track all allowance changes per (safe, hat, token)
- `ghost_terminalStates`: Track proposals that reached terminal states
- `ghost_etaChanges`: Track ETA setting events to ensure single-set invariant
- `ghost_approverHats`: Track all created approver hat IDs for uniqueness
- `ghost_multicallDeletions`: Track multicall storage deletion events

**Invariant Examples:**
```solidity
function invariant_TerminalStateImmutability() external {
    for (bytes32 id in ghost_terminalStates) {
        ProposalState currentState = proposalHatter.getProposalState(id);
        assert(currentState == ghost_terminalStates[id]); // Never changes
    }
}

function invariant_ETANeverDecreases() external {
    for (bytes32 id in ghost_etaChanges) {
        uint64 currentETA = proposalHatter.proposals(id).eta;
        assert(currentETA >= ghost_etaChanges[id].lastETA);
    }
}
```

Run with `forge test --match-contract Invariant`. 

## 4. Attack Vector Tests

Dedicated test files for security-critical scenarios. Organized by attack category within `test/attacks/`.

### 4.1 Front-Running & MEV (test/attacks/FrontRunning.t.sol)

- **test_Attack_FrontRunPropose**:
  - Attacker observes pending propose() tx
  - Attempts to front-run with same params + different salt
  - Verify attacker gets different proposalId (submitter in hash)
  - Victim's propose() succeeds with their own ID
  
- **test_Attack_ProposalIdIncludesSubmitter**:
  - Two users propose identical params (same salt)
  - Verify different proposalIds due to different msg.sender
  - Front-running protection validated

### 4.2 Griefing Attacks (test/attacks/Griefing.t.sol)

- **test_Attack_ReservedHatIndexRace**: 
  - Attacker front-runs propose() to create hats under opsBranchId
  - Victim's propose() with reservedHatId reverts (InvalidReservedHatId)
  - Confirm mitigation: Operational assumption - trusted proposers or use getNextId off-chain
  
- **test_Attack_AllowanceExhaustion**:
  - Create proposals accumulating allowances approaching type(uint88).max
  - Verify subsequent proposals revert on overflow (protective)
  - Confirm limit is sufficient: ~309M tokens for 18-decimal assets

- **test_Attack_SpamProposals**:
  - Malicious proposer creates many proposals with different salts
  - Verify no DoS (gas costs borne by attacker)
  - Approvers can ignore spam (operational defense)

### 4.3 Time Manipulation (test/attacks/TimeManipulation.t.sol)

- **test_Edge_TimestampExactETA**:
  - Set block.timestamp == p.eta exactly
  - Verify execute succeeds (uses >= check, not >)
  
- **test_Edge_BlockTimestampSkew**:
  - Use vm.warp to shift ±15 seconds (miner manipulation range)
  - Create proposal, approve, verify ETA checks robust against skew

- **test_Edge_TimelockNearMax**:
  - Fuzz timelockSec near uint32.max (~136 years)
  - Verify approve() calculates ETA correctly (overflow reverts in 0.8+)

- **test_Edge_MultipleWarps**:
  - Warp forward past ETA, execute
  - Warp backward (simulate reorg), verify state preserved

### 4.4 State Manipulation (test/attacks/StateManipulation.t.sol)

- **test_NoStuckStates**:
  - For each state, verify at least one exit path exists
  - E.g., Escalated can still be canceled by submitter
  - Terminal states (Executed, Canceled, Rejected) cannot transition

- **test_Attack_DoubleApprove**:
  - Approve same proposal twice
  - Verify second call reverts (state != Active)

- **test_Attack_DoubleExecute**:
  - Execute same proposal twice
  - Verify second call reverts (state != Approved)

- **test_Attack_RaceApproveExecute**:
  - Two approvers try to call approve simultaneously
  - One succeeds, other reverts (state changed)

- **test_Attack_CancelAfterExecute**:
  - Execute proposal, then attempt cancel
  - Verify cancel reverts (state not Active/Approved)

### 4.5 Integer Boundary Exploits (test/attacks/IntegerBounds.t.sol)

- **test_Bound_Uint88AllowanceMax**:
  - Create proposal with fundingAmount = type(uint88).max
  - Execute, verify allowance set correctly
  - Withdraw partial amounts, verify arithmetic

- **test_Bound_Uint88AllowanceOverflow**:
  - Recipient has existing allowance near max (e.g., type(uint88).max - 1e18)
  - Execute new proposal with fundingAmount that would overflow
  - Verify execute reverts (protective, not exploitable)

- **test_Bound_Uint32TimelockMax**:
  - Create proposal with timelockSec = type(uint32).max
  - Approve, verify ETA = block.timestamp + timelockSec (no overflow in 0.8+)

- **test_Bound_CumulativeAllowances**:
  - Execute 100 proposals for same (safe, recipient, token)
  - Each adds 1M tokens (realistic amounts)
  - Verify no overflow, total allowance = 100M tokens

### 4.6 Reentrancy (test/attacks/Reentrancy.t.sol)

- **test_Attack_ReentrantWithdraw**:
  - Deploy malicious ERC20 with reentrancy hook in transfer()
  - Attacker attempts to reenter withdraw() during callback
  - Verify ReentrancyGuard blocks with expected revert

- **test_Attack_ReentrantExecute**:
  - Deploy malicious Hats multicall payload that attempts callback to ProposalHatter
  - Attempt to reenter execute() during multicall
  - Verify ReentrancyGuard blocks

- **test_ReadOnlyReentrancy**:
  - During execute, external call reads ProposalHatter state
  - Verify CEI pattern: state updated before multicall (attacker sees post-execute state)

### 4.7 State Consistency Attacks (test/attacks/StateConsistency.t.sol)

- **test_Attack_ETAManipulation**:
  - Attempt to approve same proposal multiple times to change ETA
  - Verify ETA can only be set once and never changes

- **test_Attack_TerminalStateRevival**:
  - Execute proposal, then attempt to transition to other states
  - Verify terminal states (Executed/Rejected/Canceled) are immutable

- **test_Attack_ProposalDataMutation**:
  - Attempt to modify core proposal fields after creation
  - Verify immutability of submitter, fundingAmount, etc.

- **test_Attack_ApproverHatReuse**:
  - Create multiple proposals, verify each gets unique approver hat
  - Attempt to reuse approver hat IDs across proposals

- **test_Attack_RoleChangeExploit**:
  - Change executor/approver roles mid-proposal lifecycle
  - Verify existing proposals use original authorization rules

## 5. Gas Benchmarking (test/gas/)

Track gas costs across proposal types using `forge snapshot`.

**File:** `test/gas/GasBenchmarks.t.sol`

**Benchmarks:**

- **Propose Costs**:
  - `testGas_ProposeEmptyMulticall`: Funding-only proposal (0 bytes hatsMulticall)
  - `testGas_ProposeSmallMulticall`: 100 bytes hatsMulticall
  - `testGas_ProposeLargeMulticall`: 5KB hatsMulticall
  - `testGas_ProposeWithReservedHat`: Additional cost of reservedHatId creation

- **Execute Costs**:
  - `testGas_ExecuteFundingOnly`: No multicall, baseline cost
  - `testGas_ExecuteSmallMulticall`: 1-5 Hats calls
  - `testGas_ExecuteLargeMulticall`: 50+ Hats calls
  - `testGas_ExecuteHatsMulticallDeletion`: Verify delete provides refund (compare with/without)

- **Withdraw Costs**:
  - `testGas_WithdrawETH`: Native ETH transfer
  - `testGas_WithdrawERC20`: Standard ERC20 transfer
  - `testGas_WithdrawColdVsWarm`: First withdrawal (cold SLOAD) vs subsequent (warm)

**Snapshot Commands:**
```bash
forge snapshot --match-contract Gas
forge snapshot --diff .gas-snapshot  # Compare after changes
```

**CI Integration:** 
- Store `.gas-snapshot` in repo
- CI fails if gas increases >5% without justification in PR description

## 6. Test Organization

Tests organized by type, using multiple contracts per file for logical grouping.

```
test/
├── Base.t.sol                          # Base fork setup (ForkTestBase)
├── unit/
│   ├── Constructor.t.sol               # Constructor and deployment tests
│   ├── ProposeReservedHats.t.sol       # Proposal creation and reserved hat tests
│   ├── Approve.t.sol                   # Proposal approval tests
│   ├── ExecuteApproveAndExecute.t.sol  # Execution and approveAndExecute tests
│   ├── Escalate.t.sol                  # Proposal escalation tests
│   ├── Reject.t.sol                    # Proposal rejection tests
│   ├── Cancel.t.sol                    # Proposal cancellation tests
│   ├── Withdraw.t.sol                  # Withdrawal functionality tests
│   ├── Admin.t.sol                     # Admin functions tests
│   └── View.t.sol                      # View functions and getters tests
├── integration/
│   ├── Integration.t.sol               # E2E happy paths
│   ├── Chaos.t.sol                     # Random pause/state sequences
│   └── MultiProposal.t.sol             # Parallel proposals, multi-safe
├── invariant/
│   ├── Invariants.t.sol                # Main invariant test contract
│   └── handlers/
│       └── ProposalHatterHandler.sol   # Fuzz handler with ghost variables
├── attacks/
│   ├── FrontRunning.t.sol              # MEV & front-running resistance
│   ├── Griefing.t.sol                  # Griefing attack vectors
│   ├── TimeManipulation.t.sol          # Timestamp exploits
│   ├── StateManipulation.t.sol         # State machine attacks
│   ├── IntegerBounds.t.sol             # Overflow/underflow edge cases
│   ├── Reentrancy.t.sol                # Reentrancy attempts
│   └── StateConsistency.t.sol          # State consistency and immutability attacks
├── gas/
│   └── GasBenchmarks.t.sol             # Gas cost tracking
└── helpers/
    ├── TestHelpers.sol                 # Shared utilities
    └── MaliciousTokens.sol             # Mock tokens for attack testing
```

## 7. Out of Scope (Future Work)

**Deferred to future iterations:**

1. **Differential Testing**: Compare multiple implementations of proposalId hashing for correctness
2. **Formal Verification**: Use Halmos/Certora for symbolic execution of key invariants
3. **Multi-chain Testing**: Fork Optimism, Arbitrum, Polygon (chainId in hash already protects against replay)
4. **Upgrade Paths**: Test migration from v1 to hypothetical v2 with allowance preservation
5. **Economic Attack Modeling**: Game theory analysis of griefing costs vs benefits

**Rationale:** Focus on core security and functionality first; these are valuable enhancements for future sprints.

## Next Steps
- Implement base environment in `test/Base.t.sol`
- Implement unit tests in `test/unit/Unit.t.sol`
- Implement invariant handler in `test/invariant/handlers/ProposalHatterHandler.sol`
- Run `forge coverage --report lcov` to identify gaps
- Run `forge snapshot` to establish gas baselines
- Set up CI with fork caching and gas diff checks 
