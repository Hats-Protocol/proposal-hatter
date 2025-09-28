# ProposalHatter.sol — Functional Specification

Status: Draft v1.2

Date: 2025-09-27

Author: Spencer

Implementer: Codex

Scope: Single contract (ProposalHatter.sol). No proxy/upgradability assumed unless noted.

---

## 0) Purpose & Summary

We want decider trust zones to approve exactly-specified Hats changes and bounded funding, without giving the decider custody of funds or access controls. Proposals hash‑commit the precise Hats multicall bytes and the funding allowance for a Recipient Hat. After an optional timelock, anyone (or an address wearing an Executor Hat, if set) can execute the proposal. Funding is pull‑based: a Recipient Hat wearer calls Proposal Hatter, which (a) verifies entitlement and internal allowance, then (b) instructs the Safe AllowanceModule to transfer ETH/ERC‑20 from the DAO’s vault to the recipient.

---

## 1) External Dependencies & Ownership Model

- Vault = Safe. The DAO is the Safe owner(s) and can execute arbitrary transactions via normal Safe flows (multisig or delegate to governance).
- AllowanceModule (Safe “Spending Limits”) is enabled for that Safe. It lets Safe owners assign spending limits (one‑time or periodic) per token/ETH to a delegate/beneficiary—here, ProposalHatter.sol is configured to be able to execute transfers within owner‑set limits.
- Hats Protocol (`HATS_PROTOCOL_ADDRESS`), used for `isWearerOfHat` and to run the exact multicall payload.

Operational note: The DAO must configure Proposal Hatter with adequate per‑asset limits in the Safe’s AllowanceModule, at least as large as the expected aggregate withdrawals between top‑ups. Limits can be periodic or one‑time; owners can adjust them as needed via the Safe UI/API.

ETH sentinel: `address(0)` denotes native ETH in all references below.

---

## 2) Roles (Hat IDs, checked at call time)

- Owner Hat — DAO/top‑hat. May set role hats and Safe/Module parameters stored in Proposal Hatter; may pause/unpause; may adjust allowances in Proposal Hatter’s ledger.
- Proposer Hat — required to propose.
- Approver Hat — required to approveAndQueue and approveAndExecute.
- Executor Hat (optional) — if unset (`0`), any address may execute after the proposal's ETA; if set, caller must wear this hat.
- Escalator Hat — may escalate (pre‑execution veto to full DAO path).

Additionally, each proposal has a Recipient Hat, which is the hat authorized to withdraw funds from the vault.

All role checks use `Hats.isWearerOfHat(msg.sender, roleHatId)` at call time.

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
- `salt`: `bytes32` (optional; differentiate repeated proposals with identical parameters)

Deterministic IDs (global de‑duplication):

```
proposalId = keccak256(
  abi.encode(
    block.chainid,
    address(this),
    HATS_PROTOCOL_ADDRESS,
    hatsMulticall,
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
- Helper: `computeProposalId(...)` (see Interface) mirrors this hashing logic on-chain for UI/explorer consumption.

### 3.2 Storage

```
enum ProposalState { None, Active, Succeeded, Escalated, Canceled, Defeated, Executed }
// Mirrors OpenZeppelin Governor states where applicable; Escalated is Proposal Hatter-specific.

struct ProposalData {
  address submitter;
  uint64  eta;            // queue time (now + timelockSec)
  uint64  timelockSec;    // per-proposal delay; 0 = none
  ProposalState state;
  bytes   hatsMulticall;  // full encoded payload for Hats Protocol execution & UI surfaces
  uint256 recipientHatId;
  address fundingToken;
  uint256 fundingAmount;
}

mapping(bytes32 => ProposalData) public proposals;

// Internal, canonical allowance ledger (Owner-adjustable; monotonic via execute(+), withdraw(-), and admin adjustments).
mapping(uint256 /*hatId*/ => mapping(address /*token*/ => uint256)) public allowanceRemaining;

// External integration addresses / roles:
address public immutable HATS_PROTOCOL_ADDRESS;   // fixed at deploy
address public safe;                          // DAO’s Safe address
address public allowanceModule;               // Safe AllowanceModule (Spending Limits)

uint256 public ownerHatId;
uint256 public proposerHatId;
uint256 public approverHatId;
uint256 public executorHatId; // 0 => public execution
uint256 public escalatorHatId;

