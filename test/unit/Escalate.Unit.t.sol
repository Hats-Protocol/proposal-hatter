// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import {
  IProposalHatterEvents, IProposalHatterErrors, IProposalHatterTypes
} from "../../src/interfaces/IProposalHatter.sol";

/// @title Escalate Tests for ProposalHatter
/// @notice Tests for proposal escalation functionality
contract Escalate_Tests is ForkTestBase {
  // --------------------
  // Escalate Tests
  // --------------------

  function test_EscalateActive() public {
    // Create an active proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(100)));

    // Verify initial state
    _assertProposalData(_getProposalData(proposalId), expected);

    // Expect the Escalated event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.Escalated(proposalId, escalator);

    // Escalate the proposal (escalator hat already minted in setup)
    vm.prank(escalator);
    proposalHatter.escalate(proposalId);

    // Update expected state
    expected.state = IProposalHatterTypes.ProposalState.Escalated;

    // Verify proposal data is correct after escalation
    _assertProposalData(_getProposalData(proposalId), expected);

    // Verify approver hat was toggled off
    _assertHatToggle(expected.approverHatId, address(proposalHatter), false);
  }

  function test_EscalateApproved() public {
    // Create and approve a proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(101)));

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

    // Expect the Escalated event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.Escalated(proposalId, escalator);

    // Escalate the approved proposal
    vm.prank(escalator);
    proposalHatter.escalate(proposalId);

    // Update expected state to Escalated
    expected.state = IProposalHatterTypes.ProposalState.Escalated;

    // Verify proposal data is correct after escalation
    _assertProposalData(_getProposalData(proposalId), expected);

    // Verify approver hat was toggled off
    _assertHatToggle(expected.approverHatId, address(proposalHatter), false);
  }

  function test_RevertIf_NotEscalator() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(102)));

    // Attempt to escalate as non-escalator
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.escalate(proposalId);
  }

  function test_RevertIf_Escalate_None() public {
    // Create a fake proposal ID that doesn't exist
    bytes32 nonExistentProposalId = bytes32(uint256(999_999));

    // Attempt to escalate a non-existent proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.None)
    );
    vm.prank(escalator);
    proposalHatter.escalate(nonExistentProposalId);
  }

  function test_RevertIf_Escalate_Escalated() public {
    // Create and escalate a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(103)));

    vm.prank(escalator);
    proposalHatter.escalate(proposalId);

    // Attempt to escalate again
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Escalated)
    );
    vm.prank(escalator);
    proposalHatter.escalate(proposalId);
  }

  function test_RevertIf_Escalate_Canceled() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(104)));

    // Cancel the proposal
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);

    // Attempt to escalate a canceled proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Canceled)
    );
    vm.prank(escalator);
    proposalHatter.escalate(proposalId);
  }

  function test_RevertIf_Escalate_Rejected() public {
    // Create a proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(105)));

    // Mint approver hat and reject the proposal
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    vm.prank(approver);
    proposalHatter.reject(proposalId);

    // Attempt to escalate a rejected proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Rejected)
    );
    vm.prank(escalator);
    proposalHatter.escalate(proposalId);
  }

  function test_EscalateDoesNotCheckPause() public {
    // Create a proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(106)));

    // Owner pauses proposals
    vm.prank(org);
    proposalHatter.pauseProposals(true);

    // Escalate should work even when paused (by design)
    vm.prank(escalator);
    proposalHatter.escalate(proposalId);

    // Verify escalation succeeded
    expected.state = IProposalHatterTypes.ProposalState.Escalated;
    _assertProposalData(_getProposalData(proposalId), expected);

    // Verify approver hat was toggled off
    _assertHatToggle(expected.approverHatId, address(proposalHatter), false);
  }
}
