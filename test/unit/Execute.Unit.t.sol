// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import {
  IProposalHatter,
  IProposalHatterEvents,
  IProposalHatterErrors,
  IProposalHatterTypes
} from "../../src/interfaces/IProposalHatter.sol";

/// @title ApproveAndExecute Tests for ProposalHatter
/// @notice Tests for proposal approval and execution functionality
contract ApproveAndExecute_Tests is ForkTestBase {
  // --------------------
  // ApproveAndExecute Tests
  // --------------------

  function test_ApproveAndExecuteZeroTimelock() public {
    // TODO: Atomic approve+execute
  }

  function test_RevertIf_NonZeroTimelock() public {
    // TODO: Should revert if timelock != 0
  }

  function test_RevertIf_NotApprover() public {
    // TODO: Non-approver tries approveAndExecute
  }

  function test_RevertIf_NotExecutor() public {
    // TODO: When executorHat != PUBLIC_SENTINEL, non-executor reverts
  }

  function test_RevertIf_ApproveAndExecute_None() public {
    // TODO: Try to approve and execute a proposal that doesn't exist
  }

  function test_RevertIf_ApproveAndExecute_Approved() public {
    // TODO: Try to approve and execute an approved proposal
  }

  function test_RevertIf_ApproveAndExecute_Executed() public {
    // TODO: Try to approve and execute an executed proposal
  }

  function test_RevertIf_ApproveAndExecute_Canceled() public {
    // TODO: Try to approve and execute a canceled proposal
  }

  function test_RevertIf_ApproveAndExecute_Rejected() public {
    // TODO: Try to approve and execute a rejected proposal
  }

  function test_RevertIf_ApproveAndExecute_ProposalsPaused() public {
    // TODO: Pause check
  }
}

/// @title Execute Tests for ProposalHatter
/// @notice Tests for proposal execution functionality
contract Execute_Tests is ForkTestBase {
  // --------------------
  // Execute Tests
  // --------------------

  // TODO figure out how to test hatsMulticall
  // - what edges do we need to test?
  // - can we just test with a simple hat creation? or do we need to test with a more complex set of hat creates and
  // changes?

  function test_ExecuteApprovedAfterETA() public {
    // TODO: Full execution flow, verify:
    //   - Allowance increased correctly
    //   - State changed to Executed
    //   - Executed event emitted
  }

  function test_RevertIf_TooEarly() public {
    // TODO: Timing check
  }

  function test_RevertIf_NotExecutor() public {
    // TODO: Auth check
  }

  function testFuzz_ExecuteAllowance(uint88 fundingAmount) public {
    // TODO: Fuzz fundingAmount near uint88.max, check overflow revert
  }

  function test_ExecuteUsesProposalSafe() public {
    // TODO: Allowance recorded for p.safe, not global safe (important security property)
  }

  function test_ExecuteAtExactETA() public {
    // TODO: block.timestamp == p.eta should succeed (uses >= check)
  }

  function test_ExecuteWithMulticall() public {
    // TODO: Non-empty hatsMulticall, verify:
    //   - Multicall is executed
    //   - hatsMulticall storage is deleted after execution
  }

  function test_ExecuteWithoutMulticall() public {
    // TODO: Empty hatsMulticall, verify:
    //   - No multicall executed
    //   - hatsMulticall storage remains empty
  }

  function test_RevertIf_MulticallFails() public {
    // TODO: Hats multicall reverts, entire tx should revert (atomicity)
  }

  function test_RevertIf_Execute_None() public {
    // TODO: Try to execute a proposal that doesn't exist
  }

  function test_RevertIf_Execute_Escalated() public {
    // TODO: Cannot execute escalated proposal
  }

  function test_RevertIf_Execute_Canceled() public {
    // TODO: Cannot execute canceled proposal
  }

  function test_RevertIf_Execute_Rejected() public {
    // TODO: Cannot execute rejected proposal
  }

  function test_RevertIf_Execute_AlreadyExecuted() public {
    // TODO: Cannot execute twice
  }

  // --------------------
  // Public Execution Tests
  // --------------------

  function test_ExecutePublic() public {
    // TODO: Set executorHat to PUBLIC_SENTINEL, verify anyone can execute
  }

  function test_ApproveAndExecutePublic() public {
    // TODO: Public execution for approveAndExecute
  }

  function test_RevertIf_Execute_NotPublicAndNotExecutor() public {
    // TODO: When executorHat != PUBLIC_SENTINEL, non-executor reverts
  }
}