// Pauses
bool public pausedExecute;   // if true, execute() is paused
bool public pausedWithdraw;  // if true, withdraw() is paused
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
  uint256 fundingAmount,
  uint64  timelockSec,   // 0 = no timelock
  bytes32 salt           // optional salt for replaying identical payloads
) external returns (bytes32 proposalId);  // Proposer Hat

function approveAndQueue(bytes32 proposalId) external;   // Approver Hat

function execute(bytes32 proposalId) external;
// Public; if executorHatId != 0, caller must wear Executor Hat

function approveAndExecute(
  bytes   calldata hatsMulticall,
  uint256 recipientHatId,
  address fundingToken,
  uint256 fundingAmount
) external returns (bytes32 proposalId);  // Proposer + Approver hats

function escalate(bytes32 proposalId) external;          // Escalator Hat (pre-execution)
function reject(bytes32 proposalId) external;            // Approver Hat (rejection)
function cancel(bytes32 proposalId) external;            // submitter OR Owner Hat (pre-execution)

// ---- Funding pull (via Safe AllowanceModule) ----
function withdraw(
  uint256 recipientHatId,
  address token,
  uint256 amount,
  address to
) external;  // caller must wear recipientHatId

function allowanceOf(uint256 hatId, address token) external view returns (uint256);
function computeProposalId(
  bytes calldata hatsMulticall,
  uint256 recipientHatId,
  address fundingToken,
  uint256 fundingAmount,
  uint64 timelockSec,
  bytes32 salt
) external view returns (bytes32);

// ---- Admin (Owner Hat) ----
function setSafeAndModule(address safe_, address allowanceModule_) external;
function setRoleHats(uint256 owner, uint256 proposer, uint256 approver, uint256 executor, uint256 escalator) external;
function setPauses(bool executePaused, bool withdrawPaused) external;
function decreaseAllowance(uint256 hatId, address token, uint256 amount) external;
function setAllowance(uint256 hatId, address token, uint256 newAmount) external;
```

---

## 5) Semantics

### 5.1 propose(...) — Proposer Hat

- Requires `isWearerOfHat(msg.sender, proposerHatId)`.
- Requires `hatsMulticall.length > 0`.
- Computes `proposalId` (per-salt de‑dup) and requires it is unused.
- Stores `ProposalData{ submitter=msg.sender, eta=0, timelockSec, state=ProposalState.Active, hatsMulticall, recipientHatId, fundingToken, fundingAmount }`.
- Event (indexed): `Proposed(proposalId, submitter, recipientHatId, fundingToken, fundingAmount, timelockSec, salt)`.
- Note: UIs may invoke `computeProposalId` pre-call to verify or display the ID that will be emitted.

### 5.2 approveAndQueue(proposalId) — Approver Hat

- Requires current `state == ProposalState.Active`.
- Sets `eta = now + timelockSec`; sets `state = ProposalState.Succeeded` (proposal succeeded and awaits ETA).
- Event: `Succeeded(proposalId, msg.sender, eta)`.

### 5.3 execute(proposalId) — Public / Executor Hat optional

- Requires `!pausedExecute`.
- Requires `state == ProposalState.Succeeded` and `now >= eta`.
- Requires not previously `Escalated`, `Canceled`, or `Defeated` (state-machine: only `ProposalState.Succeeded` may proceed).
- If `executorHatId != 0`, caller must wear Executor Hat.
- Requires `p.hatsMulticall.length > 0` (covers calldata clearing).
- Performs atomic low‑level call to `HATS_PROTOCOL_ADDRESS` with the stored `p.hatsMulticall` bytes (revert on failure).
- On success:
  - Increase Proposal Hatter’s internal ledger: `allowanceRemaining[recipientHatId][fundingToken] += fundingAmount`.
  - Set state `ProposalState.Executed`.
  - Events: `Executed(proposalId, recipientHatId, fundingToken, fundingAmount, allowanceRemaining[recipientHatId][fundingToken])` and `FundingApproved(recipientHatId, fundingToken, fundingAmount, allowanceRemaining[recipientHatId][fundingToken])`.
- nonReentrant: reentrancy guard prevents reentry across the external call.

### 5.4 approveAndExecute(...) — Proposer + Approver Hats

- Convenience path for zero‑delay proposals:
  - Internally `propose(..., timelockSec=0, salt=<as passed>)` → `proposalId`.
  - Mark `Succeeded` (`eta=now`) and run `execute(proposalId)`.
- Caller must wear both Proposer and Approver Hats.
- Emits `Proposed`, `Succeeded`, `Executed`, `FundingApproved`.

### 5.5 escalate(proposalId) — Escalator Hat

- Allowed when state ∈ {`ProposalState.Active`, `ProposalState.Succeeded`} and before execution.
- Sets state `ProposalState.Escalated`.
- Event: `Escalated(proposalId, msg.sender)`.
- Effect: An `Escalated` proposal cannot be executed by Proposal Hatter; the DAO may proceed via its own governance paths outside Proposal Hatter if desired.

### 5.6 cancel(proposalId) — submitter or Owner Hat

- Allowed when state ∈ {`ProposalState.Active`, `ProposalState.Succeeded`} anytime pre‑execution (no pre‑ETA restriction).
- Sets state `ProposalState.Canceled`.
- Event: `Canceled(proposalId, by)`.

### 5.7 reject(proposalId) — Approver Hat (committee rejection)

- Allowed when state == `ProposalState.Active`.
- Sets state `ProposalState.Defeated`.
- Event: `Defeated(proposalId, by)`.
- Rationale: models a committee rejection akin to Governor’s `Defeated` outcome.

### 5.8 withdraw(recipientHatId, token, amount, to) — Recipient Hat wearer

- Requires `!pausedWithdraw`.
- Requires caller wears `recipientHatId`.
- Requires `allowanceRemaining[recipientHatId][token] >= amount`.
- Effects: decrement internal allowance; then instruct the Safe AllowanceModule to transfer funds from the Safe to `to`:
  - ETH: `token == address(0)`.
  - ERC‑20: `token` is the token address.
- Revert on any module error; if revert, restore the internal allowance to its previous value.
- Event: `AllowanceConsumed(recipientHatId, token, amount, remaining, to, msg.sender)`.
- Emits both the payout destination and caller for downstream auditing.
- nonReentrant: reentrancy guard prevents reentry via token hooks or module callbacks.

Module call note: The canonical method in the Safe modules repo is `AllowanceModule.executeAllowanceTransfer(...)`. Exact parameters and ETH sentinel conventions vary by version; follow the module in use. If using `executeAllowanceTransfer`, ETH is typically represented with `address(0)` and a payment of `0`.

---

## 6) Events (all indexed)

```
event Proposed(bytes32 indexed proposalId, address indexed submitter,
               uint256 indexed recipientHatId, address fundingToken,
               uint256 fundingAmount, uint64 timelockSec, bytes32 salt);

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

