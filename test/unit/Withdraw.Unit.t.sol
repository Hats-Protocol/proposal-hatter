// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import {
  IProposalHatter,
  IProposalHatterEvents,
  IProposalHatterErrors,
  IProposalHatterTypes
} from "../../src/interfaces/IProposalHatter.sol";

/// @title Withdraw Tests for ProposalHatter
/// @notice Tests for withdrawal functionality
contract Withdraw_Tests is ForkTestBase {
  // --------------------
  // Withdraw Tests
  // --------------------

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

  function test_WithdrawETH() public {
    // TODO: Specifically test ETH withdrawal
  }

  function test_WithdrawERC20() public {
    // TODO: Specifically test ERC20 withdrawal
  }

  function test_WithdrawMultipleTimes() public {
    // TODO: Partial withdrawals until allowance exhausted
  }

  function test_WithdrawFromSecondaryAccount() public {
    // TODO: Multiple addresses wearing same hat can withdraw
  }
}
