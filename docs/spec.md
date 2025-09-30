# ProposalHatter.sol — Functional Specification

Status: Draft v1.5

Date: 2025-09-29

Author: Spencer

Implementer: Codex

Scope: Single contract (ProposalHatter.sol). No proxy/upgradability assumed unless noted.

---

## 0) Purpose & Summary

We want decider trust zones (hats) to approve exactly-specified Hats changes and bounded funding, without giving the decider custody of funds or access controls. Proposals hash‑commit the precise Hats `multicall` bytes and the funding allowance for a Recipient Hat. After an optional timelock, anyone (or an address wearing an Executor Hat, if set) can execute the proposal. Funding is pull‑based: a Recipient Hat wearer calls Proposal Hatter, which (a) verifies entitlement and internal allowance, then (b) instructs the Safe AllowanceModule to transfer ETH/ERC‑20 from the DAO’s vault to the recipient.

Concurrency model: Each proposal has its own decider trust zone (hat) and its own optional reserved Hats subtree.
- A unique per‑proposal Approver Ticket Hat is created at propose‑time and later minted to the selected decider; only a wearer of this hat can approve or reject that proposal.
- Optionally, a per‑proposal Reserved Branch Hat is created at propose‑time (if a non‑zero branch root is supplied), reserving a namespace under which the proposal’s operational hats can be created without index races.

Funding‑only proposals are supported: if a proposal’s `hatsMulticall` bytes are empty, it still must be executed to activate the internal allowance and enable withdrawals. In that case, the contract skips calling Hats Protocol and only applies the funding effects.

This spec is for a minimal version of this concept that, if successful, will be updated in future iterations. This version should minimize complexity and focus on the core functionality, with regards to both implementation of the contract and to make user interfaces as simple and cheap to implement as possible.

---

## 1) External Dependencies & Ownership Model

- Vault = Safe. The DAO is the Safe owner(s) and can execute arbitrary transactions via normal Safe flows (multisig or delegate to governance).
- AllowanceModule (Safe "Spending Limits") is enabled for that Safe. It lets Safe owners assign spending limits (one-time or periodic) per token/ETH to a delegate/beneficiary—here, ProposalHatter.sol is configured as the **delegate** with permission to execute transfers within owner-set limits. Hat wearers calling `withdraw()` are the **beneficiaries** who receive the funds.
- Hats Protocol (`HATS_PROTOCOL_ADDRESS`), used for `isWearerOfHat` and to run the exact multicall payload.

Hats integration calls used:
- `createHat(admin, details, maxSupply, eligibility, toggle, mutable, imageURI)` to create per-proposal ticket hats and optional reserved hats.
- `changeHatToggle(hatId, newToggle)` then `setHatStatus(hatId, false)` to deactivate a reserved hat on cancel/reject.

Hats module address requirements: modules cannot be zero-address. This spec uses `EMPTY_SENTINEL = address(1)` for “no eligibility/toggle module”.

Operational note: The DAO must configure Proposal Hatter with adequate per-asset limits in the Safe’s AllowanceModule, at least as large as the expected aggregate withdrawals between top-ups. Limits can be periodic or one-time; owners can adjust them as needed via the Safe UI/API.

ETH sentinel: `address(0)` denotes native ETH in all references below.

Constructor wiring:

- `HATS_PROTOCOL_ADDRESS` is immutable and set at deploy.
- `safe` (the DAO Safe) and `allowanceModule` addresses are set in the constructor and never change post-deploy.
- `approverBranchId` is set in the constructor (admin under which per-proposal approver ticket hats are created) and is immutable thereafter.
- `opsBranchId` is set in the constructor (branch root used for validation of per-proposal reserved hats) and is immutable thereafter.
- Role hat IDs (`proposerHatId`, `executorHatId`, `escalatorHatId`) are set in the constructor and cannot be updated. There is no global Approver Hat.
- Proposal Hatter has no owner role; the deployment parameters above define the entire administrative surface area.
- Internal allowance balances can only be increased by executed proposals and decreased by withdrawals; there is no administrative path to adjust them.

