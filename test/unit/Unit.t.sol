// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import { ProposalHatter } from "../../src/ProposalHatter.sol";
import {
  IProposalHatter,
  IProposalHatterEvents,
  IProposalHatterErrors,
  IProposalHatterTypes
} from "../../src/interfaces/IProposalHatter.sol";
import { Strings } from "../../lib/openzeppelin-contracts/contracts/utils/Strings.sol";

/// @title Unit Tests for ProposalHatter
/// @notice Comprehensive unit tests organized by contract function

// =============================================================================
// Constructor Tests
// =============================================================================

contract Constructor_Tests is ForkTestBase {
  function test_DeployWithValidParams() public {
    // Deploy a fresh instance to capture events
    vm.startPrank(deployer);

    // Expect all deployment events in order
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.ProposalHatterDeployed(HATS_PROTOCOL, ownerHat, approverBranchId, opsBranchId);

    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.ProposerHatSet(proposerHat);

    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.EscalatorHatSet(escalatorHat);

    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.ExecutorHatSet(executorHat);

    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.SafeSet(primarySafe);

    // Deploy
    ProposalHatter testInstance = new ProposalHatter(
      HATS_PROTOCOL, primarySafe, ownerHat, proposerHat, executorHat, escalatorHat, approverBranchId, opsBranchId
    );

    vm.stopPrank();

    // Verify immutables
    assertEq(testInstance.HATS_PROTOCOL_ADDRESS(), HATS_PROTOCOL, "HATS_PROTOCOL_ADDRESS mismatch");
    assertEq(testInstance.OWNER_HAT(), ownerHat, "OWNER_HAT mismatch");
    assertEq(testInstance.APPROVER_BRANCH_ID(), approverBranchId, "APPROVER_BRANCH_ID mismatch");
    assertEq(testInstance.OPS_BRANCH_ID(), opsBranchId, "OPS_BRANCH_ID mismatch");

    // Verify mutable storage
    assertEq(testInstance.safe(), primarySafe, "safe mismatch");
    assertEq(testInstance.proposerHat(), proposerHat, "proposerHat mismatch");
    assertEq(testInstance.executorHat(), executorHat, "executorHat mismatch");
    assertEq(testInstance.escalatorHat(), escalatorHat, "escalatorHat mismatch");

    // Verify pause states (should be false by default)
    assertFalse(testInstance.proposalsPaused(), "proposals should not be paused");
    assertFalse(testInstance.withdrawalsPaused(), "withdrawals should not be paused");
  }

  function test_RevertIf_ZeroHatsProtocol() public {
    vm.expectRevert(IProposalHatterErrors.ZeroAddress.selector);
    new ProposalHatter(
      address(0), // zero hatsProtocol
      primarySafe,
      ownerHat,
      proposerHat,
      executorHat,
      escalatorHat,
      approverBranchId,
      opsBranchId
    );
  }

  function test_RevertIf_ZeroSafe() public {
    vm.expectRevert(IProposalHatterErrors.ZeroAddress.selector);
    new ProposalHatter(
      HATS_PROTOCOL,
      address(0), // zero safe
      ownerHat,
      proposerHat,
      executorHat,
      escalatorHat,
      approverBranchId,
      opsBranchId
    );
  }

  function test_RevertIf_ZeroOwnerHat() public {
    vm.expectRevert(IProposalHatterErrors.ZeroAddress.selector);
    new ProposalHatter(
      HATS_PROTOCOL,
      primarySafe,
      0, // zero ownerHat
      proposerHat,
      executorHat,
      escalatorHat,
      approverBranchId,
      opsBranchId
    );
  }

  function test_DeployWithZeroOpsBranchId() public {
    // opsBranchId = 0 is valid (disables branch check for reserved hats)
    ProposalHatter testInstance = new ProposalHatter(
      HATS_PROTOCOL,
      primarySafe,
      ownerHat,
      proposerHat,
      executorHat,
      escalatorHat,
      approverBranchId,
      0 // zero opsBranchId is allowed
    );

    // Verify it was set correctly
    assertEq(testInstance.OPS_BRANCH_ID(), 0, "OPS_BRANCH_ID should be 0");
  }

  function testFuzz_DeployWithRoles(uint256 proposerHatId, uint256 executorHatId, uint256 escalatorHatId) public {
    // Bound the hat IDs to reasonable values (non-zero, less than max uint256)
    proposerHatId = bound(proposerHatId, 1, type(uint256).max);
    executorHatId = bound(executorHatId, 1, type(uint256).max);
    escalatorHatId = bound(escalatorHatId, 1, type(uint256).max);

    ProposalHatter testInstance = new ProposalHatter(
      HATS_PROTOCOL, primarySafe, ownerHat, proposerHatId, executorHatId, escalatorHatId, approverBranchId, opsBranchId
    );

    // Verify all role hats were set correctly
    assertEq(testInstance.proposerHat(), proposerHatId, "proposerHat mismatch");
    assertEq(testInstance.executorHat(), executorHatId, "executorHat mismatch");
    assertEq(testInstance.escalatorHat(), escalatorHatId, "escalatorHat mismatch");
  }
}

