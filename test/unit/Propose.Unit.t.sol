// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import {
  IProposalHatterEvents, IProposalHatterErrors, IProposalHatterTypes
} from "../../src/interfaces/IProposalHatter.sol";
import { Strings } from "../../lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import { IMulticallable } from "../../src/interfaces/IMulticallable.sol";

/// @title Propose Tests for ProposalHatter
/// @notice Tests for proposal creation and reserved hat functionality
contract Propose_Tests is ForkTestBase {
  // --------------------
  // Propose Tests
  // --------------------

  function test_ProposeValid() public {
    // Build a valid hats multicall payload that creates a hat during execution
    bytes memory hatsMulticall = _buildSingleHatCreationMulticall(approverBranchId, "Lifecycle Hat");

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

  function test_ProposeRolesOnly_ValidMulticall() public {
    // Build a valid hats multicall payload that creates a hat during execution
    bytes memory hatsMulticall = _buildSingleHatCreationMulticall(approverBranchId, "Lifecycle Hat");

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

  function test_ProposeRolesOnly_RevertIf_MulticallTooShort() public {
    // Build an invalid hats multicall payload that is too short (<4 bytes)
    bytes memory hatsMulticall = hex"12345678";

    // Build expected proposal data with roles only (0 funding, arbitrary token)
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 0, ETH, 1 days, recipientHat, 0, hatsMulticall, IProposalHatterTypes.ProposalState.Active
    );

    // Attempt to propose with invalid hatsMulticall
    vm.expectRevert(IProposalHatterErrors.InvalidMulticall.selector);
    vm.prank(proposer);
    proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      bytes32(uint256(1))
    );
  }

  function testFuzz_ProposeRolesOnly_RevertIf_MulticallWrongSelector(bytes4 selector) public {
    // Build an invalid hats multicall that doesn't match the multicall selector
    bytes memory hatsMulticall = abi.encodeWithSelector(selector, new bytes[](1));

    // Build expected proposal data with roles only (0 funding, arbitrary token)
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 0, ETH, 1 days, recipientHat, 0, hatsMulticall, IProposalHatterTypes.ProposalState.Active
    );

    // Attempt to propose with invalid hatsMulticall
    vm.expectRevert(IProposalHatterErrors.InvalidMulticall.selector);
    vm.prank(proposer);
    proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      bytes32(uint256(1))
    );
  }

  function testFuzz_ProposeRolesOnly_RevertIf_MulticallInvalidPayload(bytes32 args) public {
    // Build an invalid hats multicall payload
    bytes memory hatsMulticall = abi.encodeWithSelector(IMulticallable.multicall.selector, args);

    // Build expected proposal data with roles only (0 funding, arbitrary token)
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, 0, ETH, 1 days, recipientHat, 0, hatsMulticall, IProposalHatterTypes.ProposalState.Active
    );

    // Attempt to propose with invalid hatsMulticall
    vm.expectRevert(IProposalHatterErrors.InvalidMulticall.selector);
    vm.prank(proposer);
    proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      bytes32(uint256(1))
    );
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

  // --------------------
  // Reserved Hat Tests
  // --------------------

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