---

## 2) Roles (Hat IDs, checked at call time)

- Proposer Hat — required to propose.
- Approver Ticket Hat — per-proposal hat created by `propose` (under `approverBranchId`) and minted operationally to the chosen decider; required to approve/reject and approveAndExecute for that proposal only.
- Executor Hat (optional) — if unset (`0`), any address may execute after the proposal's ETA; if set, caller must wear this hat.
- Escalator Hat — may escalate (pre-execution veto to full DAO path).

Additionally, each proposal has a Recipient Hat, which is the hat authorized to withdraw funds from the vault.

All role checks use `Hats.isWearerOfHat(msg.sender, roleHatId)` at call time. There is no contract owner; once deployed, role assignments remain fixed until a new deployment occurs.

Sentinels

- `PUBLIC_SENTINEL = 1` — never a valid Hats ID; indicates public execution when set as `executorHatId`.
- `EMPTY_SENTINEL = address(1)` — used when creating hats to indicate “no eligibility module” and “no toggle module” (Hats requires non‑zero module addresses).

---

## 3) Data Model

### 3.1 Proposal identity & hashing

Inputs defining a proposal:

- `hatsMulticall`: `bytes` (exact payload for Hats Protocol)
- `recipientHatId`: `uint256`
- `fundingToken`: `address` (ERC‑20 or ETH sentinel `address(0)`)
- `fundingAmount`: `uint256`
- `timelockSec`: `uint64` (0 = no timelock)
- `submitter`: `address` (caller of `propose`)
- `reservedHatId`: `uint256` (optional; if non‑zero, this exact hat id is created at propose‑time; its parent must be a descendant of `opsBranchId` when `opsBranchId != 0`)
- `salt`: `bytes32` (optional; differentiate repeated proposals with identical parameters)

Deterministic IDs (global de‑duplication):

```
hatsMulticallHash = keccak256(hatsMulticall);
proposalId = keccak256(
  abi.encode(
    block.chainid,
    address(this),
    HATS_PROTOCOL_ADDRESS,
    hatsMulticallHash,
    recipientHatId,
    fundingToken,
    fundingAmount,
    timelockSec,
    salt
  )
);
```

Notes:

- Per-salt de‑duplication: `proposalId` excludes `submitter` but includes `salt`. Proposing identical inputs with the same salt yields the same `proposalId` and must be unused; changing the salt creates a new `proposalId` for an otherwise identical payload.
- `salt` is optional (e.g., `0x00`) and is emitted for provenance.
- Full `hatsMulticall` calldata is persisted alongside each proposal for first-party UIs; integrity checks compare supplied calldata to the stored bytes.
- Helper: `computeProposalId(...)` (see Interface) mirrors this hashing logic on-chain for UI/explorer consumption. Implementations may pre-hash `hatsMulticall` for efficiency; the canonical definition binds the hash of `hatsMulticall`.
- Note: `reservedHatId` (if created) is not included in the `proposalId` hash derivation.

### 3.2 Storage

```
enum ProposalState { None, Active, Succeeded, Escalated, Canceled, Defeated, Executed }
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

// Internal, canonical allowance ledger (monotonic via execute(+), withdraw(-); no admin adjustments).
mapping(uint256 /*hatId*/ => mapping(address /*token*/ => uint88)) public allowanceRemaining;

// External integration addresses / roles:
address public immutable HATS_PROTOCOL_ADDRESS;   // fixed at deploy
address public immutable safe;                    // DAO’s Safe address
address public immutable allowanceModule;         // Safe AllowanceModule (Spending Limits)

uint256 public immutable proposerHatId;
uint256 public immutable executorHatId; // PUBLIC_SENTINEL (1) => public execution
uint256 internal constant PUBLIC_SENTINEL = 1; // sentinel for public execution
uint256 public immutable escalatorHatId;
uint256 public immutable approverBranchId; // admin under which per-proposal approver ticket hats are created
uint256 public immutable opsBranchId; // admin under which per-proposal operational hats are created

```

