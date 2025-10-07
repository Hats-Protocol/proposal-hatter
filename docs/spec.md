# ProposalHatter.sol — Functional Specification

Status: Draft v1.7

Date: 2025-10-06

Author: Spencer

Implementer: Codex

Scope: Single contract (ProposalHatter.sol). No proxy/upgradability assumed unless noted.

---

## 0) Purpose & Summary

We want decider trust zones (hats) to approve exactly-specified Hats changes and bounded funding, without giving the decider custody of funds or access controls. Proposals hash‑commit the precise Hats `multicall` bytes and the funding allowance for a Recipient Hat. After an optional timelock, anyone (or an address wearing an Executor Hat, if set) can execute the proposal. Funding is pull‑based: a Recipient Hat wearer calls Proposal Hatter, which (a) verifies entitlement and internal allowance, then (b) executes a Safe module transaction to transfer ETH/ERC‑20 from the DAO’s vault to the recipient.

Concurrency model: Each proposal has its own decider trust zone (hat) and its own optional reserved Hats subtree.
- A unique per‑proposal Approver Ticket Hat is created at propose‑time and later minted to the selected decider; only a wearer of this hat can approve or reject that proposal.
- Optionally, a per‑proposal Reserved Branch Hat is created at propose‑time (if a non‑zero branch root is supplied), reserving a namespace under which the proposal’s operational hats can be created without index races.

Funding‑only proposals are supported: if a proposal’s `hatsMulticall` bytes are empty, it still must be executed to activate the internal allowance and enable withdrawals. In that case, the contract skips calling Hats Protocol and only applies the funding effects.

This spec is for a minimal version of this concept that, if successful, will be updated in future iterations. This version should minimize complexity and focus on the core functionality, with regards to both implementation of the contract and to make user interfaces as simple and cheap to implement as possible.

---

## 1) External Dependencies & Ownership Model

- Vault = Safe. The DAO is the Safe owner(s) and can execute arbitrary transactions via normal Safe flows (multisig or delegate to governance).
- Safe Module pattern: ProposalHatter must be enabled as a module on the Safe. Withdrawals are executed via `execTransactionFromModuleReturnData` (Safe v1.4.1) using `Enum.Operation.Call` only.
- Hats Protocol (`HATS_PROTOCOL_ADDRESS`), used for `isWearerOfHat` and to run the exact multicall payload.
- Codebase imports `safe-global/safe-smart-account` v1.4.1 for Safe module interfaces (`ISafe`, `Enum`).

Hats integration calls used:
- `createHat(admin, details, maxSupply, eligibility, toggle, mutable, imageURI)` to create per-proposal ticket hats and optional reserved hats.
- `changeHatToggle(hatId, newToggle)` then `setHatStatus(hatId, false)` to deactivate a reserved hat on cancel/reject.

Hats module address requirements: modules cannot be zero-address. This spec uses `EMPTY_SENTINEL = address(1)` for “no eligibility/toggle module”.

Operational note: The DAO must enable ProposalHatter as a module on the Safe. Safe owners may remove/disable the module at any time via Safe governance.

ETH sentinel: `address(0)` denotes native ETH in all references below.

Constructor wiring:

