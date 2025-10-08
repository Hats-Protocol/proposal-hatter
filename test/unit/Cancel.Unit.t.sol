// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import {
  IProposalHatter,
  IProposalHatterEvents,
  IProposalHatterErrors,
  IProposalHatterTypes
} from "../../src/interfaces/IProposalHatter.sol";

/// @title Cancel Tests for ProposalHatter
/// @notice Tests for proposal cancellation functionality
contract Cancel_Tests is ForkTestBase {
  // --------------------
  // Cancel Tests
  // --------------------

  function test_CancelActive() public {
    // Get the next hat ID under opsBranchId for the reserved hat
    uint256 expectedReservedHatId = _getNextHatId(opsBranchId);

    // Create an active proposal with reserved hat
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(5 ether, ETH, 1 days, recipientHat, expectedReservedHatId, "", bytes32(uint256(150)));

    // Verify initial state
    _assertProposalData(_getProposalData(proposalId), expected);

    // Expect the Canceled event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.Canceled(proposalId, proposer);

    // Cancel the proposal as the submitter (proposer)
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);

    // Update expected state
    expected.state = IProposalHatterTypes.ProposalState.Canceled;

    // Verify proposal data is correct after cancellation
    _assertProposalData(_getProposalData(proposalId), expected);

    // Verify reserved hat was toggled off and its toggle module is ProposalHatter
    _assertHatToggle(expectedReservedHatId, address(proposalHatter), false);
  }

  function test_CancelApproved() public {
    // Get the next hat ID under opsBranchId for the reserved hat
    uint256 expectedReservedHatId = _getNextHatId(opsBranchId);

    // Create and approve a proposal with reserved hat
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(5 ether, ETH, 1 days, recipientHat, expectedReservedHatId, "", bytes32(uint256(151)));

    // Mint approver hat and approve
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    vm.prank(approver);
    proposalHatter.approve(proposalId);

    // Update expected for approved state
    expected.state = IProposalHatterTypes.ProposalState.Approved;
    expected.eta = uint64(block.timestamp) + expected.timelockSec;

    // Verify approved state
    _assertProposalData(_getProposalData(proposalId), expected);

    // Expect the Canceled event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.Canceled(proposalId, proposer);

    // Cancel the approved proposal as the submitter
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);

    // Update expected state to Canceled
    expected.state = IProposalHatterTypes.ProposalState.Canceled;

    // Verify proposal data is correct after cancellation
    _assertProposalData(_getProposalData(proposalId), expected);

    // Verify reserved hat was toggled off and its toggle module is ProposalHatter
    _assertHatToggle(expectedReservedHatId, address(proposalHatter), false);
  }

  function test_RevertIf_Cancel_NotSubmitter() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(152)));

    // Attempt to cancel as non-submitter
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.cancel(proposalId);
  }

  function test_CancelWithoutReservedHat() public {
    // Create a proposal without reserved hat (reservedHatId = 0)
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(153)));

    // Expect the Canceled event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.Canceled(proposalId, proposer);

    // Cancel the proposal
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);

    // Update expected state
    expected.state = IProposalHatterTypes.ProposalState.Canceled;

    // Verify proposal data is correct after cancellation
    IProposalHatterTypes.ProposalData memory actual = _getProposalData(proposalId);
    _assertProposalData(actual, expected);

    // No reserved hat to toggle off, so just verify state is correct
    assertEq(actual.reservedHatId, 0, "Should have no reserved hat");
  }

  function test_RevertIf_Cancel_None() public {
    // Create a fake proposal ID that doesn't exist
    bytes32 nonExistentProposalId = bytes32(uint256(999_999));

    // Attempt to cancel a non-existent proposal
    // Note: Will revert with NotAuthorized because submitter check happens before state check
    // and the submitter for a non-existent proposal is address(0)
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(proposer);
    proposalHatter.cancel(nonExistentProposalId);
  }

  function test_RevertIf_Cancel_Executed() public {
    // Create, approve, and execute a proposal
    (bytes32 proposalId,) = _executeFullProposalLifecycle();

    // Attempt to cancel an executed proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Executed)
    );
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);
  }

  function test_RevertIf_Cancel_Escalated() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(154)));

    // Escalate the proposal (escalator hat already minted in setup)
    vm.prank(escalator);
    proposalHatter.escalate(proposalId);

    // Attempt to cancel an escalated proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Escalated)
    );
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);
  }

  function test_RevertIf_Cancel_Rejected() public {
    // Create a proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(155)));

    // Mint approver hat and reject the proposal
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    vm.prank(approver);
    proposalHatter.reject(proposalId);

    // Attempt to cancel a rejected proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Rejected)
    );
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);
  }

  function test_RevertIf_Cancel_Canceled() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(156)));

    // Cancel the proposal
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);

    // Attempt to cancel again
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Canceled)
    );
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);
  }

  function test_CancelDoesNotCheckPause() public {
    // Create a proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(157)));

    // Owner pauses proposals
    vm.prank(org);
    proposalHatter.pauseProposals(true);

    // Cancel should work even when paused (by design)
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);

    // Verify cancellation succeeded
    expected.state = IProposalHatterTypes.ProposalState.Canceled;
    _assertProposalData(_getProposalData(proposalId), expected);
  }
}