Proposal Hatter’s own allowance ledger is authoritative for governance. The Safe’s AllowanceModule is an outer guardrail; it must be configured with an owner‑set limit ≥ the near‑term total Proposal Hatter will spend per asset.

---

## 4) Contract Interface

```
// ---- Lifecycle ----
function propose(
  bytes   calldata hatsMulticall,
  uint256 recipientHatId,
  address fundingToken,
  uint88  fundingAmount, // optimized for storage packing
  uint32  timelockSec,   // 0 = no timelock
  uint256 reservedHatId, // 0 = no reserved hat
  bytes32 salt           // optional salt for replaying identical payloads
) external returns (bytes32 proposalId);  // Proposer Hat

function approve(bytes32 proposalId) external;   // Approver Ticket Hat (per-proposal)

function execute(bytes32 proposalId) external;
// Public; if executorHatId != PUBLIC_SENTINEL, caller must wear Executor Hat

function approveAndExecute(bytes32 proposalId) external returns (bytes32);  // Approver Ticket Hat (+ Executor Hat if set)

function escalate(bytes32 proposalId) external;          // Escalator Hat (pre-execution)
function reject(bytes32 proposalId) external;            // Approver Ticket Hat (rejection)
function cancel(bytes32 proposalId) external;            // proposal submitter

// ---- Funding pull (via Safe AllowanceModule) ----
function withdraw(
  uint256 recipientHatId,
  address token,
  uint88  amount  // optimized for storage packing
) external;  // caller must wear recipientHatId; funds sent to msg.sender

function allowanceOf(uint256 hatId, address token) external view returns (uint88);
function computeProposalId(
  bytes calldata hatsMulticall,
  uint256 recipientHatId,
  address fundingToken,
  uint88 fundingAmount,  // optimized for storage packing
  uint32 timelockSec,
  bytes32 salt
) external view returns (bytes32);

// No admin surface: deployment parameters are immutable.
```

---

## 5) Semantics

### 5.1 propose(...) — Proposer Hat

- Requires `isWearerOfHat(msg.sender, proposerHatId)`.
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
- Event (indexed): `Proposed(proposalId, hatsMulticallHash, submitter, recipientHatId, fundingToken, fundingAmount, timelockSec, approverHatId, reservedHatId, salt)`. The `hatsMulticallHash` (keccak256 of the multicall bytes) is emitted for off-chain verification.
- Note: UIs may invoke `computeProposalId` pre-call to verify or display the ID that will be emitted. `reservedHatId` is not included in the hash.

### 5.2 approve(proposalId) — Approver Ticket Hat

- Requires caller wears this proposal's `approverHatId`.
- Requires current `state == ProposalState.Active`.
- Sets `eta = now + timelockSec` (uses stored per‑proposal `timelockSec`); sets `state = ProposalState.Succeeded` (proposal succeeded and awaits ETA).
- Event: `Succeeded(proposalId, msg.sender, eta)`.

### 5.3 execute(proposalId) — Public / Executor Hat optional

- Requires `state == ProposalState.Succeeded` and `now >= eta`.
- Requires not previously `Escalated`, `Canceled`, or `Defeated` (state-machine: only `ProposalState.Succeeded` may proceed).
- If `executorHatId != PUBLIC_SENTINEL`, caller must wear Executor Hat.
- Effects (before external calls, per CEI pattern):
  - Increase Proposal Hatter's internal ledger with overflow protection: check that `allowanceRemaining[recipientHatId][fundingToken] + fundingAmount` does not overflow, then `allowanceRemaining[recipientHatId][fundingToken] += fundingAmount`.
  - This path is the sole mechanism that increases internal allowances.
  - Set state `ProposalState.Executed`.