// =============================================================================
// Propose Tests
// =============================================================================

contract Propose_Tests is ForkTestBase {
  function test_ProposeValid() public {
    // Arbitrary hats multicall bytes (don't need to be valid for proposal tests)
    bytes memory hatsMulticall = hex"1234567890abcdef";

    // Build expected proposal data
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 10 ether, ETH, 1 days, recipientHat, 0, hatsMulticall, IProposalHatterTypes.ProposalState.Active
    );
    bytes32 salt = bytes32(uint256(1));

    // Compute expected proposal ID
    bytes32 expectedProposalId = proposalHatter.computeProposalId(
      expected.submitter,
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.safe,
      expected.recipientHatId,
      expected.hatsMulticall,
      salt
    );

    // Expect the Proposed event
    vm.expectEmit(true, true, true, true);
    emit IProposalHatterEvents.Proposed(
      expectedProposalId,
      keccak256(expected.hatsMulticall),
      expected.submitter,
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.safe,
      expected.recipientHatId,
      expected.approverHatId,
      expected.reservedHatId,
      salt
    );

    // Create proposal
    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );

    // Verify proposal ID
    assertEq(proposalId, expectedProposalId, "Proposal ID mismatch");

    // Verify determinism
    assertEq(
      proposalHatter.computeProposalId(
        expected.submitter,
        expected.fundingAmount,
        expected.fundingToken,
        expected.timelockSec,
        expected.safe,
        expected.recipientHatId,
        expected.hatsMulticall,
        salt
      ),
      expectedProposalId,
      "Proposal ID not deterministic"
    );

    // Verify approver hat was created correctly
    _assertHatCreated(expected.approverHatId, approverBranchId, Strings.toHexString(uint256(proposalId), 32));

    // Verify proposal data stored correctly
    _assertProposalData(_getProposalData(proposalId), expected);
  }

  function test_RevertIf_NotProposer() public {
    // Build proposal data
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      maliciousActor, 1 ether, ETH, 1 days, recipientHat, 0, "", IProposalHatterTypes.ProposalState.Active
    );
    bytes32 salt = bytes32(uint256(1));

    // Attempt to propose as non-proposer
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );
  }

  function test_RevertIf_ProposalsPaused() public {
    // Owner pauses proposals
    vm.prank(org);
    proposalHatter.pauseProposals(true);

    // Build proposal data
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 1 ether, ETH, 1 days, recipientHat, 0, "", IProposalHatterTypes.ProposalState.Active
    );
    bytes32 salt = bytes32(uint256(1));

    // Attempt to propose while paused
    vm.expectRevert(IProposalHatterErrors.ProposalsArePaused.selector);
    vm.prank(proposer);
    proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );
  }

  function testFuzz_ProposeWithParams(uint88 fundingAmount, uint256 tokenSeed, uint32 timelockSec, bytes32 salt) public {
    address fundingToken = _getFundingToken(tokenSeed);
    // Build proposal data with fuzzed params
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, fundingAmount, fundingToken, timelockSec, recipientHat, 0, "", IProposalHatterTypes.ProposalState.Active
    );

    // Compute expected proposal ID
    bytes32 expectedProposalId = proposalHatter.computeProposalId(
      expected.submitter,
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.safe,
      expected.recipientHatId,
      expected.hatsMulticall,
      salt
    );

    // Create proposal
    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );

    // Verify proposal ID matches expected
    assertEq(proposalId, expectedProposalId, "Proposal ID mismatch");

    // Verify proposal data stored correctly
    _assertProposalData(_getProposalData(proposalId), expected);
  }

  function test_ProposeFundingOnly() public {
    // Build proposal data with only funding (empty hatsMulticall)
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 5 ether, ETH, 1 days, recipientHat, 0, "", IProposalHatterTypes.ProposalState.Active
    );
    bytes32 salt = bytes32(uint256(42));

    // Compute expected proposal ID
    bytes32 expectedProposalId = proposalHatter.computeProposalId(
      expected.submitter,
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.safe,
      expected.recipientHatId,
      expected.hatsMulticall,
      salt
    );

    // Create proposal
    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );

    // Verify proposal created
    assertEq(proposalId, expectedProposalId, "Proposal ID mismatch");

    // Verify empty hatsMulticall preserved
    _assertProposalData(_getProposalData(proposalId), expected);
  }

  function testFuzz_ProposeRolesOnly(bytes calldata hatsMulticall) public {
    // Build expected proposal data with roles only (0 funding, arbitrary token)
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 0, ETH, 1 days, recipientHat, 0, hatsMulticall, IProposalHatterTypes.ProposalState.Active
    );
    bytes32 salt = bytes32(uint256(200));

    // Compute expected proposal ID
    bytes32 expectedProposalId = proposalHatter.computeProposalId(
      expected.submitter,
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.safe,
      expected.recipientHatId,
      expected.hatsMulticall,
      salt
    );

    // Create proposal with roles only (0 funding)
    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );

    // Verify proposal ID
    assertEq(proposalId, expectedProposalId, "Proposal ID mismatch");

    // Verify proposal data stored correctly with fuzzed hatsMulticall
    _assertProposalData(_getProposalData(proposalId), expected);
  }

  function test_RevertIf_DuplicateProposal() public {
    // Build proposal data
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 3 ether, ETH, 2 days, recipientHat, 0, "", IProposalHatterTypes.ProposalState.Active
    );
    bytes32 salt = bytes32(uint256(123));

    // Create first proposal
    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );

    // Attempt to create duplicate proposal with same parameters
    vm.expectRevert(abi.encodeWithSelector(IProposalHatterErrors.AlreadyUsed.selector, proposalId));
    vm.prank(proposer);
    proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );
  }

  function testFuzz_ProposeFundingAmountBoundary(uint88 fundingAmount) public {
    // Build proposal data with fuzzed funding amount (tests full uint88 range)
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, fundingAmount, ETH, 1 days, recipientHat, 0, "", IProposalHatterTypes.ProposalState.Active
    );
    bytes32 salt = bytes32(uint256(fundingAmount)); // Use fundingAmount as salt for uniqueness

    // Create proposal
    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );

    // Verify proposal data stored correctly with full uint88 range
    _assertProposalData(_getProposalData(proposalId), expected);
  }
}

