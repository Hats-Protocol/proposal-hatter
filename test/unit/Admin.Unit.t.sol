// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import {
  IProposalHatterEvents, IProposalHatterErrors, IProposalHatterTypes
} from "../../src/interfaces/IProposalHatter.sol";

/// @title Admin Tests for ProposalHatter
/// @notice Tests for admin functions (Owner Hat only)
contract Admin_Tests is ForkTestBase {
  // --------------------
  // Admin Tests
  // --------------------

  function test_SetProposerHat() public {
    // Create a new hat to use as proposer
    vm.prank(org);
    uint256 newProposerHat = hats.createHat(topHatId, "New Proposer", 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

    // Expect the ProposerHatSet event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.ProposerHatSet(newProposerHat);

    // Set the proposer hat as owner
    vm.prank(org);
    proposalHatter.setProposerHat(newProposerHat);

    // Verify storage was updated
    assertEq(proposalHatter.proposerHat(), newProposerHat, "Proposer hat mismatch");
  }

  function test_RevertIf_SetProposerHat_NotOwner() public {
    // Attempt to set proposer hat as non-owner
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.setProposerHat(123);
  }

  function test_SetExecutorHat() public {
    // Create a new hat to use as executor
    vm.prank(org);
    uint256 newExecutorHat = hats.createHat(topHatId, "New Executor", 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

    // Expect the ExecutorHatSet event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.ExecutorHatSet(newExecutorHat);

    // Set the executor hat as owner
    vm.prank(org);
    proposalHatter.setExecutorHat(newExecutorHat);

    // Verify storage was updated
    assertEq(proposalHatter.executorHat(), newExecutorHat, "Executor hat mismatch");
  }

  function test_RevertIf_SetExecutorHat_NotOwner() public {
    // Attempt to set executor hat as non-owner
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.setExecutorHat(123);
  }

  function test_SetEscalatorHat() public {
    // Create a new hat to use as escalator
    vm.prank(org);
    uint256 newEscalatorHat = hats.createHat(topHatId, "New Escalator", 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

    // Expect the EscalatorHatSet event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.EscalatorHatSet(newEscalatorHat);

    // Set the escalator hat as owner
    vm.prank(org);
    proposalHatter.setEscalatorHat(newEscalatorHat);

    // Verify storage was updated
    assertEq(proposalHatter.escalatorHat(), newEscalatorHat, "Escalator hat mismatch");
  }

  function test_RevertIf_SetEscalatorHat_NotOwner() public {
    // Attempt to set escalator hat as non-owner
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.setEscalatorHat(123);
  }

  function test_SetSafe() public {
    // Use the secondary safe as the new safe
    address newSafe = secondarySafe;

    // Expect the SafeSet event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.SafeSet(newSafe);

    // Set the safe as owner
    vm.prank(org);
    proposalHatter.setSafe(newSafe);

    // Verify storage was updated
    assertEq(proposalHatter.safe(), newSafe, "Safe mismatch");
  }

  function test_RevertIf_SetSafe_NotOwner() public {
    // Attempt to set safe as non-owner
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.setSafe(secondarySafe);
  }

  function test_RevertIf_SetSafe_ZeroAddress() public {
    // Attempt to set safe to address(0)
    vm.expectRevert(IProposalHatterErrors.ZeroAddress.selector);
    vm.prank(org);
    proposalHatter.setSafe(address(0));
  }

  function test_PauseProposals() public {
    // Verify not paused initially
    assertFalse(proposalHatter.proposalsPaused(), "Should not be paused initially");

    // Expect the ProposalsPaused event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.ProposalsPaused(true);

    // Pause proposals as owner
    vm.prank(org);
    proposalHatter.pauseProposals(true);

    // Verify storage was updated
    assertTrue(proposalHatter.proposalsPaused(), "Should be paused");
  }

  function test_UnpauseProposals() public {
    // First pause
    vm.prank(org);
    proposalHatter.pauseProposals(true);
    assertTrue(proposalHatter.proposalsPaused(), "Should be paused");

    // Expect the ProposalsPaused event with false
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.ProposalsPaused(false);

    // Unpause proposals as owner
    vm.prank(org);
    proposalHatter.pauseProposals(false);

    // Verify storage was updated
    assertFalse(proposalHatter.proposalsPaused(), "Should be unpaused");
  }

  function test_RevertIf_PauseProposals_NotOwner() public {
    // Attempt to pause proposals as non-owner
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.pauseProposals(true);
  }

  function test_PauseWithdrawals() public {
    // Verify not paused initially
    assertFalse(proposalHatter.withdrawalsPaused(), "Should not be paused initially");

    // Expect the WithdrawalsPaused event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.WithdrawalsPaused(true);

    // Pause withdrawals as owner
    vm.prank(org);
    proposalHatter.pauseWithdrawals(true);

    // Verify storage was updated
    assertTrue(proposalHatter.withdrawalsPaused(), "Should be paused");
  }

  function test_UnpauseWithdrawals() public {
    // First pause
    vm.prank(org);
    proposalHatter.pauseWithdrawals(true);
    assertTrue(proposalHatter.withdrawalsPaused(), "Should be paused");

    // Expect the WithdrawalsPaused event with false
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.WithdrawalsPaused(false);

    // Unpause withdrawals as owner
    vm.prank(org);
    proposalHatter.pauseWithdrawals(false);

    // Verify storage was updated
    assertFalse(proposalHatter.withdrawalsPaused(), "Should be unpaused");
  }

  function test_RevertIf_PauseWithdrawals_NotOwner() public {
    // Attempt to pause withdrawals as non-owner
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.pauseWithdrawals(true);
  }

  function test_SafeMigrationIsolation() public {
    // Create a proposal using the original safe (primarySafe)
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(300)));

    // Verify the proposal uses the primary safe
    assertEq(expected.safe, primarySafe, "Proposal should use primary safe");

    // Owner changes the global safe to secondarySafe
    vm.prank(org);
    proposalHatter.setSafe(secondarySafe);

    // Verify global safe was updated
    assertEq(proposalHatter.safe(), secondarySafe, "Global safe should be updated");

    // Verify the existing proposal still uses the original safe (isolation property)
    IProposalHatterTypes.ProposalData memory actualProposal = _getProposalData(proposalId);
    assertEq(actualProposal.safe, primarySafe, "Existing proposal should still use original safe");

    // Create a new proposal after the safe change
    (bytes32 newProposalId, IProposalHatterTypes.ProposalData memory newExpected) =
      _createTestProposal(1 days, bytes32(uint256(301)));

    // Verify the new proposal uses the new safe
    assertEq(newExpected.safe, secondarySafe, "New proposal should use new safe");

    // Double-check by reading from storage
    IProposalHatterTypes.ProposalData memory actualNewProposal = _getProposalData(newProposalId);
    assertEq(actualNewProposal.safe, secondarySafe, "New proposal should use new safe (storage check)");
  }
}
