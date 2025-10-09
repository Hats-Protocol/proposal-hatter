// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import {
  IProposalHatter,
  IProposalHatterEvents,
  IProposalHatterErrors,
  IProposalHatterTypes
} from "../../src/interfaces/IProposalHatter.sol";

/// @title Reject Tests for ProposalHatter
/// @notice Tests for proposal rejection functionality
contract Reject_Tests is ForkTestBase {
  // --------------------
  // Reject Tests
  // --------------------

  function test_RejectActive() public {
    // Get the next hat ID under opsBranchId for the reserved hat
    uint256 expectedReservedHatId = _getNextHatId(opsBranchId);

    // Create an active proposal with reserved hat
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(5 ether, ETH, 1 days, recipientHat, expectedReservedHatId, "", bytes32(uint256(107)));

    // Verify initial state
    _assertProposalData(_getProposalData(proposalId), expected);

    // Mint approver hat to approver
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    // Expect the Rejected event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.Rejected(proposalId, approver);

    // Reject the proposal
    vm.prank(approver);
    proposalHatter.reject(proposalId);

    // Update expected state
    expected.state = IProposalHatterTypes.ProposalState.Rejected;

    // Verify proposal data is correct after rejection
    _assertProposalData(_getProposalData(proposalId), expected);

    // Verify reserved hat was toggled off and its toggle module is ProposalHatter
    _assertHatToggle(expectedReservedHatId, address(proposalHatter), false);

    // Verify approver hat was toggled off
    _assertHatToggle(expected.approverHatId, address(proposalHatter), false);
  }

  function test_RevertIf_Reject_NotApprover() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(108)));

    // Attempt to reject as non-approver (maliciousActor doesn't wear the approver hat)
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.reject(proposalId);
  }

  function test_RevertIf_Reject_None() public {
    // Create a fake proposal ID that doesn't exist
    bytes32 nonExistentProposalId = bytes32(uint256(999_999));

    // Attempt to reject a non-existent proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.None)
    );
    vm.prank(approver);
    proposalHatter.reject(nonExistentProposalId);
  }

  function test_RevertIf_Reject_Approved() public {
    // Create and approve a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(109)));

    _approveProposal(proposalId);

    // Attempt to reject an approved proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Approved)
    );
    vm.prank(approver);
    proposalHatter.reject(proposalId);
  }

  function test_RevertIf_Reject_Escalated() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(110)));

    // Escalate the proposal (escalator hat already minted in setup)
    vm.prank(escalator);
    proposalHatter.escalate(proposalId);

    // Attempt to reject an escalated proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Escalated)
    );
    vm.prank(approver);
    proposalHatter.reject(proposalId);
  }

  function test_RevertIf_Reject_Canceled() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(111)));

    // Cancel the proposal (as the proposer who is the submitter)
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);

    // Attempt to reject a canceled proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Canceled)
    );
    vm.prank(approver);
    proposalHatter.reject(proposalId);
  }

  function test_RevertIf_Reject_Rejected() public {
    // Create a proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(112)));

    // Mint approver hat and reject the proposal
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    vm.prank(approver);
    proposalHatter.reject(proposalId);

    // Attempt to reject again
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Rejected)
    );
    vm.prank(approver);
    proposalHatter.reject(proposalId);
  }

  function test_RejectWithoutReservedHat() public {
    // Create a proposal without reserved hat (reservedHatId = 0)
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(113)));

    // Mint approver hat to approver
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    // Expect the Rejected event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.Rejected(proposalId, approver);

    // Reject the proposal
    vm.prank(approver);
    proposalHatter.reject(proposalId);

    // Update expected state
    expected.state = IProposalHatterTypes.ProposalState.Rejected;

    // Verify proposal data is correct after rejection
    IProposalHatterTypes.ProposalData memory actual = _getProposalData(proposalId);
    _assertProposalData(actual, expected);

    // No reserved hat to toggle off, so just verify state is correct
    assertEq(actual.reservedHatId, 0, "Should have no reserved hat");

    // Verify approver hat was toggled off
    _assertHatToggle(actual.approverHatId, address(proposalHatter), false);
  }

  function test_RejectDoesNotCheckPause() public {
    // Create a proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(114)));

    // Mint approver hat to approver
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    // Owner pauses proposals
    vm.prank(org);
    proposalHatter.pauseProposals(true);

    // Reject should work even when paused (by design)
    vm.prank(approver);
    proposalHatter.reject(proposalId);

    // Verify rejection succeeded
    expected.state = IProposalHatterTypes.ProposalState.Rejected;
    _assertProposalData(_getProposalData(proposalId), expected);

    // Verify approver hat was toggled off
    _assertHatToggle(expected.approverHatId, address(proposalHatter), false);
  }
}