// =============================================================================
// Reserved Hat Tests
// =============================================================================

contract ReservedHat_Tests is ForkTestBase {
  function test_ProposeWithReservedHat() public {
    // Get the next hat ID under opsBranchId for the reserved hat
    uint256 expectedReservedHatId = _getNextHatId(opsBranchId);

    // Build expected proposal data with reserved hat
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 5 ether, ETH, 1 days, recipientHat, expectedReservedHatId, "", IProposalHatterTypes.ProposalState.Active
    );
    bytes32 salt = bytes32(uint256(100));

    // Compute expected proposal ID
    bytes32 expectedProposalId = proposalHatter.computeProposalId(
      expected.submitter,
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.safe,
      expected.recipientHatId,
      expected.hatsMulticall,
      salt
    );

    // Create proposal with reserved hat
    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );

    // Verify proposal ID
    assertEq(proposalId, expectedProposalId, "Proposal ID mismatch");

    // Verify approver hat was created correctly
    _assertHatCreated(expected.approverHatId, approverBranchId, Strings.toHexString(uint256(proposalId), 32));

    // Verify reserved hat was created correctly
    _assertHatCreated(expectedReservedHatId, opsBranchId, Strings.toHexString(uint256(proposalId), 32));

    // Verify proposal data stored correctly
    _assertProposalData(_getProposalData(proposalId), expected);
  }

  function test_RevertIf_InvalidReservedHatId() public {
    // Get the next hat ID under opsBranchId
    uint256 nextHatId = _getNextHatId(opsBranchId);

    // Use a different (invalid) hat ID
    uint256 invalidReservedHatId = nextHatId + 1;

    // Build proposal data with invalid reserved hat ID
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 5 ether, ETH, 1 days, recipientHat, invalidReservedHatId, "", IProposalHatterTypes.ProposalState.Active
    );
    bytes32 salt = bytes32(uint256(101));

    // Attempt to create proposal with invalid reserved hat ID
    vm.expectRevert(IProposalHatterErrors.InvalidReservedHatId.selector);
    vm.prank(proposer);
    proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );
  }

  function test_RevertIf_InvalidReservedHatBranch() public {
    // Create a hat outside of the OPS_BRANCH_ID tree (under approverBranchId instead)
    vm.prank(org);
    uint256 hatOutsideOpsBranch =
      hats.createHat(approverBranchId, "Hat Outside Ops Branch", 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

    // Get next child of this hat (still outside OPS_BRANCH_ID tree)
    uint256 invalidReservedHatId = _getNextHatId(hatOutsideOpsBranch);

    // Build proposal data with reserved hat outside OPS_BRANCH_ID tree
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 5 ether, ETH, 1 days, recipientHat, invalidReservedHatId, "", IProposalHatterTypes.ProposalState.Active
    );
    bytes32 salt = bytes32(uint256(102));

    // Attempt to create proposal with reserved hat outside OPS_BRANCH_ID
    vm.expectRevert(IProposalHatterErrors.InvalidReservedHatBranch.selector);
    vm.prank(proposer);
    proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );
  }

  function test_ProposeWithoutReservedHat() public {
    // Build expected proposal data without reserved hat (reservedHatId = 0)
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 5 ether, ETH, 1 days, recipientHat, 0, "", IProposalHatterTypes.ProposalState.Active
    );
    bytes32 salt = bytes32(uint256(103));

    // Create proposal without reserved hat
    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      salt
    );

    // Verify proposal data stored correctly with reservedHatId = 0
    _assertProposalData(_getProposalData(proposalId), expected);
  }
}

