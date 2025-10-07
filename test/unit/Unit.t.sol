// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import { IProposalHatter } from "../../src/interfaces/IProposalHatter.sol";

/// @title Unit Tests for ProposalHatter
/// @notice Comprehensive unit tests organized by contract function

// =============================================================================
// Constructor Tests
// =============================================================================

contract Constructor_Tests is ForkTestBase {
  function test_DeployWithValidParams() public {
    // TODO: Verify immutables, events emitted
  }

  function test_RevertIf_ZeroAddress() public {
    // TODO: Test zero address inputs
  }

  function testFuzz_DeployWithRoles(uint256 proposerHatId, uint256 executorHatId) public {
    // TODO: Fuzz hat IDs, verify storage
  }
}

// =============================================================================
// Propose Tests
// =============================================================================

contract Propose_Tests is ForkTestBase {
  function test_ProposeValid() public {
    // TODO: Create proposal, verify ID determinism, approver hat creation, events
  }

  function test_RevertIf_NotProposer() public {
    // TODO: Unauthorized caller
  }

  function test_RevertIf_ProposalsPaused() public {
    // TODO: After owner pauses
  }

  function testFuzz_ProposeWithParams(uint88 fundingAmount, address fundingToken, uint32 timelockSec, bytes32 salt)
    public
  {
    // TODO: Fuzz parameters, verify ID hash
  }

  function test_ProposeFundingOnly() public {
    // TODO: Empty hatsMulticall
  }

  function test_RevertIf_DuplicateProposal() public {
    // TODO: Same inputs/salt
  }

  function test_ProposalStoresSafeAddress() public {
    // TODO: Verify p.safe captured at propose-time
  }

  function test_ProposalIdIncludesChainId() public {
    // TODO: Verify block.chainid in hash
  }

  function test_ProposalIdIncludesSafe() public {
    // TODO: Different Safes yield different IDs
  }
}

// =============================================================================
// Approve Tests
// =============================================================================

contract Approve_Tests is ForkTestBase {
  function test_ApproveActiveProposal() public {
    // TODO: Sets ETA, state to Approved, event
  }

  function test_RevertIf_NotApprover() public {
    // TODO: Non-wearer
  }

  function testFuzz_ApproveTimelock(uint32 timelockSec) public {
    // TODO: Fuzz timelockSec, verify ETA
  }
}

// =============================================================================
// ApproveAndExecute Tests
// =============================================================================

contract ApproveAndExecute_Tests is ForkTestBase {
  function test_ApproveAndExecuteZeroTimelock() public {
    // TODO: Atomic approve+execute
  }

  function test_RevertIf_NonZeroTimelock() public {
    // TODO: Should revert if timelock != 0
  }
}

// =============================================================================
// Execute Tests
// =============================================================================

contract Execute_Tests is ForkTestBase {
  function test_ExecuteApprovedAfterETA() public {
    // TODO: Increases allowance, calls multicall, state to Executed, event
  }

  function test_RevertIf_TooEarly() public {
    // TODO: Timing check
  }

  function test_RevertIf_BadState() public {
    // TODO: State check
  }

  function test_RevertIf_NotExecutor() public {
    // TODO: Auth check
  }

  function testFuzz_ExecuteAllowance(uint88 fundingAmount) public {
    // TODO: Fuzz fundingAmount near uint88.max, check overflow revert
  }

  function test_ExecuteUsesProposalSafe() public {
    // TODO: Allowance recorded for p.safe, not global safe
  }

  function test_HatsMulticallDeleted() public {
    // TODO: After execute with non-empty multicall, verify empty
  }

  function test_HatsMulticallPreservedIfEmpty() public {
    // TODO: After execute with empty multicall, verify remains empty
  }
}

// =============================================================================
// Lifecycle Tests (Escalate, Reject, Cancel)
// =============================================================================

contract Lifecycle_Tests is ForkTestBase {
  function test_EscalateActive() public {
    // TODO: Sets state, event, blocks execute
  }

  function test_EscalateApproved() public {
    // TODO: Sets state, event, blocks execute
  }

  function test_RevertIf_NotEscalator() public {
    // TODO: Auth check
  }

  function test_RevertIf_Escalate_BadState() public {
    // TODO: State check
  }

  function test_RejectActive() public {
    // TODO: Sets state, toggles reserved hat off
  }

  function test_RevertIf_Reject_BadState() public {
    // TODO: State check
  }

  function test_CancelPreExecution() public {
    // TODO: By submitter, toggles reserved hat
  }

  function test_RevertIf_Cancel_NotSubmitter() public {
    // TODO: Auth check
  }
}

// =============================================================================
// Withdraw Tests
// =============================================================================

contract Withdraw_Tests is ForkTestBase {
  function test_WithdrawValid() public {
    // TODO: Decrements allowance, executes Safe transfer, event
  }

  function test_RevertIf_NotRecipient() public {
    // TODO: Auth check
  }

  function test_RevertIf_InsufficientAllowance() public {
    // TODO: Allowance check
  }

  function test_RevertIf_Paused() public {
    // TODO: Pause check
  }

  function test_RevertIf_SafeFailure() public {
    // TODO: Safe execution failure
  }

  function testFuzz_WithdrawAmount(uint88 amount) public {
    // TODO: Fuzz amount <= allowance, verify post-balance
  }

  function test_WithdrawUsesParameterSafe() public {
    // TODO: Module call targets the safe_ parameter
  }

  function test_ERC20_NoReturn() public {
    // TODO: USDT-style token (0 bytes return) should succeed
  }

  function test_RevertIf_ERC20_ReturnsFalse() public {
    // TODO: Token returns false should revert
  }

  function test_RevertIf_ERC20_MalformedReturn() public {
    // TODO: Return data not 32 bytes should revert
  }

  function test_ERC20_ExactlyTrue() public {
    // TODO: Token returns exactly true should succeed
  }
}

// =============================================================================
// Admin Tests
// =============================================================================

contract Admin_Tests is ForkTestBase {
  function test_SetProposerHat() public {
    // TODO: Owner-only, event, storage update
  }

  function test_SetExecutorHat() public {
    // TODO: Owner-only, event, storage update
  }

  function test_SetEscalatorHat() public {
    // TODO: Owner-only, event, storage update
  }

  function test_SetSafe() public {
    // TODO: Owner-only, event, storage update
  }

  function test_PauseProposals() public {
    // TODO: Owner-only, event, storage update
  }

  function test_PauseWithdrawals() public {
    // TODO: Owner-only, event, storage update
  }

  function test_RevertIf_NotOwner() public {
    // TODO: Auth check on all admin functions
  }

  function test_RevertIf_ZeroSafe() public {
    // TODO: Validation check
  }

  function test_SafeMigrationIsolation() public {
    // TODO: Change global safe, verify existing proposals use original p.safe
  }
}

// =============================================================================
// View Tests
// =============================================================================

contract View_Tests is ForkTestBase {
  function test_AllowanceOf() public {
    // TODO: Matches internal ledger for correct (safe, hatId, token) tuple
  }

  function test_ComputeProposalId() public {
    // TODO: Matches on-chain hash, includes all expected parameters
  }

  function test_GetProposalState() public {
    // TODO: Returns correct state for various proposal IDs
  }
}