event FundingApproved(
  uint256 indexed recipientHatId,
  address indexed fundingToken,
  uint256 amount,
  uint256 allowanceRemaining
);
event AllowanceConsumed(
  uint256 indexed recipientHatId,
  address indexed token,
  uint256 amount,
  uint256 remaining,
  address indexed to,
  address by
);

event SafeAndModuleUpdated(address indexed safe, address indexed allowanceModule);
event RoleHatsUpdated(uint256 indexed ownerHatId, uint256 indexed proposerHatId,
                      uint256 indexed approverHatId, uint256 executorHatId, uint256 escalatorHatId);

event Paused(bool executePaused, bool withdrawPaused);
event AllowanceAdjusted(uint256 indexed recipientHatId, address indexed token, uint256 oldAmount, uint256 newAmount);
```

---

## 7) Invariants

- Exact‑bytes execution: only the stored `hatsMulticall` bytes can be executed; `hatsMulticall.length > 0`.
- Atomicity: if the Hats call fails, nothing changes (no funding approval).
- Spend monotonicity and authority:
  - `allowanceRemaining` increases only via successful `execute` or via Owner admin `setAllowance`/`decreaseAllowance`.
  - `allowanceRemaining` decreases only via `withdraw` or Owner admin `decreaseAllowance`/`setAllowance`.
- Treasury custody: committee has no access; Proposal Hatter is the only actor orchestrating transfers via the Safe’s AllowanceModule within owner‑set module limits.
- Replay safety: `proposalId` binds chain, this contract, Hats core target, payload bytes, recipient hat, token, amount, timelock, and salt. Identical inputs with the same salt are deduped; choosing a new salt permits a fresh proposal for the same payload.
- State machine: No execution if state ∈ {`ProposalState.Escalated`, `ProposalState.Canceled`, `ProposalState.Defeated`, `ProposalState.Executed`}.

---

## 8) Errors (custom errors recommended)

- `error NotHatWearer(uint256 requiredHatId);`
- `error InvalidState(ProposalState current);`
- `error TooEarly(uint64 eta, uint64 nowTs);`
- `error AllowanceExceeded(uint256 remaining, uint256 requested);`
- `error ModuleCallFailed();`
- `error AlreadyUsed(bytes32 proposalId);`
- `error NotSubmitterOrOwner();`
- `error ExecutionPaused();`
- `error WithdrawPaused();`
- `error ZeroAddress();`

---

## 9) Safe + AllowanceModule Wiring (runbook)

One‑time setup (DAO owners on the Safe):

1) Enable the AllowanceModule on the Safe (UI or programmatically).
2) Add spending limits for Proposal Hatter:
   - For each asset (ETH and specific ERC‑20s), set a limit (one‑time or periodic) large enough for near‑term operations.
   - Automate top‑ups as part of DAO ops cadence if desired.
3) (Optional) Attach Zodiac Roles Modifier to the Safe to further constrain which modules/selectors are callable.

During operation:

- Executing a proposal in Proposal Hatter increments internal allowances; it does not auto‑change Safe module limits.
- Withdrawals call the AllowanceModule to move funds from the Safe. If a Safe module limit is lower than Proposal Hatter’s internal ledger for that token, the module will block before Proposal Hatter’s ledger is exhausted—ops should raise the module limit as needed.

Audits / Lindy:

- Safe core and the AllowanceModule have public audits and ongoing bug bounties.

---

## 10) Security Considerations

- Two layers of limit: Proposal Hatter’s governance‑canonical ledger + Safe’s module limit. Either can stop a withdrawal; both must allow it.
- Compromise model: If Proposal Hatter is compromised, module limits cap outflows; keep them “as low as practical” and top‑up operationally.
- Reentrancy: Guard `execute` and `withdraw` (`nonReentrant`, CEI).
- External calls: Only two: (a) Hats Core in `execute`, (b) AllowanceModule in `withdraw`. Revert on failure.
- Revocation halts system: DAO can revoke Proposer/Approver/Executor Hats in Hats Core, pause Proposal Hatter (`setPauses`), or reduce/disable the Safe’s module limits to freeze payouts immediately.

---

## 11) Test Plan (acceptance)

Lifecycle

- Propose → Succeed → Execute happy path (with/without timelock).
- Public execution when `executorHatId == 0`; restricted when set.
- Duplicates: proposing identical inputs with the same salt rejects with `AlreadyUsed`; changing the salt permits a new proposal.

Calldata integrity

- Zero‐length `hatsMulticall` at `propose` → revert.
- Stored `hatsMulticall` cleared/missing before `execute` → revert.
- Reading proposal data returns the exact stored `hatsMulticall` bytes.

Escalation / Cancel / Defeat

- `escalate` (Escalator Hat) blocks execution.
- `cancel` by submitter and by Owner Hat at any time pre‑execution.
- `reject` by Approver Hat sets proposal to `Defeated` and blocks execution.

Withdrawals

- Non‑wearer cannot withdraw.
- Wearer withdraw ≤ remaining → Proposal Hatter decrements and module transfer succeeds (mock module returns success).
- Wearer withdraw > remaining → `AllowanceExceeded`.
- Module failure (e.g., mocked revert) → `ModuleCallFailed` and ledger restored.

Module limit interaction

- Simulate module cap lower than Proposal Hatter’s ledger → transfer hits module cap and fails; further transfers must wait for ops to increase module limit.

Reentrancy & Pauses

- Malicious token hook tries to reenter `withdraw` → blocked by `nonReentrant`.
- External reentry attempt into `execute` during Hats call → blocked by `nonReentrant`.
- `setPauses(true, false)` blocks `execute` only; `setPauses(false, true)` blocks `withdraw` only.

Admin adjustments

- `decreaseAllowance` reduces allowance and emits `AllowanceAdjusted`.
- `setAllowance` sets to exact new value and emits `AllowanceAdjusted`.

---

## 12) Reference pseudocode (selected)

```
function propose(...) external returns (bytes32 id) {
  if (!Hats.isWearerOfHat(msg.sender, proposerHatId)) revert NotHatWearer(proposerHatId);
  if (hatsMulticall.length == 0) revert();
  id = keccak256(abi.encode(block.chainid, address(this), HATS_PROTOCOL_ADDRESS,
                            hatsMulticall, recipientHatId, fundingToken, fundingAmount, timelockSec, salt));
  if (proposals[id].state != ProposalState.None) revert AlreadyUsed(id);
  proposals[id] = ProposalData({
    submitter: msg.sender,
    eta: 0,
    timelockSec: timelockSec,
    state: ProposalState.Active,
    hatsMulticall: hatsMulticall,
    recipientHatId: recipientHatId,
    fundingToken: fundingToken,
    fundingAmount: fundingAmount
  });
  emit Proposed(id, msg.sender, recipientHatId, fundingToken, fundingAmount, timelockSec, salt);
}