- `HATS_PROTOCOL_ADDRESS` is immutable and set at deploy
- `ownerHatId` is provided in the constructor and is immutable; the “owner” is any caller wearing this hat.
- `safe` (the DAO's vault) is provided in the constructor and MAY be updated post‑deploy by the owner via `setVault(address)`.
- `approverBranchId` is set in the constructor (admin under which per‑proposal approver ticket hats are created) and is immutable thereafter.
- `opsBranchId` is set in the constructor (branch root used for validation of per‑proposal reserved hats) and is immutable thereafter.
- Role hat IDs (`proposerHatId`, `executorHatId`, `escalatorHatId`) are set in the constructor and MAY be updated post‑deploy by the owner via `setProposerHat`, `setExecutorHat`, and `setEscalatorHat`. There is no global Approver Hat.
- Pausability: the owner may toggle `pauseProposals(bool)` and `pauseWithdrawals(bool)`. Proposal‑lifecycle pause blocks create/queue/execute (see Semantics). Withdrawals pause blocks `withdraw`. Escalate/Reject/Cancel remain unpaused.
- Internal allowance balances can only be increased by executed proposals and decreased by withdrawals; there is no administrative path to adjust them.

---

## 2) Roles (Hat IDs, checked at call time)

- Owner Hat — wearer of `ownerHatId`; required for admin/setter/pause functions.
- Proposer Hat — required to propose.
- Approver Ticket Hat — per-proposal hat created by `propose` (under `approverBranchId`) and minted operationally to the chosen decider; required to approve/reject and approveAndExecute for that proposal only.
- Executor Hat — if set to `PUBLIC_SENTINEL` (value `1`), execution is public; otherwise, caller must wear this hat.
- Escalator Hat — may escalate (pre-execution veto to full DAO path).

Additionally, each proposal has a Recipient Hat, which is the hat authorized to withdraw funds from the vault.

All role checks use `Hats.isWearerOfHat(msg.sender, roleHatId)` at call time. Admin functions require the caller to wear the Owner Hat. Role assignments (proposer/executor/escalator) may be updated post‑deploy by the owner.

Sentinels

- `PUBLIC_SENTINEL = 1` — never a valid Hats ID; indicates public execution when set as `executorHatId`.
- `EMPTY_SENTINEL = address(1)` — used when creating hats to indicate “no eligibility module” and “no toggle module” (Hats requires non‑zero module addresses).

---

## 3) Data Model

### 3.1 Proposal identity & hashing

Inputs defining a proposal:

- `fundingAmount`: `uint88`
- `fundingToken`: `address` (ERC‑20 or ETH sentinel `address(0)`)
- `timelockSec`: `uint64` (0 = no timelock)
- `recipientHatId`: `uint256`
- `reservedHatId`: `uint256` (optional; if non‑zero, this exact hat id is created at propose‑time; its parent must be a descendant of `opsBranchId` when `opsBranchId != 0`)
- `hatsMulticall`: `bytes` (exact payload for Hats Protocol)
- `salt`: `bytes32` (optional; differentiate repeated proposals with identical parameters)
- `submitter`: `address` (caller of `propose`)

Deterministic IDs (global de‑duplication):

```
hatsMulticallHash = keccak256(hatsMulticall);
proposalId = keccak256(
  abi.encode(
    block.chainid,
    address(this),
    HATS_PROTOCOL_ADDRESS,
    submitter,
    fundingAmount,
    fundingToken,
    timelockSec,
    recipientHatId,
    hatsMulticallHash,
    salt
  )
);
```

Notes:

- Per-salt de-duplication: For a given submitter, proposing identical inputs with the same salt yields the same `proposalId` and must be unused; changing the salt creates a new `proposalId` for an otherwise identical payload. Different submitters always derive different `proposalId`s, preventing front-running with borrowed calldata.
- `salt` is optional (e.g., `0x00`) and is emitted for provenance.
- Full `hatsMulticall` calldata is persisted alongside each proposal for first-party UIs; integrity checks compare supplied calldata to the stored bytes.
- Helper: `computeProposalId(...)` (see Interface) mirrors this hashing logic on-chain for UI/explorer consumption. Implementations may pre-hash `hatsMulticall` for efficiency; the canonical definition binds the hash of `hatsMulticall`.
- Field ordering mirrors the stored `ProposalData` where applicable: submitter, fundingAmount, fundingToken, timelockSec, recipientHatId, hatsMulticall.
- Note: `reservedHatId` (if created) is not included in the `proposalId` hash derivation.

### 3.2 Storage

```
enum ProposalState { None, Active, Approved, Escalated, Canceled, Rejected, Executed }
// Mirrors OpenZeppelin Governor states where applicable; Escalated is Proposal Hatter-specific.

// Storage-optimized struct (5 slots + dynamic bytes):
// Slot 0: submitter (20) + fundingAmount (11) + state (1) = 32 bytes
// Slot 1: fundingToken (20) + eta (8) + timelockSec (4) = 32 bytes
// Slot 2: recipientHatId (32 bytes)
// Slot 3: approverHatId (32 bytes)
// Slot 4: reservedHatId (32 bytes)
// Slot 5+: hatsMulticall (dynamic)
struct ProposalData {
  address submitter;         // 20 bytes
  uint88  fundingAmount;     // 11 bytes (optimized for storage packing)
  ProposalState state;       // 1 byte
  address fundingToken;      // 20 bytes
  uint64  eta;               // 8 bytes (queue time: now + timelockSec)
  uint32  timelockSec;       // 4 bytes (per-proposal delay; 0 = none)
  uint256 recipientHatId;    // 32 bytes
  uint256 approverHatId;     // 32 bytes (per-proposal approver ticket hat id, max supply 1)
  uint256 reservedHatId;     // 32 bytes (per-proposal reserved branch hat id, 0 if none)
  bytes   hatsMulticall;     // dynamic (full encoded payload for Hats Protocol execution & UI surfaces)
}

mapping(bytes32 => ProposalData) public proposals;

// Internal, canonical allowance ledger (monotonic via execute(+), withdraw(-); surfaced via allowanceOf).
mapping(address safe => mapping(uint256 /*hatId*/ => mapping(address /*token*/ => uint88))) internal _allowanceRemaining;

// External integration addresses / roles:
address public immutable HATS_PROTOCOL_ADDRESS;   // fixed at deploy
address public safe;                              // DAO’s Vault (Safe) address (owner‑settable)

uint256 public immutable ownerHatId;              // fixed at deploy (owner = wearer)
uint256 public proposerHatId;                     // owner‑settable
uint256 public executorHatId;                     // owner‑settable; PUBLIC_SENTINEL (1) => public execution
uint256 public escalatorHatId;                    // owner‑settable
uint256 public immutable APPROVER_BRANCH_ID;        // admin under which per‑proposal approver ticket hats are created
uint256 public immutable OPS_BRANCH_ID;             // branch root used for reserved hat validation
uint256 internal constant PUBLIC_SENTINEL = 1;    // sentinel for public execution

bool public proposalsPaused;                      // owner‑settable pause for propose/approve/execute
bool public withdrawalsPaused;                    // owner‑settable pause for withdraw

```

Proposal Hatter’s own allowance ledger is authoritative for governance. Funds move from the Safe only via ProposalHatter’s module calls; Safe owners can disable/remove the module at any time.

---

## 4) Contract Interface

```
// ---- Lifecycle ----
function propose(
  uint88  fundingAmount, // optimized for storage packing
  address fundingToken,
  uint32  timelockSec,   // 0 = no timelock
  uint256 recipientHatId,
  uint256 reservedHatId, // 0 = no reserved hat
  bytes   calldata hatsMulticall,
  bytes32 salt           // optional salt for replaying identical payloads
) external returns (bytes32 proposalId);  // Proposer Hat

function approve(bytes32 proposalId) external;   // Approver Ticket Hat (per-proposal)

function execute(bytes32 proposalId) external;
// Public; if executorHatId != PUBLIC_SENTINEL, caller must wear Executor Hat

function approveAndExecute(bytes32 proposalId) external returns (bytes32);  // Approver Ticket Hat (+ Executor Hat if set)

function escalate(bytes32 proposalId) external;          // Escalator Hat (pre-execution)
function reject(bytes32 proposalId) external;            // Approver Ticket Hat (rejection)
function cancel(bytes32 proposalId) external;            // proposal submitter

// ---- Funding pull (via Safe Module) ----
function withdraw(
  uint256 recipientHatId,
  address safe,
  address token,
  uint88  amount  // optimized for storage packing
) external;  // caller must wear recipientHatId; funds sent to msg.sender

function allowanceOf(address safe, uint256 hatId, address token) external view returns (uint88);
function computeProposalId(
  uint88 fundingAmount,  // optimized for storage packing
  address fundingToken,
  uint32 timelockSec,
  uint256 recipientHatId,
  bytes calldata hatsMulticall,
  bytes32 salt
) external view returns (bytes32);  // Uses msg.sender as the submitter for hashing

// ---- Admin (Owner Hat required) ----
function pauseProposals(bool paused) external;      // Emits ProposalsPaused(paused)
function pauseWithdrawals(bool paused) external;    // Emits WithdrawalsPaused(paused)

function setProposerHat(uint256 hatId) external;    // Emits ProposerHatSet(hatId)
function setEscalatorHat(uint256 hatId) external;   // Emits EscalatorHatSet(hatId)
function setExecutorHat(uint256 hatId) external;    // Emits ExecutorHatSet(hatId); hatId==PUBLIC_SENTINEL enables public execution
function setSafe(address safe) external; // Emits SafeSet(safe)

// ---- Views ----
function OWNER_HAT() external view returns (uint256);
function proposalsPaused() external view returns (bool);
function withdrawalsPaused() external view returns (bool);
```

---

## 5) Semantics

### 5.1 propose(...) — Proposer Hat

- Requires `isWearerOfHat(msg.sender, proposerHatId)`.
- Reverts `ProposalsArePaused()` if proposals are paused.
- Allows `hatsMulticall.length == 0` for funding‑only proposals.
- Computes `proposalId` (per-salt de‑dup) and requires it is unused.
- Creates a per‑proposal Approver Ticket Hat under `approverBranchId` with params: `details = string(proposalId)`, `maxSupply = 1`, `eligibility = EMPTY_SENTINEL`, `toggle = EMPTY_SENTINEL`, `mutable = true`; stores returned `approverHatId`. The hat is not minted by this contract.
- If `reservedHatId != 0`, atomically create the per‑proposal Reserved Branch Hat with that exact id:
  - Let `parent` be the admin/parent hat of `reservedHatId` (ie, the id with the last level stripped).
  - Require `IHats(HATS_PROTOCOL_ADDRESS).getNextId(parent) == reservedHatId` (prevents index races).
  - If `opsBranchId != 0`, require `parent` is a descendant (direct child or deeper) of `opsBranchId`.
  - Call `createHat(parent, details=string(proposalId), maxSupply=1, eligibility=EMPTY_SENTINEL, toggle=EMPTY_SENTINEL, mutable=true, imageURI="")`.
  - Do not mint this hat.
- Stores `ProposalData{ submitter=msg.sender, fundingAmount, state=ProposalState.Active, fundingToken, eta=0, timelockSec, recipientHatId, approverHatId, reservedHatId, hatsMulticall }` (fields ordered for optimal storage packing).
- Event: `Proposed(proposalId, hatsMulticallHash, submitter, fundingAmount, fundingToken, timelockSec, recipientHatId, approverHatId, reservedHatId, salt)`. The `hatsMulticallHash` (keccak256 of the multicall bytes) is emitted for off-chain verification.
- Note: UIs may invoke `computeProposalId` pre-call to verify or display the ID that will be emitted, but they must call from the same address that will submit the proposal. `reservedHatId` is not included in the hash.

### 5.2 approve(proposalId) — Approver Ticket Hat

- Reverts `ProposalsArePaused()` if proposals are paused.
- Requires caller wears this proposal's `approverHatId`.
- Requires current `state == ProposalState.Active`.
- Sets `eta = now + timelockSec` (uses stored per‑proposal `timelockSec`); sets `state = ProposalState.Approved` (proposal approved and awaits ETA).
- Event: `Approved(proposalId, msg.sender, eta)`.

### 5.3 execute(proposalId) — Public / Executor Hat optional

- Reverts `ProposalsArePaused()` if proposals are paused.
- Requires `state == ProposalState.Approved` and `now >= eta`.
- Requires not previously `Escalated`, `Canceled`, or `Rejected` (state-machine: only `ProposalState.Approved` may proceed).
- If `executorHatId != PUBLIC_SENTINEL`, caller must wear Executor Hat.
- Effects (before external calls, per CEI pattern):
  - Increase Proposal Hatter's internal ledger with overflow protection: check that `_allowanceRemaining[safe][recipientHatId][fundingToken] + fundingAmount` does not overflow, then `_allowanceRemaining[safe][recipientHatId][fundingToken] += fundingAmount`.
  - This path is the sole mechanism that increases internal allowances (surfaced via `allowanceOf`).
  - Set state `ProposalState.Executed`.
- Interactions:
  - If `p.hatsMulticall.length > 0`, performs `IHats(HATS_PROTOCOL_ADDRESS).multicall(p.hatsMulticall)` (revert on failure). If `p.hatsMulticall.length == 0`, skip the Hats call (funding‑only proposal).
  - Events: `Executed(proposalId, recipientHatId, safe, fundingToken, fundingAmount, _allowanceRemaining[safe][recipientHatId][fundingToken])`.
- nonReentrant: reentrancy guard prevents reentry across the external call.

### 5.4 approveAndExecute(proposalId) — Approver Ticket Hat (+ Executor Hat if set)

- Reverts `ProposalsArePaused()` if proposals are paused.
- Convenience path to approve and execute an existing proposal in a single call when `timelockSec == 0`.
- Requires caller wears this proposal's `approverHatId`.
- If `executorHatId != PUBLIC_SENTINEL`, caller must also wear the Executor Hat.
- Requires current `state == ProposalState.Active` and stored `timelockSec == 0`.
- Sets `eta = now`, sets `state = ProposalState.Approved`, emits `Approved`, then runs the same execute semantics as `execute(proposalId)`.
- Emits `Approved` and `Executed` (no `Proposed`, since the proposal already exists).

### 5.5 escalate(proposalId) — Escalator Hat

- Allowed when state ∈ {`ProposalState.Active`, `ProposalState.Approved`} and before execution.
- Sets state `ProposalState.Escalated`.
- Event: `Escalated(proposalId, msg.sender)`.
- Effect: An `Escalated` proposal cannot be executed by Proposal Hatter; the DAO may proceed via its own governance paths outside Proposal Hatter if desired.
- Reserved hat is left untouched on escalate.

### 5.6 cancel(proposalId) — proposal submitter

- Allowed when state ∈ {`ProposalState.Active`, `ProposalState.Approved`} anytime pre‑execution (no pre‑ETA restriction).
- Sets state `ProposalState.Canceled`.
- Event: `Canceled(proposalId, by)`.
- Cleanup: if `reservedHatId != 0`, set its toggle to `address(this)` via `Hats.changeHatToggle(reservedHatId, address(this))`, then deactivate via `Hats.setHatStatus(reservedHatId, false)`.

### 5.7 reject(proposalId) — Approver Ticket Hat (decider rejection)

- Requires caller wears this proposal's `approverHatId`.
- Allowed when state == `ProposalState.Active`.
- Sets state `ProposalState.Rejected`.
- Event: `Rejected(proposalId, by)`.
- Rationale: models a committee rejection akin to Governor’s `Rejected` outcome.
- Cleanup: if `reservedHatId != 0`, set its toggle to `address(this)` via `Hats.changeHatToggle(reservedHatId, address(this))`, then deactivate via `Hats.setHatStatus(reservedHatId, false)`.

### 5.8 withdraw(recipientHatId, safe, token, amount) — Recipient Hat wearer

- Reverts `WithdrawalsArePaused()` if withdrawals are paused.
- Checks:
  - Requires caller wears `recipientHatId`.
  - Requires `_allowanceRemaining[safe][recipientHatId][token] >= amount`.
- Effects (before external calls, per CEI pattern):
  - Decrement internal allowance: `_allowanceRemaining[safe][recipientHatId][token] -= amount`.
  - This pathway is the only mechanism that reduces internal allowances (outside of revert rollbacks).
- Interactions:
  - Execute a Safe module transaction via `execTransactionFromModuleReturnData` (Safe v1.4.1, `Enum.Operation.Call` only):
    - ETH: `to = msg.sender`, `value = amount`, `data = ""`, `operation = Call`.
    - ERC‑20: `to = token`, `value = 0`, `data = abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, amount)`, `operation = Call`.
  - On return, require `success == true`. For ERC‑20, additionally validate return data:
    - If `returnData.length == 0`, accept (ERC‑20s that do not return a value).
    - Else decode as `bool ok` and require `ok == true`; otherwise revert `ERC20TransferReturnedFalse(token, returnData)`.
  - These patterns should follow the OpenZeppelin SafeERC20 library patterns (modified for the Safe module execution, of course).
  - Event: `AllowanceConsumed(recipientHatId, safe, token, amount, remaining, msg.sender)`.
- Emits the payout destination (msg.sender) for downstream auditing.
- nonReentrant: reentrancy guard prevents reentry via token hooks or module callbacks.

Decimals & amounts:
- `amount` is always specified in the token’s base units. The contract does not query or normalize `decimals()`; UIs should display/collect human amounts using off‑chain `decimals()` reads (or curated metadata) and convert to base units before calling `withdraw`. This avoids on‑chain failures from non‑standard or missing `decimals()` implementations and eliminates rounding ambiguity (e.g., USDC’s 6 decimals vs 18‑decimals tokens).

Module call note (Safe 1.4.1): use `execTransactionFromModuleReturnData(address to, uint256 value, bytes memory data, Enum.Operation operation) returns (bool success, bytes memory returnData)`. ProposalHatter must be an enabled module on the Safe. Delegatecall is never used.

### 5.9 Admin (Owner Hat)

- `pauseProposals(bool paused)`
  - Only owner (caller must wear `ownerHatId`).
  - Sets `proposalsPaused = paused` and emits `ProposalsPaused(paused)`.
  - When paused, `propose`, `approve`, `approveAndExecute`, and `execute` revert with `ProposalsArePaused()` for all callers (including the owner).

- `pauseWithdrawals(bool paused)`
  - Only owner.
  - Sets `withdrawalsPaused = paused` and emits `WithdrawalsPaused(paused)`.
  - When paused, `withdraw` reverts with `WithdrawalsArePaused()` for all callers (including the owner).

- `setProposerHat(uint256 hatId)`
  - Only owner. No branch constraints.
  - Sets `proposerHatId = hatId` and emits `ProposerHatSet(hatId)`.

- `setEscalatorHat(uint256 hatId)`
  - Only owner. No branch constraints.
  - Sets `escalatorHatId = hatId` and emits `EscalatorHatSet(hatId)`.

- `setExecutorHat(uint256 hatId)`
  - Only owner. No branch constraints.
  - Setting to `PUBLIC_SENTINEL` (1) enables public execution; otherwise execution requires this hat.
  - Sets `executorHatId = hatId` and emits `ExecutorHatSet(hatId)`.

- `setSafe(address safe)`
  - Only owner. `safe` must be non‑zero or revert `ZeroAddress()`.  
  - Updates `safe` and emits `SafeSet(safe)`.
  - Takes effect immediately for future `withdraw` calls; proposals and internal ledger are unaffected.

---

## 6) Events

```solidity
event Proposed(
  bytes32 indexed proposalId,
  bytes32 indexed hatsMulticallHash,  // keccak256(hatsMulticall) for off-chain verification
  address indexed submitter,
  uint256 fundingAmount,
  address fundingToken,
  uint32 timelockSec,
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
  address indexed to  // always msg.sender
);

event ProposalHatterDeployed(address hatsProtocol, uint256 ownerHatId, uint256 approverBranchId, uint256 opsBranchId);

// Admin + pause events
event ProposalsPaused(bool paused);
event WithdrawalsPaused(bool paused);
event ProposerHatSet(uint256 hatId);
event EscalatorHatSet(uint256 hatId);
event ExecutorHatSet(uint256 hatId);
event SafeSet(address safe);

```

---

## 7) Invariants

- Exact‑bytes execution: only the stored `hatsMulticall` bytes can be executed when present. Funding‑only proposals (empty `hatsMulticall`) execute without a Hats call.
- Atomicity: if the Hats call fails, nothing changes (no funding approval).
- Spend monotonicity and authority:
  - `_allowanceRemaining` increases only via successful `execute`.
  - `_allowanceRemaining` decreases only via `withdraw`.
  - Maximum allowance per hat is `type(uint88).max` for storage optimization while maintaining sufficient range.
- Treasury custody: decider trust zone (eg committee) has no access; Proposal Hatter is the only actor orchestrating transfers via the Safe module interface; Safe owners can disable/remove the module at any time.
- Replay safety: `proposalId` binds chain, this contract, Hats Protocol target, payload bytes, recipient hat, token, amount, timelock, submitter, and salt. Identical inputs with the same salt are deduped per submitter; choosing a new salt permits a fresh proposal for the same payload.
- State machine: No execution if state ∈ {`ProposalState.Escalated`, `ProposalState.Canceled`, `ProposalState.Rejected`, `ProposalState.Executed`}.
- Pauses: when `proposalsPaused == true`, `propose`, `approve`, `approveAndExecute`, and `execute` revert with `ProposalsArePaused()` for all callers (including the owner). When `withdrawalsPaused == true`, `withdraw` reverts with `WithdrawalsArePaused()`. `escalate`, `reject`, and `cancel` remain callable.

---

## 8) Errors (custom errors recommended)

- `error NotAuthorized();`
- `error InvalidState(ProposalState current);`
- `error TooEarly(uint64 eta, uint64 nowTs);`
- `error AllowanceExceeded(uint256 remaining, uint256 requested);`
- `error AlreadyUsed(bytes32 proposalId);`
- `error ZeroAddress();`
- `error InvalidReservedHatId();`
- `error InvalidReservedHatBranch();`
- `error ProposalsArePaused();`
- `error WithdrawalsArePaused();`
- `error SafeExecutionFailed(bytes returnData);`
- `error ERC20TransferReturnedFalse(address token, bytes returnData);`
- `error ERC20TransferMalformedReturn(address token, bytes returnData);`

---

## 9) Safe Module Wiring (runbook)

One‑time setup (DAO owners on the Safe):

1) Enable ProposalHatter as a module on the Safe (UI or programmatically). Safe version: v1.4.1.