- Interactions:
  - If `p.hatsMulticall.length > 0`, performs `IHats(HATS_PROTOCOL_ADDRESS).multicall(p.hatsMulticall)` (revert on failure). If `p.hatsMulticall.length == 0`, skip the Hats call (funding‑only proposal).
  - Events: `Executed(proposalId, recipientHatId, fundingToken, fundingAmount, allowanceRemaining[recipientHatId][fundingToken])`.
- nonReentrant: reentrancy guard prevents reentry across the external call.

### 5.4 approveAndExecute(proposalId) — Approver Ticket Hat (+ Executor Hat if set)

- Convenience path to approve and execute an existing proposal in a single call when `timelockSec == 0`.
- Requires caller wears this proposal's `approverHatId`.
- If `executorHatId != PUBLIC_SENTINEL`, caller must also wear the Executor Hat.
- Requires current `state == ProposalState.Active` and stored `timelockSec == 0`.
- Sets `eta = now`, sets `state = ProposalState.Succeeded`, emits `Succeeded`, then runs `execute(proposalId)`.
- Emits `Succeeded` and`Executed` (no `Proposed`, since the proposal already exists).

### 5.5 escalate(proposalId) — Escalator Hat

- Allowed when state ∈ {`ProposalState.Active`, `ProposalState.Succeeded`} and before execution.
- Sets state `ProposalState.Escalated`.
- Event: `Escalated(proposalId, msg.sender)`.
- Effect: An `Escalated` proposal cannot be executed by Proposal Hatter; the DAO may proceed via its own governance paths outside Proposal Hatter if desired.
- Reserved hat is left untouched on escalate.

### 5.6 cancel(proposalId) — proposal submitter

- Allowed when state ∈ {`ProposalState.Active`, `ProposalState.Succeeded`} anytime pre‑execution (no pre‑ETA restriction).
- Sets state `ProposalState.Canceled`.
- Event: `Canceled(proposalId, by)`.
- Cleanup: if `reservedHatId != 0`, set its toggle to `address(this)` via `Hats.changeHatToggle(reservedHatId, address(this))`, then deactivate via `Hats.setHatStatus(reservedHatId, false)`.

### 5.7 reject(proposalId) — Approver Ticket Hat (decider rejection)

- Requires caller wears this proposal's `approverHatId`.
- Allowed when state == `ProposalState.Active`.
- Sets state `ProposalState.Defeated`.
- Event: `Defeated(proposalId, by)`.
- Rationale: models a committee rejection akin to Governor’s `Defeated` outcome.
- Cleanup: if `reservedHatId != 0`, set its toggle to `address(this)` via `Hats.changeHatToggle(reservedHatId, address(this))`, then deactivate via `Hats.setHatStatus(reservedHatId, false)`.

### 5.8 withdraw(recipientHatId, token, amount) — Recipient Hat wearer

- Checks:
  - Requires caller wears `recipientHatId`.
  - Requires `allowanceRemaining[recipientHatId][token] >= amount`.
- Effects (before external calls, per CEI pattern):
  - Decrement internal allowance: `allowanceRemaining[recipientHatId][token] -= amount`.
  - This pathway is the only mechanism that reduces internal allowances (outside of revert rollbacks).
- Interactions:
  - Instruct the Safe AllowanceModule to transfer funds from the Safe to `msg.sender`:
    - ETH: `token == address(0)`.
    - ERC‑20: `token` is the token address.
  - Any revert from AllowanceModule bubbles up and reverts the entire transaction (including allowance changes).
  - Event: `AllowanceConsumed(recipientHatId, token, amount, remaining, msg.sender)`.
- Emits the payout destination (msg.sender) for downstream auditing.
- nonReentrant: reentrancy guard prevents reentry via token hooks or module callbacks.

