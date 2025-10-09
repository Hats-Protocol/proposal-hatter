// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import {
  IProposalHatterEvents, IProposalHatterErrors, IProposalHatterTypes
} from "../../src/interfaces/IProposalHatter.sol";

/// @title Approve Tests for ProposalHatter
/// @notice Tests for proposal approval functionality
contract Approve_Tests is ForkTestBase {
  // --------------------
  // Approve Tests
  // --------------------

  function test_ApproveActiveProposal() public {
    // Create a proposal with a timelock
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(1)));

    // Verify initial state
    _assertProposalData(_getProposalData(proposalId), expected);

    // Mint approver hat to approver
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    // Calculate expected ETA
    uint64 expectedEta = uint64(block.timestamp) + expected.timelockSec;

    // Expect the Approved event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.Approved(proposalId, approver, expectedEta);

    // Approve the proposal
    vm.prank(approver);
    proposalHatter.approve(proposalId);

    // Update expected state and eta for verification
    expected.state = IProposalHatterTypes.ProposalState.Approved;
    expected.eta = expectedEta;

    // Verify proposal data is correct after approval
    _assertProposalData(_getProposalData(proposalId), expected);

    // Verify approver hat was toggled off
    _assertHatToggle(expected.approverHatId, address(proposalHatter), false);
  }

  function test_RevertIf_NotApprover() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(2)));

    // Attempt to approve as non-approver (maliciousActor doesn't wear the approver hat)
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.approve(proposalId);
  }

  function testFuzz_ApproveTimelock(uint32 timelockSec) public {
    // Create a proposal with fuzzed timelock
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(timelockSec, bytes32(uint256(3)));

    // Mint approver hat to approver
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    // Calculate expected ETA
    uint64 expectedEta = uint64(block.timestamp) + timelockSec;

    // Approve the proposal
    vm.prank(approver);
    proposalHatter.approve(proposalId);

    // Update expected state and eta
    expected.state = IProposalHatterTypes.ProposalState.Approved;
    expected.eta = expectedEta;

    // Verify ETA is correctly set based on fuzzed timelock
    _assertProposalData(_getProposalData(proposalId), expected);

    // Verify approver hat was toggled off
    _assertHatToggle(expected.approverHatId, address(proposalHatter), false);
  }

  function test_RevertIf_Approve_None() public {
    // Create a fake proposal ID that doesn't exist
    bytes32 nonExistentProposalId = bytes32(uint256(999_999));

    // Attempt to approve a non-existent proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.None)
    );
    vm.prank(approver);
    proposalHatter.approve(nonExistentProposalId);
  }

  function test_RevertIf_Approve_AlreadyApproved() public {
    // Create and approve a proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(4)));

    // Mint approver hat and approve
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    vm.prank(approver);
    proposalHatter.approve(proposalId);

    // Attempt to approve again
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Approved)
    );
    vm.prank(approver);
    proposalHatter.approve(proposalId);
  }

  function test_RevertIf_Approve_Executed() public {
    // Create, approve, and execute a proposal
    (bytes32 proposalId,) = _executeFullProposalLifecycle();

    // Attempt to approve an executed proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Executed)
    );
    vm.prank(approver);
    proposalHatter.approve(proposalId);
  }

  function test_RevertIf_Approve_Escalated() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(5)));

    // Escalate the proposal (escalator hat already minted in setup)
    vm.prank(escalator);
    proposalHatter.escalate(proposalId);

    // Attempt to approve an escalated proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Escalated)
    );
    vm.prank(approver);
    proposalHatter.approve(proposalId);
  }

  function test_RevertIf_Approve_Canceled() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 days, bytes32(uint256(6)));

    // Cancel the proposal (as the proposer who is the submitter)
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);

    // Attempt to approve a canceled proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Canceled)
    );
    vm.prank(approver);
    proposalHatter.approve(proposalId);
  }

  function test_RevertIf_Approve_Rejected() public {
    // Create a proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(7)));

    // Mint approver hat and reject the proposal
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    vm.prank(approver);
    proposalHatter.reject(proposalId);

    // Attempt to approve a rejected proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Rejected)
    );
    vm.prank(approver);
    proposalHatter.approve(proposalId);
  }
}