During operation:

- Executing a proposal in Proposal Hatter increments internal allowances; it does not affect Safe owner settings.
- Withdrawals call the Safe via `execTransactionFromModuleReturnData`. If a withdrawal fails at the token or ETH transfer layer, the transaction reverts and the internal ledger rollback is preserved.
- If the DAO migrates the Safe, the owner can update the target via `setSafe(newSafe)`. Future withdrawals use the new address; existing proposals and internal ledger are unchanged.


---

## 10) Security Considerations

- Withdrawal execution surface: ProposalHatter performs Safe module calls with `Enum.Operation.Call` only; no delegatecalls.
- ERC‑20 success handling: Accepts no‑return tokens and requires `true` when a boolean is returned. Non‑standard tokens may still misbehave; governance SHOULD prefer standard ERC‑20s for treasury.
- Permissions: Safe owners can remove/disable ProposalHatter as a module to halt withdrawals immediately.
- Reentrancy: Guard `execute` and `withdraw` (`nonReentrant`, CEI). Safe’s module call is the last interaction in `withdraw`.
- External calls: (a) Hats Protocol in `execute` via `IHats.multicall`, (b) Safe module call in `withdraw` via `execTransactionFromModuleReturnData`. Revert on failure. 
- Revocation halts system: DAO can revoke Proposer/Approver/Executor Hats in Hats Protocol and/or disable the Safe module to freeze payouts immediately.