Module call note: Use `AllowanceModule.executeAllowanceTransfer(address safe, address token, address to, uint96 amount, address paymentToken, uint96 payment, address delegate, bytes signature)`, passing `safe` from storage, `paymentToken = address(0)`, `payment = 0`, `delegate = address(this)`, and `signature = ""` (empty bytes). ETH is represented by `token == address(0)`. The module treats an empty signature as authorization by `msg.sender`, so Proposal Hatter must be configured as the delegate for the Safe in the AllowanceModule.

---

## 6) Events (all indexed)

```solidity
event Proposed(
  bytes32 indexed proposalId,
  bytes32 indexed hatsMulticallHash,  // keccak256(hatsMulticall) for off-chain verification
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
  uint256 indexed recipientHatId,
  address indexed token,
  uint256 amount,
  uint256 remaining,
  address indexed to  // always msg.sender
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

```

---

## 7) Invariants

- Exact‑bytes execution: only the stored `hatsMulticall` bytes can be executed when present. Funding‑only proposals (empty `hatsMulticall`) execute without a Hats call.
- Atomicity: if the Hats call fails, nothing changes (no funding approval).
- Spend monotonicity and authority:
  - `allowanceRemaining` increases only via successful `execute`.
  - `allowanceRemaining` decreases only via `withdraw`.
  - Maximum allowance per hat is `type(uint88).max` for storage optimization while maintaining sufficient range.
- Treasury custody: committee has no access; Proposal Hatter is the only actor orchestrating transfers via the Safe's AllowanceModule within owner‑set module limits.
- Replay safety: `proposalId` binds chain, this contract, Hats Protocol target, payload bytes, recipient hat, token, amount, timelock, and salt. Identical inputs with the same salt are deduped; choosing a new salt permits a fresh proposal for the same payload.
- State machine: No execution if state ∈ {`ProposalState.Escalated`, `ProposalState.Canceled`, `ProposalState.Defeated`, `ProposalState.Executed`}.

---

## 8) Errors (custom errors recommended)

- `error NotAuthorized();`
- `error InvalidState(ProposalState current);`
- `error TooEarly(uint64 eta, uint64 nowTs);`
- `error AllowanceExceeded(uint256 remaining, uint256 requested);`
- `error AlreadyUsed(bytes32 proposalId);`
- `error ZeroAddress();`

---

## 9) Safe + AllowanceModule Wiring (runbook)

One‑time setup (DAO owners on the Safe):

1) Enable the AllowanceModule on the Safe (UI or programmatically).
2) Add Proposal Hatter as a delegate and set spending limits for it:
   - For each asset (ETH and specific ERC‑20s), set a limit (one‑time or periodic) large enough for near‑term operations.
   - Automate top‑ups as part of DAO ops cadence if desired.
3) (Optional) Attach Zodiac Roles Modifier to the Safe to further constrain which modules/selectors are callable.

During operation:

- Executing a proposal in Proposal Hatter increments internal allowances; it does not auto‑change Safe module limits.
- Withdrawals call the AllowanceModule to move funds from the Safe. If a Safe module limit is lower than Proposal Hatter's internal ledger for that token, the module will revert and the allowance change will be rolled back—ops should raise the module limit as needed.

Audits / Lindy:

- Safe core and the AllowanceModule have public audits and ongoing bug bounties.

---

## 10) Security Considerations

- Two layers of limit: Proposal Hatter’s governance‑canonical ledger + Safe’s module limit. Either can stop a withdrawal; both must allow it.
- Compromise model: If Proposal Hatter is compromised, module limits cap outflows; keep them “as low as practical” and top‑up operationally.
- Reentrancy: Guard `execute` and `withdraw` (`nonReentrant`, CEI).
- External calls: Only two: (a) Hats Protocol in `execute` via `IHats.multicall`, (b) AllowanceModule in `withdraw` via `executeAllowanceTransfer`. Revert on failure. For AllowanceModule, an empty signature uses `msg.sender` as signer; ensure Proposal Hatter is the configured delegate.
- Revocation halts system: DAO can revoke Proposer/Approver/Executor Hats in Hats Protocol, or reduce/disable the Safe’s module limits to freeze payouts immediately.