function execute(bytes32 id) external nonReentrant {
  if (pausedExecute) revert ExecutionPaused();
  ProposalData storage p = proposals[id];
  if (p.state != ProposalState.Succeeded) revert InvalidState(p.state);
  if (block.timestamp < p.eta) revert TooEarly(uint64(p.eta), uint64(block.timestamp));
  if (executorHatId != 0 && !Hats.isWearerOfHat(msg.sender, executorHatId)) revert NotHatWearer(executorHatId);
  if (p.hatsMulticall.length == 0) revert();

  // interactions
  (bool ok, ) = HATS_PROTOCOL_ADDRESS.call(p.hatsMulticall);
  if (!ok) revert();

  // effects
  allowanceRemaining[p.recipientHatId][p.fundingToken] += p.fundingAmount;
  p.state = ProposalState.Executed;

  emit Executed(id);
  emit FundingApproved(p.recipientHatId, p.fundingToken, p.fundingAmount);
}

function withdraw(uint256 recipientHatId, address token, uint256 amount, address to)
  external nonReentrant
{
  if (pausedWithdraw) revert WithdrawPaused();
  if (!Hats.isWearerOfHat(msg.sender, recipientHatId)) revert NotHatWearer(recipientHatId);

  uint256 rem = allowanceRemaining[recipientHatId][token];
  if (rem < amount) revert AllowanceExceeded(rem, amount);

  // effects
  allowanceRemaining[recipientHatId][token] = rem - amount;

  // interactions: call AllowanceModule to move funds from Safe to `to`
  // Canonical method name in Safe modules: AllowanceModule.executeAllowanceTransfer(...)
  (bool ok, ) = allowanceModule.call(
    abi.encodeWithSignature(
      "executeAllowanceTransfer(address,address,address,uint96,address,uint96,address,bytes)",
      safe,
      token,         // use address(0) for ETH per module
      to,
      uint96(amount),
      address(0),    // paymentToken (none)
      uint96(0),     // payment (0)
      address(this), // delegate/beneficiary, depending on module config
      bytes("")      // signature if required by the module version (may be empty if not required)
    )
  );
  if (!ok) {
    allowanceRemaining[recipientHatId][token] = rem;
    revert ModuleCallFailed();
  }

  emit AllowanceConsumed(recipientHatId, token, amount, rem - amount);
}