---

## 11) Test Plan (acceptance)

Lifecycle

- Propose → Approve → Execute happy path (with/without timelock).
- Public execution when `executorHatId == PUBLIC_SENTINEL`; restricted when set.
- Duplicates: proposing identical inputs with the same salt rejects with `AlreadyUsed`; changing the salt permits a new proposal.

Calldata integrity

- Allow zero-length `hatsMulticall` at `propose` to support funding-only proposals; `execute` must succeed and skip the Hats call.
- For proposals with a non-empty `hatsMulticall`, if the stored bytes are cleared/missing before `execute`, revert.
- Reading proposal data returns the exact stored `hatsMulticall` bytes.

Escalation / Cancel / Rejection

- `escalate` (Escalator Hat) blocks execution.
- `cancel` by submitter at any time pre‑execution.
- `reject` by Approver Ticket Hat wearer sets proposal to `Rejected` and blocks execution.

Withdrawals

- Non‑wearer cannot withdraw.
- Wearer withdraw ≤ remaining → Proposal Hatter decrements and Safe module call succeeds.
- Wearer withdraw > remaining → `AllowanceExceeded`.
- Safe module failure (e.g., ETH transfer revert, token revert) → revert `SafeExecutionFailed` (with return data) and ledger is reverted.

ERC‑20 return handling

- Token returns no data → treated as success.
- Token returns boolean `false` → revert `ERC20TransferReturnedFalse`.

Reentrancy

- Malicious token hook tries to reenter `withdraw` → blocked by `nonReentrant`.
- External reentry attempt into `execute` during Hats call → blocked by `nonReentrant`.

---

---

## 12) Non‑goals (v1)

- Policy tiers, Reality‑based challenges, per‑epoch program budgets, stream/drip schedules (can be layered later without changing the Safe wiring).
- Auto‑provisioning Safe module limits from Proposal Hatter (module limits are owner‑set per Safe UX/API).
- Interface abstraction/adapters for multiple module versions; upgrades will be handled by revoking Proposal Hatter’s hat and minting it to a new contract version, with any allowance data migration handled in that process.
- Support for Hats trees that are linked or nested across multiple branches; this version assumes all relevant hats live within a single branch.

---

End of spec.