---

## 11) Test Plan (acceptance)

Lifecycle

- Propose → Succeed → Execute happy path (with/without timelock).
- Public execution when `executorHatId == PUBLIC_SENTINEL`; restricted when set.
- Duplicates: proposing identical inputs with the same salt rejects with `AlreadyUsed`; changing the salt permits a new proposal.

Calldata integrity

- Allow zero-length `hatsMulticall` at `propose` to support funding-only proposals; `execute` must succeed and skip the Hats call.
- For proposals with a non-empty `hatsMulticall`, if the stored bytes are cleared/missing before `execute`, revert.
- Reading proposal data returns the exact stored `hatsMulticall` bytes.

Escalation / Cancel / Defeat

- `escalate` (Escalator Hat) blocks execution.
- `cancel` by submitter at any time pre‑execution.
- `reject` by Approver Ticket Hat wearer sets proposal to `Defeated` and blocks execution.

Withdrawals

- Non‑wearer cannot withdraw.
- Wearer withdraw ≤ remaining → Proposal Hatter decrements and module transfer succeeds.
- Wearer withdraw > remaining → `AllowanceExceeded`.
- Module failure (e.g., mocked revert) → bubbles up original error and ledger is reverted.

Module limit interaction

- Simulate module cap lower than Proposal Hatter’s ledger → transfer hits module cap and fails; further transfers must wait for ops to increase module limit.

Reentrancy

- Malicious token hook tries to reenter `withdraw` → blocked by `nonReentrant`.
- External reentry attempt into `execute` during Hats call → blocked by `nonReentrant`.

---

## 12) Reference pseudocode (selected)