// =============================================================================
// Approve Tests
// =============================================================================

contract Approve_Tests is ForkTestBase {
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
    bytes32 proposalId = _executeFullProposalLifecycle();

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

// =============================================================================
// Execute Tests
// =============================================================================

contract Execute_Tests is ForkTestBase {
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
}

// =============================================================================
// Public Execution Tests
// =============================================================================

contract PublicExecution_Tests is ForkTestBase {
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

// =============================================================================
// Escalate Tests
// =============================================================================

contract Escalate_Tests is ForkTestBase {
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
  }
}

// =============================================================================
// Reject Tests
// =============================================================================

contract Reject_Tests is ForkTestBase {
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
    // Note: Will revert with NotAuthorized because auth check happens before state check
    // and the approverHatId for a non-existent proposal is 0
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(approver);
    proposalHatter.reject(nonExistentProposalId);
  }

  function test_RevertIf_Reject_Approved() public {
    // Create and approve a proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(109)));

    // Mint approver hat and approve
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

    vm.prank(approver);
    proposalHatter.approve(proposalId);

    // Attempt to reject an approved proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Approved)
    );
    vm.prank(approver);
    proposalHatter.reject(proposalId);
  }

  function test_RevertIf_Reject_Escalated() public {
    // Create a proposal
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(110)));

    // Mint approver hat to approver (needed for auth check)
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

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
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(1 days, bytes32(uint256(111)));

    // Mint approver hat to approver (needed for auth check)
    vm.prank(approverAdmin);
    hats.mintHat(expected.approverHatId, approver);

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
  }
}

// =============================================================================
// Cancel Tests
// =============================================================================

