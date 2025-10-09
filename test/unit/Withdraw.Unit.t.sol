// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import {
  IProposalHatterEvents, IProposalHatterErrors, IProposalHatterTypes
} from "../../src/interfaces/IProposalHatter.sol";
import { NoReturnToken, FalseReturningToken, MalformedReturnToken } from "../helpers/MaliciousTokens.sol";

/// @title Withdraw Tests for ProposalHatter
/// @notice Tests for withdrawal functionality
contract Withdraw_Tests is ForkTestBase {
  // --------------------
  // Withdraw Tests
  // --------------------

  function test_WithdrawValid() public {
    // Execute a full proposal lifecycle to create an allowance for the recipient
    (, IProposalHatterTypes.ProposalData memory expectedProposal) = _executeFullProposalLifecycle();

    // Get the safe address and verify initial allowance
    address safe_ = expectedProposal.safe;
    uint88 initialAllowance = proposalHatter.allowanceOf(safe_, recipientHat, expectedProposal.fundingToken);
    assertEq(
      uint256(initialAllowance),
      uint256(expectedProposal.fundingAmount),
      "initial allowance should match funding amount"
    );

    // Get recipient's initial balance
    uint256 recipientInitialBalance = _getBalance(expectedProposal.fundingToken, recipient);

    // Calculate expected values after withdrawal
    uint88 withdrawAmount = expectedProposal.fundingAmount / 2; // withdraw half
    uint88 expectedRemainingAllowance = initialAllowance - withdrawAmount;

    // Expect the AllowanceConsumed event
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(
      recipientHat, safe_, expectedProposal.fundingToken, withdrawAmount, expectedRemainingAllowance, recipient
    );

    // Execute withdrawal as recipient
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, safe_, expectedProposal.fundingToken, withdrawAmount);

    // Verify allowance was decremented correctly
    uint88 finalAllowance = proposalHatter.allowanceOf(safe_, recipientHat, expectedProposal.fundingToken);
    assertEq(
      uint256(finalAllowance), uint256(expectedRemainingAllowance), "allowance should be decremented by withdraw amount"
    );

    // Verify recipient received the funds
    uint256 recipientFinalBalance = _getBalance(expectedProposal.fundingToken, recipient);
    assertEq(
      recipientFinalBalance - recipientInitialBalance,
      uint256(withdrawAmount),
      "recipient should receive withdrawn amount"
    );
  }

  function test_RevertIf_NotRecipient() public {
    // Execute a full proposal lifecycle to create an allowance
    (, IProposalHatterTypes.ProposalData memory expectedProposal) = _executeFullProposalLifecycle();

    // Attempt to withdraw as non-recipient (malicious actor doesn't wear the recipient hat)
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, expectedProposal.fundingToken, 1 ether);
  }

  function test_RevertIf_InsufficientAllowance() public {
    // Execute a full proposal lifecycle to create an allowance
    (, IProposalHatterTypes.ProposalData memory expectedProposal) = _executeFullProposalLifecycle();

    // Get the current allowance
    uint88 allowance = proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, expectedProposal.fundingToken);

    // Attempt to withdraw more than the allowance
    uint88 excessiveAmount = allowance + 1 ether;

    // Expect AllowanceExceeded error with remaining and requested amounts
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.AllowanceExceeded.selector, allowance, excessiveAmount)
    );
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, expectedProposal.fundingToken, excessiveAmount);
  }

  function test_RevertIf_Paused() public {
    // Execute a full proposal lifecycle to create an allowance
    (, IProposalHatterTypes.ProposalData memory expectedProposal) = _executeFullProposalLifecycle();

    // Pause withdrawals as owner
    vm.prank(org);
    proposalHatter.pauseWithdrawals(true);

    // Attempt to withdraw while paused
    vm.expectRevert(IProposalHatterErrors.WithdrawalsArePaused.selector);
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, expectedProposal.fundingToken, 1 ether);
  }

  function test_RevertIf_SafeModuleNotEnabled() public {
    // Create a proposal with the disabled Safe (module not enabled)
    vm.prank(org);
    proposalHatter.setSafe(disabledSafe);

    // Execute a full proposal lifecycle to create an allowance for disabledSafe
    (, IProposalHatterTypes.ProposalData memory expectedProposal) = _executeFullProposalLifecycle();

    // Attempt to withdraw from disabled Safe (module not enabled on disabledSafe)
    // Safe reverts with custom error GS104 (not a string Error)
    vm.expectRevert("GS104");
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, expectedProposal.fundingToken, 1 ether);
  }

  function test_RevertIf_InsufficientSafeBalance_ETH() public {
    // Point ProposalHatter at the underfunded Safe and execute a proposal lifecycle for it
    vm.prank(org);
    proposalHatter.setSafe(underfundedSafe);

    (, IProposalHatterTypes.ProposalData memory expectedProposal) = _executeFullProposalLifecycle();

    // Sanity: ensure the allowance exceeds the Safe balance so the Safe call will fail
    uint256 safeBalance = _getBalance(expectedProposal.fundingToken, expectedProposal.safe);
    assertLt(
      safeBalance, uint256(expectedProposal.fundingAmount), "underfundedSafe unexpectedly has sufficient balance"
    );

    // The Safe module call should return (false, returnData) and trigger SafeExecutionFailed with empty return data
    vm.expectRevert(abi.encodeWithSelector(IProposalHatterErrors.SafeExecutionFailed.selector, bytes("")));

    vm.prank(recipient);
    proposalHatter.withdraw(
      recipientHat, expectedProposal.safe, expectedProposal.fundingToken, expectedProposal.fundingAmount
    );
  }

  function test_RevertIf_InsufficientSafeBalance_ERC20() public {
    vm.prank(org);
    proposalHatter.setSafe(underfundedSafe);

    uint88 fundingAmount = 1000 ether;
    (, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _executeFullProposalLifecycle(DAI, fundingAmount, recipientHat);

    // Ensure the Safe balance is lower than the amount that will be withdrawn
    uint256 safeBalance = _getBalance(DAI, expectedProposal.safe);
    assertLt(safeBalance, uint256(expectedProposal.fundingAmount), "token balance unexpectedly sufficient");

    // When the Safe forwards the transfer call, DAI reverts with the standard MakerDAO message
    bytes memory expectedReturnData = abi.encodeWithSignature("Error(string)", "Dai/insufficient-balance");
    vm.expectRevert(abi.encodeWithSelector(IProposalHatterErrors.SafeExecutionFailed.selector, expectedReturnData));

    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, DAI, expectedProposal.fundingAmount);
  }

  function testFuzz_WithdrawAmount(uint88 amount) public {
    // Execute a full proposal lifecycle to create an allowance
    (, IProposalHatterTypes.ProposalData memory expectedProposal) = _executeFullProposalLifecycle();

    // Get the initial allowance
    uint88 allowance = proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, expectedProposal.fundingToken);

    // Bound the fuzzed amount to be within the allowance
    amount = uint88(bound(uint256(amount), 1, uint256(allowance)));

    // Get recipient's initial balance
    uint256 recipientInitialBalance = _getBalance(expectedProposal.fundingToken, recipient);

    // Calculate expected remaining allowance
    uint88 expectedRemainingAllowance = allowance - amount;

    // Expect the AllowanceConsumed event
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(
      recipientHat, expectedProposal.safe, expectedProposal.fundingToken, amount, expectedRemainingAllowance, recipient
    );

    // Execute withdrawal as recipient
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, expectedProposal.fundingToken, amount);

    // Verify allowance was decremented correctly
    uint88 finalAllowance =
      proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, expectedProposal.fundingToken);
    assertEq(
      uint256(finalAllowance), uint256(expectedRemainingAllowance), "allowance should be decremented by withdraw amount"
    );

    // Verify recipient received the funds
    uint256 recipientFinalBalance = _getBalance(expectedProposal.fundingToken, recipient);
    assertEq(
      recipientFinalBalance - recipientInitialBalance, uint256(amount), "recipient should receive withdrawn amount"
    );
  }

  function test_WithdrawUsesParameterSafe() public {
    // Create an allowance for the recipient hat on the secondary Safe
    vm.prank(org);
    proposalHatter.setSafe(secondarySafe);

    // Execute a full proposal lifecycle for secondarySafe
    (, IProposalHatterTypes.ProposalData memory expectedProposal) = _executeFullProposalLifecycle();

    // Verify the proposal is for secondarySafe
    assertEq(expectedProposal.safe, secondarySafe, "proposal should be for secondarySafe");

    // Get initial balances
    uint256 recipientInitialBalance = _getBalance(expectedProposal.fundingToken, recipient);
    uint256 secondarySafeInitialBalance = _getBalance(expectedProposal.fundingToken, secondarySafe);

    // expect the AllowanceConsumed event
    uint88 withdrawAmount = 1 ether;
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(
      recipientHat,
      secondarySafe,
      expectedProposal.fundingToken,
      withdrawAmount,
      expectedProposal.fundingAmount - withdrawAmount,
      recipient
    );

    // Withdraw from secondarySafe
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, secondarySafe, expectedProposal.fundingToken, withdrawAmount);

    // Verify funds came from secondarySafe (not primarySafe)
    uint256 recipientFinalBalance = _getBalance(expectedProposal.fundingToken, recipient);
    uint256 secondarySafeFinalBalance = _getBalance(expectedProposal.fundingToken, secondarySafe);

    assertEq(recipientFinalBalance - recipientInitialBalance, uint256(withdrawAmount), "recipient should receive funds");
    assertEq(
      secondarySafeInitialBalance - secondarySafeFinalBalance,
      uint256(withdrawAmount),
      "funds should be withdrawn from secondarySafe"
    );
  }

  function test_ERC20_NoReturn() public {
    // Deploy a USDT-style token (returns no data)
    NoReturnToken noReturnToken = new NoReturnToken();

    // Fund the primary Safe with this token
    _dealTokens(address(noReturnToken), primarySafe, 1000 ether);

    // Execute a proposal lifecycle with the no-return token
    (, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _executeFullProposalLifecycle(address(noReturnToken), 100 ether, recipientHat);

    // Get recipient's initial balance
    uint256 recipientInitialBalance = _getBalance(address(noReturnToken), recipient);

    // expect the AllowanceConsumed event
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(
      recipientHat, expectedProposal.safe, address(noReturnToken), 50 ether, 50 ether, recipient
    );

    // Withdraw should succeed even though the token returns no data
    uint88 withdrawAmount = 50 ether;
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, address(noReturnToken), withdrawAmount);

    // Verify recipient received the funds
    uint256 recipientFinalBalance = _getBalance(address(noReturnToken), recipient);
    assertEq(
      recipientFinalBalance - recipientInitialBalance,
      uint256(withdrawAmount),
      "recipient should receive withdrawn amount"
    );
  }

  function test_RevertIf_ERC20_ReturnsFalse() public {
    // Deploy a token that returns false on transfer
    FalseReturningToken falseToken = new FalseReturningToken();

    // Fund the primary Safe with this token
    _dealTokens(address(falseToken), primarySafe, 1000 ether);

    // Execute a proposal lifecycle with the false-returning token
    (, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _executeFullProposalLifecycle(address(falseToken), 100 ether, recipientHat);

    // Attempt to withdraw - should revert with ERC20TransferReturnedFalse
    uint88 withdrawAmount = 50 ether;
    bytes memory expectedReturnData = abi.encode(false);

    vm.expectRevert(
      abi.encodeWithSelector(
        IProposalHatterErrors.ERC20TransferReturnedFalse.selector, address(falseToken), expectedReturnData
      )
    );
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, address(falseToken), withdrawAmount);
  }

  function test_RevertIf_ERC20_MalformedReturn() public {
    // Deploy a token that returns malformed data (not 32 bytes)
    MalformedReturnToken malformedToken = new MalformedReturnToken();

    // Fund the primary Safe with this token
    _dealTokens(address(malformedToken), primarySafe, 1000 ether);

    // Execute a proposal lifecycle with the malformed-return token
    (, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _executeFullProposalLifecycle(address(malformedToken), 100 ether, recipientHat);

    // Attempt to withdraw - should revert with ERC20TransferMalformedReturn
    uint88 withdrawAmount = 50 ether;

    // The malformed token returns 16 bytes (only the first 16 bytes have data, rest are zero-padded)
    vm.expectRevert(
      abi.encodeWithSelector(
        IProposalHatterErrors.ERC20TransferMalformedReturn.selector,
        address(malformedToken),
        hex"00000000000000000000000000000000"
      )
    );
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, address(malformedToken), withdrawAmount);
  }

  function test_ERC20_ExactlyTrue() public {
    // Use USDC which returns exactly true (standard ERC20)
    address token = USDC;

    // Execute a proposal lifecycle with USDC
    (, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _executeFullProposalLifecycle(token, 10_000 * 1e6, recipientHat);

    // Get recipient's initial balance
    uint256 recipientInitialBalance = _getBalance(token, recipient);

    // expect the AllowanceConsumed event
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(
      recipientHat, expectedProposal.safe, token, 5000 * 1e6, 5000 * 1e6, recipient
    );

    // Withdraw should succeed with standard ERC20 token
    uint88 withdrawAmount = 5000 * 1e6;
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, token, withdrawAmount);

    // Verify recipient received the funds
    uint256 recipientFinalBalance = _getBalance(token, recipient);
    assertEq(
      recipientFinalBalance - recipientInitialBalance,
      uint256(withdrawAmount),
      "recipient should receive withdrawn amount"
    );
  }

  function test_WithdrawETH() public {
    // Execute a proposal lifecycle with ETH
    (, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _executeFullProposalLifecycle(ETH, 10 ether, recipientHat);

    // Verify the proposal uses ETH
    assertEq(expectedProposal.fundingToken, ETH, "funding token should be ETH");

    // Get recipient's initial balance
    uint256 recipientInitialBalance = recipient.balance;

    // expect the AllowanceConsumed event
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(recipientHat, expectedProposal.safe, ETH, 5 ether, 5 ether, recipient);

    // Withdraw ETH
    uint88 withdrawAmount = 5 ether;
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, ETH, withdrawAmount);

    // Verify recipient received the ETH
    uint256 recipientFinalBalance = recipient.balance;
    assertEq(
      recipientFinalBalance - recipientInitialBalance, uint256(withdrawAmount), "recipient should receive withdrawn ETH"
    );
  }

  function test_WithdrawERC20() public {
    // Execute a proposal lifecycle with DAI
    (, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _executeFullProposalLifecycle(DAI, 10_000 * 1e18, recipientHat);

    // Verify the proposal uses DAI
    assertEq(expectedProposal.fundingToken, DAI, "funding token should be DAI");

    // Get recipient's initial balance
    uint256 recipientInitialBalance = _getBalance(DAI, recipient);

    // expect the AllowanceConsumed event
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(
      recipientHat, expectedProposal.safe, DAI, 5000 * 1e18, 5000 * 1e18, recipient
    );

    // Withdraw DAI
    uint88 withdrawAmount = 5000 * 1e18;
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, DAI, withdrawAmount);

    // Verify recipient received the DAI
    uint256 recipientFinalBalance = _getBalance(DAI, recipient);
    assertEq(
      recipientFinalBalance - recipientInitialBalance, uint256(withdrawAmount), "recipient should receive withdrawn DAI"
    );
  }

  function test_WithdrawMultipleTimes() public {
    // Execute a proposal lifecycle to create an allowance
    (, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _executeFullProposalLifecycle(ETH, 10 ether, recipientHat);

    // Get initial allowance and balance
    uint88 initialAllowance = proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, ETH);
    uint256 recipientInitialBalance = recipient.balance;

    // Perform multiple partial withdrawals
    uint88 firstWithdrawal = 3 ether;
    uint88 secondWithdrawal = 2 ether;
    uint88 thirdWithdrawal = 5 ether;

    // First withdrawal
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(
      recipientHat, expectedProposal.safe, ETH, firstWithdrawal, initialAllowance - firstWithdrawal, recipient
    );
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, ETH, firstWithdrawal);
    assertEq(
      proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, ETH),
      initialAllowance - firstWithdrawal,
      "allowance after first withdrawal"
    );

    // Second withdrawal
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(
      recipientHat,
      expectedProposal.safe,
      ETH,
      secondWithdrawal,
      initialAllowance - firstWithdrawal - secondWithdrawal,
      recipient
    );
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, ETH, secondWithdrawal);
    assertEq(
      proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, ETH),
      initialAllowance - firstWithdrawal - secondWithdrawal,
      "allowance after second withdrawal"
    );

    // Third withdrawal (exhausts allowance)
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(
      recipientHat,
      expectedProposal.safe,
      ETH,
      thirdWithdrawal,
      initialAllowance - firstWithdrawal - secondWithdrawal - thirdWithdrawal,
      recipient
    );
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, ETH, thirdWithdrawal);
    assertEq(proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, ETH), 0, "allowance should be exhausted");

    // Verify total amount withdrawn
    uint256 recipientFinalBalance = recipient.balance;
    assertEq(
      recipientFinalBalance - recipientInitialBalance,
      uint256(firstWithdrawal + secondWithdrawal + thirdWithdrawal),
      "recipient should receive total withdrawn amount"
    );
  }

  function test_WithdrawFromSecondaryAccount() public {
    // Increase maxSupply for recipientHat to allow multiple wearers
    address secondRecipient = makeAddr("secondRecipient");
    vm.prank(org);
    hats.changeHatMaxSupply(recipientHat, 2);

    // Execute a proposal lifecycle to create an allowance
    uint88 initialAllowance = 10 ether;
    (, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _executeFullProposalLifecycle(ETH, initialAllowance, recipientHat);

    // Mint the recipient hat to a second address
    vm.prank(org);
    hats.mintHat(recipientHat, secondRecipient);

    // Verify both addresses wear the recipient hat
    assertTrue(hats.isWearerOfHat(recipient, recipientHat), "original recipient should wear hat");
    assertTrue(hats.isWearerOfHat(secondRecipient, recipientHat), "second recipient should wear hat");

    // Get initial balances
    uint256 recipientInitialBalance = recipient.balance;
    uint256 secondRecipientInitialBalance = secondRecipient.balance;

    // First recipient withdraws
    uint88 firstWithdrawal = 4 ether;
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(
      recipientHat, expectedProposal.safe, ETH, firstWithdrawal, initialAllowance - firstWithdrawal, recipient
    );
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, ETH, firstWithdrawal);

    // Second recipient withdraws from the same allowance
    uint88 secondWithdrawal = 6 ether;
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(
      recipientHat,
      expectedProposal.safe,
      ETH,
      secondWithdrawal,
      initialAllowance - firstWithdrawal - secondWithdrawal,
      secondRecipient
    );
    vm.prank(secondRecipient);
    proposalHatter.withdraw(recipientHat, expectedProposal.safe, ETH, secondWithdrawal);

    // Verify both received their respective amounts
    assertEq(
      recipient.balance - recipientInitialBalance,
      uint256(firstWithdrawal),
      "first recipient should receive withdrawn amount"
    );
    assertEq(
      secondRecipient.balance - secondRecipientInitialBalance,
      uint256(secondWithdrawal),
      "second recipient should receive withdrawn amount"
    );

    // Verify allowance is exhausted
    assertEq(proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, ETH), 0, "allowance should be exhausted");
  }
}