```solidity
function propose(...) external returns (bytes32 id) {
  if (!Hats.isWearerOfHat(msg.sender, proposerHatId)) revert NotAuthorized();
  bytes32 hatsHash = keccak256(hatsMulticall);
  id = keccak256(abi.encode(block.chainid, address(this), HATS_PROTOCOL_ADDRESS,
                            hatsHash, recipientHatId, fundingToken, fundingAmount, uint32(timelockSec), salt));
  if (proposals[id].state != ProposalState.None) revert AlreadyUsed(id);

  // Create per-proposal approver ticket hat under approverBranchId (details = proposalId)
  uint256 approverHatId = IHats(HATS_PROTOCOL_ADDRESS).createHat(
    approverBranchId,
    Strings.toHexString(id),
    1,
    EMPTY_SENTINEL,
    EMPTY_SENTINEL,
    true,
    ""
  );

  // Optionally create reserved branch hat with exact id = reservedHatId (details = proposalId)
  uint256 reservedHatId = 0;
  if (inputReservedHatId != 0) {
    // derive parent id from the input hat id
    uint256 parent = parentOf(inputReservedHatId);
    // must be the next child to prevent index races
    if (IHats(HATS_PROTOCOL_ADDRESS).getNextId(parent) != inputReservedHatId) revert InvalidReservedHatId();
    // if opsBranchId is set, require parent is a descendant of opsBranchId
    if (opsBranchId != 0 && !isDescendant(parent, opsBranchId)) revert InvalidReservedHatBranch();
    // create the reserved hat under its parent
    reservedHatId = IHats(HATS_PROTOCOL_ADDRESS).createHat(
      parent,
      Strings.toHexString(id),
      1,
      EMPTY_SENTINEL,
      EMPTY_SENTINEL,
      true,
      ""
    );
    // sanity: ensure returned id matches input
    assert(reservedHatId == inputReservedHatId);
  }

  proposals[id] = ProposalData({
    submitter: msg.sender,
    fundingAmount: fundingAmount,
    state: ProposalState.Active,
    fundingToken: fundingToken,
    eta: 0,
    timelockSec: timelockSec,
    recipientHatId: recipientHatId,
    approverHatId: approverHatId,
    reservedHatId: reservedHatId,
    hatsMulticall: hatsMulticall
  });

  bytes32 hatsMulticallHash = keccak256(hatsMulticall);
  emit Proposed(id, hatsMulticallHash, msg.sender, recipientHatId, fundingToken, fundingAmount, uint32(timelockSec), approverHatId, reservedHatId, salt);
}

function execute(bytes32 id) external nonReentrant {
  ProposalData storage p = proposals[id];
  // checks
  if (p.state != ProposalState.Succeeded) revert InvalidState(p.state);
  if (block.timestamp < p.eta) revert TooEarly(uint64(p.eta), uint64(block.timestamp));
  if (executorHatId != PUBLIC_SENTINEL && !Hats.isWearerOfHat(msg.sender, executorHatId)) revert NotAuthorized();
  
  // effects
  uint88 currentAllowance = allowanceRemaining[p.recipientHatId][p.fundingToken];
  uint88 newAllowance = currentAllowance + p.fundingAmount;
  allowanceRemaining[p.recipientHatId][p.fundingToken] = newAllowance;
  p.state = ProposalState.Executed;

  // interactions
  if (p.hatsMulticall.length > 0) {
    IHats(HATS_PROTOCOL_ADDRESS).multicall(p.hatsMulticall);
  }

  emit Executed(id, p.recipientHatId, p.fundingToken, p.fundingAmount, newAllowance);
}

function withdraw(uint256 recipientHatId, address token, uint88 amount)
  external nonReentrant
{
  // checks
  if (!Hats.isWearerOfHat(msg.sender, recipientHatId)) revert NotAuthorized();
  uint88 rem = allowanceRemaining[recipientHatId][token];
  if (rem < amount) revert AllowanceExceeded(rem, amount);

  // effects
  uint88 newAllowance = rem - amount;
  allowanceRemaining[recipientHatId][token] = newAllowance;

  // interactions: call AllowanceModule to move funds from Safe to msg.sender
  // Signature: executeAllowanceTransfer(address safe, address token, address to, uint96 amount, address paymentToken, uint96 payment, address delegate, bytes signature)
  // Use delegate = address(this) and signature = empty bytes to authorize as the configured delegate
  // Any revert from the module will bubble up and revert the entire transaction
  AllowanceModule(allowanceModule).executeAllowanceTransfer(
    safe,
    token,
    msg.sender,
    uint96(amount),
    address(0),
    0,
    address(this),
    bytes("")
  );

  emit AllowanceConsumed(recipientHatId, token, amount, newAllowance, msg.sender);
}

// Constructor (summary)
// constructor(
//   address hatsProtocol,
//   address safe_,
//   address allowanceModule_,
//   uint256 proposer,
//   uint256 executor,
//   uint256 escalator,
//   uint256 approverBranchId_,
//   uint256 opsBranchId_,
// ) { ... }
// - Sets immutable HATS_PROTOCOL_ADDRESS = hatsProtocol
// - Sets safe = safe_ and allowanceModule = allowanceModule_
// - Sets immutable role hat IDs (no global Approver) and immutable branch ids to the provided values
```

> Module call signature fixed in this spec: `executeAllowanceTransfer(address safe, address token, address to, uint96 amount, address paymentToken, uint96 payment, address delegate, bytes signature)`.

---

## 13) Non‑goals (v1)

- Policy tiers, Reality‑based challenges, per‑epoch program budgets, stream/drip schedules (can be layered later without changing the Safe wiring).
- Auto‑provisioning Safe module limits from Proposal Hatter (module limits are owner‑set per Safe UX/API).
- Interface abstraction/adapters for multiple module versions; upgrades will be handled by revoking Proposal Hatter’s hat and minting it to a new contract version, with any allowance data migration handled in that process.
- Support for Hats trees that are linked or nested across multiple branches; this version assumes all relevant hats live within a single branch.

---

End of spec.