contract Cancel_Tests is ForkTestBase {
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
    bytes32 proposalId = _executeFullProposalLifecycle();

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

// =============================================================================
// Admin Tests
// =============================================================================

contract Admin_Tests is ForkTestBase {
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

// =============================================================================
// View Tests
// =============================================================================

contract View_Tests is ForkTestBase {
  function testFuzz_AllowanceOf(uint256 tokenSeed, uint88 fundingAmount) public {
    address fundingToken = _getFundingToken(tokenSeed);

    vm.assume(fundingAmount > 0);

    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) =
      _createTestProposal(fundingAmount, fundingToken, 1 days, recipientHat, 0, "", bytes32(uint256(1)));
    _approveProposal(proposalId);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    uint88 allowance = proposalHatter.allowanceOf(expected.safe, expected.recipientHatId, expected.fundingToken);
    assertEq(allowance, expected.fundingAmount, "Allowance should match funding amount");

    uint88 zeroAllowance = proposalHatter.allowanceOf(secondarySafe, expected.recipientHatId, expected.fundingToken);
    assertEq(zeroAllowance, 0, "Non-existent allowance should be zero");
  }

  function test_ComputeProposalId_MatchesOnChain() public {
    // Prepare proposal parameters
    uint88 fundingAmount = 10 ether;
    address fundingToken = ETH;
    uint32 timelockSec = 1 days;
    uint256 recipientHatId = recipientHat;
    uint256 reservedHatId = 0;
    bytes memory hatsMulticall = "";
    bytes32 salt = bytes32(uint256(500));

    // Compute the expected proposal ID
    bytes32 expectedId = proposalHatter.computeProposalId(
      proposer, fundingAmount, fundingToken, timelockSec, primarySafe, recipientHatId, hatsMulticall, salt
    );

    // Create the proposal
    vm.prank(proposer);
    bytes32 actualId = proposalHatter.propose(
      fundingAmount, fundingToken, timelockSec, recipientHatId, reservedHatId, hatsMulticall, salt
    );

    // Verify they match
    assertEq(actualId, expectedId, "On-chain proposal ID should match computed ID");
  }

  function test_ComputeProposalId_Determinism() public view {
    // Compute the same proposal ID multiple times
    bytes32 id1 = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );
    bytes32 id2 = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );
    bytes32 id3 = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );

    // All should be identical (deterministic)
    assertEq(id1, id2, "ID should be deterministic (1 vs 2)");
    assertEq(id2, id3, "ID should be deterministic (2 vs 3)");
    assertEq(id1, id3, "ID should be deterministic (1 vs 3)");
  }

  function test_ComputeProposalId_DifferentSubmitters() public view {
    // Compute proposal IDs with same params but different submitters
    bytes32 idProposer = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );
    bytes32 idApprover = proposalHatter.computeProposalId(
      approver, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );
    bytes32 idExecutor = proposalHatter.computeProposalId(
      executor, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );

    // All should be different (submitter is part of hash)
    assertTrue(idProposer != idApprover, "Different submitters should produce different IDs (proposer vs approver)");
    assertTrue(idApprover != idExecutor, "Different submitters should produce different IDs (approver vs executor)");
    assertTrue(idProposer != idExecutor, "Different submitters should produce different IDs (proposer vs executor)");
  }

  function test_ComputeProposalId_IncludesChainId() public {
    // Compute a proposal ID on current chain (mainnet = 1)
    bytes32 idChain1 = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );

    // Change to a different chain ID
    vm.chainId(10); // Optimism chain ID

    // Compute the same proposal ID on different chain
    bytes32 idChain2 = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );

    // Should be different (chainId is part of hash)
    assertTrue(idChain1 != idChain2, "Different chain IDs should produce different proposal IDs");

    // Restore original chain ID
    vm.chainId(1);
  }

  function test_ComputeProposalId_IncludesSafe() public view {
    // Compute proposal IDs with same params but different safes
    bytes32 idPrimarySafe = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );
    bytes32 idSecondarySafe = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, secondarySafe, recipientHat, "", bytes32(uint256(1))
    );

    // Should be different (safe address is part of hash)
    assertTrue(idPrimarySafe != idSecondarySafe, "Different safes should produce different IDs");
  }

  function test_ComputeProposalId_IncludesContractAddress() public {
    // Deploy a second ProposalHatter instance with same parameters
    vm.prank(deployer);
    ProposalHatter secondInstance = new ProposalHatter(
      HATS_PROTOCOL, primarySafe, ownerHat, proposerHat, executorHat, escalatorHat, approverBranchId, opsBranchId
    );

    // Compute proposal IDs from both instances with identical params
    bytes32 idInstance1 = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );
    bytes32 idInstance2 = secondInstance.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );

    // Should be different (contract address is part of hash)
    assertTrue(idInstance1 != idInstance2, "Different contract addresses should produce different IDs");
  }

  function test_ComputeProposalId_IncludesHatsProtocol() public {
    // Deploy a ProposalHatter instance with a different HATS_PROTOCOL address
    address fakeHatsProtocol = makeAddr("fakeHatsProtocol");

    vm.prank(deployer);
    ProposalHatter differentHatsInstance = new ProposalHatter(
      fakeHatsProtocol, primarySafe, ownerHat, proposerHat, executorHat, escalatorHat, approverBranchId, opsBranchId
    );

    // Compute proposal IDs from both instances with identical params
    bytes32 idOriginal = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );
    bytes32 idDifferentHats = differentHatsInstance.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );

    // Should be different (HATS_PROTOCOL address is part of hash)
    assertTrue(idOriginal != idDifferentHats, "Different HATS_PROTOCOL addresses should produce different IDs");
  }

  /// @dev Does not fuzz address parameters to simplify fork-test state RPC usage
  function testFuzz_ComputeProposalId_AllParams(
    uint88 fundingAmount,
    uint32 timelockSec,
    uint256 recipientHatId,
    bytes32 salt
  ) public view {
    // Compute ID with fuzzed parameters (first time)
    bytes32 id1 =
      proposalHatter.computeProposalId(proposer, fundingAmount, ETH, timelockSec, primarySafe, recipientHatId, "", salt);

    // Compute again with same parameters (determinism check)
    bytes32 id2 =
      proposalHatter.computeProposalId(proposer, fundingAmount, ETH, timelockSec, primarySafe, recipientHatId, "", salt);

    // Should be identical (deterministic)
    assertEq(id1, id2, "Fuzzed parameters should produce deterministic IDs");

    // Compute with slightly different salt (uniqueness check)
    bytes32 id3 = proposalHatter.computeProposalId(
      proposer, fundingAmount, ETH, timelockSec, primarySafe, recipientHatId, "", bytes32(uint256(salt) + 1)
    );

    // Should be different (changing any param changes ID)
    assertTrue(id1 != id3, "Different salt should produce different ID");
  }

  function testFuzz_ComputeProposalId_WithTestActors(
    uint256 actorSeed,
    uint256 tokenSeed,
    uint88 fundingAmount,
    bytes32 salt
  ) public view {
    address proposer = _getTestActor(actorSeed);
    address fundingToken = _getFundingToken(tokenSeed);
    
    // Compute ID with test actor and token
    bytes32 id1 = proposalHatter.computeProposalId(
      proposer, fundingAmount, fundingToken, 1 days, primarySafe, recipientHat, "", salt
    );

    // Compute again with same parameters (determinism check)
    bytes32 id2 = proposalHatter.computeProposalId(
      proposer, fundingAmount, fundingToken, 1 days, primarySafe, recipientHat, "", salt
    );

    // Should be identical (deterministic)
    assertEq(id1, id2, "Should be deterministic with test actors");

    // Different actor should produce different ID (avoid overflow)
    address differentProposer = _getTestActor(actorSeed ^ 1); // XOR to get different actor safely
    bytes32 id3 = proposalHatter.computeProposalId(
      differentProposer, fundingAmount, fundingToken, 1 days, primarySafe, recipientHat, "", salt
    );

    // Only check if actors are actually different
    if (proposer != differentProposer) {
      assertTrue(id1 != id3, "Different actor should produce different ID");
    }
  }

  function test_ComputeProposalId_ChangingEachParam() public view {
    // Base ID
    bytes32 baseId = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );

    // Change submitter
    assertTrue(
      baseId
        != proposalHatter.computeProposalId(
          approver, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
        ),
      "Changing submitter should change ID"
    );

    // Change funding amount
    assertTrue(
      baseId
        != proposalHatter.computeProposalId(
          proposer, 2 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
        ),
      "Changing funding amount should change ID"
    );

    // Change token
    assertTrue(
      baseId
        != proposalHatter.computeProposalId(
          proposer, 1 ether, USDC, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
        ),
      "Changing token should change ID"
    );

    // Change timelock
    assertTrue(
      baseId
        != proposalHatter.computeProposalId(
          proposer, 1 ether, ETH, 2 days, primarySafe, recipientHat, "", bytes32(uint256(1))
        ),
      "Changing timelock should change ID"
    );

    // Change safe
    assertTrue(
      baseId
        != proposalHatter.computeProposalId(
          proposer, 1 ether, ETH, 1 days, secondarySafe, recipientHat, "", bytes32(uint256(1))
        ),
      "Changing safe should change ID"
    );

    // Change recipient
    assertTrue(
      baseId
        != proposalHatter.computeProposalId(
          proposer, 1 ether, ETH, 1 days, primarySafe, proposerHat, "", bytes32(uint256(1))
        ),
      "Changing recipient should change ID"
    );

    // Change multicall
    assertTrue(
      baseId
        != proposalHatter.computeProposalId(
          proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, hex"1234", bytes32(uint256(1))
        ),
      "Changing multicall should change ID"
    );

    // Change salt
    assertTrue(
      baseId
        != proposalHatter.computeProposalId(
          proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(2))
        ),
      "Changing salt should change ID"
    );
  }

  function test_ComputeProposalId_EmptyVsNonEmptyMulticall() public view {
    // Compute ID with empty multicall
    bytes32 idEmpty = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, "", bytes32(uint256(1))
    );

    // Compute ID with non-empty multicall
    bytes memory nonEmptyMulticall = hex"1234567890abcdef";
    bytes32 idNonEmpty = proposalHatter.computeProposalId(
      proposer, 1 ether, ETH, 1 days, primarySafe, recipientHat, nonEmptyMulticall, bytes32(uint256(1))
    );

    // Should be different
    assertTrue(idEmpty != idNonEmpty, "Empty vs non-empty multicall should produce different IDs");
  }

  function test_GetProposalState() public {
    // Test None state (non-existent proposal)
    bytes32 nonExistentId = bytes32(uint256(999_999));
    assertEq(
      uint8(proposalHatter.getProposalState(nonExistentId)),
      uint8(IProposalHatterTypes.ProposalState.None),
      "Non-existent proposal should be None"
    );

    // Create a proposal (Active state)
    (bytes32 activeId,) = _createTestProposal(1 days, bytes32(uint256(600)));
    assertEq(
      uint8(proposalHatter.getProposalState(activeId)),
      uint8(IProposalHatterTypes.ProposalState.Active),
      "New proposal should be Active"
    );

    // Approve it (Approved state)
    _approveProposal(activeId);
    assertEq(
      uint8(proposalHatter.getProposalState(activeId)),
      uint8(IProposalHatterTypes.ProposalState.Approved),
      "Approved proposal should be Approved"
    );

    // Execute it (Executed state)
    _warpPastETA(activeId);
    _executeProposal(activeId);
    assertEq(
      uint8(proposalHatter.getProposalState(activeId)),
      uint8(IProposalHatterTypes.ProposalState.Executed),
      "Executed proposal should be Executed"
    );

    // Test Escalated state
    (bytes32 escalatedId,) = _createTestProposal(1 days, bytes32(uint256(601)));
    vm.prank(escalator);
    proposalHatter.escalate(escalatedId);
    assertEq(
      uint8(proposalHatter.getProposalState(escalatedId)),
      uint8(IProposalHatterTypes.ProposalState.Escalated),
      "Escalated proposal should be Escalated"
    );

    // Test Canceled state
    (bytes32 canceledId,) = _createTestProposal(1 days, bytes32(uint256(602)));
    vm.prank(proposer);
    proposalHatter.cancel(canceledId);
    assertEq(
      uint8(proposalHatter.getProposalState(canceledId)),
      uint8(IProposalHatterTypes.ProposalState.Canceled),
      "Canceled proposal should be Canceled"
    );

    // Test Rejected state
    (bytes32 rejectedId, IProposalHatterTypes.ProposalData memory rejectedProposal) =
      _createTestProposal(1 days, bytes32(uint256(603)));
    vm.prank(approverAdmin);
    hats.mintHat(rejectedProposal.approverHatId, approver);
    vm.prank(approver);
    proposalHatter.reject(rejectedId);
    assertEq(
      uint8(proposalHatter.getProposalState(rejectedId)),
      uint8(IProposalHatterTypes.ProposalState.Rejected),
      "Rejected proposal should be Rejected"
    );
  }
}