// Admin adjustments (Owner Hat)
function setPauses(bool execP, bool wdrP) external {
  if (!Hats.isWearerOfHat(msg.sender, ownerHatId)) revert NotHatWearer(ownerHatId);
  pausedExecute = execP; pausedWithdraw = wdrP;
  emit Paused(execP, wdrP);
}

function decreaseAllowance(uint256 hatId, address token, uint256 amount) external {
  if (!Hats.isWearerOfHat(msg.sender, ownerHatId)) revert NotHatWearer(ownerHatId);
  uint256 oldAmt = allowanceRemaining[hatId][token];
  uint256 newAmt = (amount >= oldAmt) ? 0 : (oldAmt - amount);
  allowanceRemaining[hatId][token] = newAmt;
  emit AllowanceAdjusted(hatId, token, oldAmt, newAmt);
}

function setAllowance(uint256 hatId, address token, uint256 newAmount) external {
  if (!Hats.isWearerOfHat(msg.sender, ownerHatId)) revert NotHatWearer(ownerHatId);
  uint256 oldAmt = allowanceRemaining[hatId][token];
  allowanceRemaining[hatId][token] = newAmount;
  emit AllowanceAdjusted(hatId, token, oldAmt, newAmount);
}
```

> Exact module parameters/signature may differ by deployment. Use the version deployed with your Safe; the canonical contract name in the Safe modules repository is `AllowanceModule`.

---

## 13) Non‑goals (v1)

- Policy tiers, Reality‑based challenges, per‑epoch program budgets, stream/drip schedules (can be layered later without changing the Safe wiring).
- Auto‑provisioning Safe module limits from Proposal Hatter (module limits are owner‑set per Safe UX/API).
- Interface abstraction/adapters for multiple module versions; upgrades will be handled by revoking Proposal Hatter’s hat and minting it to a new contract version, with any allowance data migration handled in that process.

---

End of spec.
