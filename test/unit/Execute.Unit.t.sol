// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import {
  IProposalHatter,
  IProposalHatterEvents,
  IProposalHatterErrors,
  IProposalHatterTypes
} from "../../src/interfaces/IProposalHatter.sol";
import { IHats } from "../../lib/hats-protocol/src/Interfaces/IHats.sol";
import { HatsErrors } from "../../lib/hats-protocol/src/Interfaces/HatsErrors.sol";
import { stdError } from "forge-std/StdError.sol";

/// @title Execute Tests for ProposalHatter
/// @notice Tests for proposal execution functionality
contract Execute_Tests is ForkTestBase {
  // --------------------
  // Execute Tests
  // --------------------

  function test_ExecuteApprovedAfterETA() public {
    uint88 fundingAmount = 1e18;
    address fundingToken = ETH;
    uint32 timelock = 1 hours;
    string memory newHatDetails = "Ops Execution Hat";

    // create + approve proposal with a simple hat creation multicall
    (bytes32 proposalId, uint256 expectedNewHatId, IProposalHatterTypes.ProposalData memory expectedProposal) =
    _createApprovedProposalWithHatCreation(
      opsBranchId, newHatDetails, fundingAmount, fundingToken, timelock, recipientHat, 0, bytes32("execute-after-eta")
    );

    // sanity-check proposal snapshot after approval
    IProposalHatterTypes.ProposalData memory proposalDataAfterApproval = _getProposalData(proposalId);
    _assertProposalData(proposalDataAfterApproval, expectedProposal);

    // move past ETA for execution
    _warpPastETA(proposalId);

    // check initial allowance
    address safe_ = proposalHatter.safe();
    uint88 initialAllowance = proposalHatter.allowanceOf(safe_, recipientHat, fundingToken);
    assertEq(uint256(initialAllowance), 0, "pre-execution allowance should be zero");

    // expect execute event with updated allowance
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.Executed(proposalId, recipientHat, safe_, fundingToken, fundingAmount, fundingAmount);

    // execute proposal as authorized executor
    _executeProposal(proposalId);

    // check final allowance
    uint88 postAllowance = proposalHatter.allowanceOf(safe_, recipientHat, fundingToken);
    assertEq(uint256(postAllowance), fundingAmount, "allowance should increase by funding amount");

    // proposal snapshot post-execution, ensure state is Executed and hatsMulticall is empty
    IProposalHatterTypes.ProposalData memory proposalData = _getProposalData(proposalId);
    expectedProposal.state = IProposalHatterTypes.ProposalState.Executed;
    expectedProposal.hatsMulticall = bytes(""); // hatsMulticall gets cleared after execution for gas savings
    _assertProposalData(proposalData, expectedProposal);

    // ensure hat was created through multicall
    _assertHatCreated(expectedNewHatId, opsBranchId, newHatDetails);
  }

  function test_RevertIf_TooEarly() public {
    uint32 timelock = 1 hours;
    string memory newHatDetails = "Ops Execution Hat";

    // create + approve proposal with a non-zero timelock
    (bytes32 proposalId,, IProposalHatterTypes.ProposalData memory expectedProposal) =
    _createApprovedProposalWithHatCreation(
      opsBranchId, newHatDetails, 1e18, ETH, timelock, recipientHat, 0, bytes32("too-early")
    );

    // confirm snapshot after approval
    IProposalHatterTypes.ProposalData memory proposalDataAfterApproval = _getProposalData(proposalId);
    _assertProposalData(proposalDataAfterApproval, expectedProposal);

    // should revert because block.timestamp < eta
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.TooEarly.selector, expectedProposal.eta, uint64(block.timestamp))
    );
    _executeProposal(proposalId);

    // state should remain Approved after failed execution
    IProposalHatterTypes.ProposalData memory proposalData = _getProposalData(proposalId);
    _assertProposalData(proposalData, expectedProposal);
  }

  function test_RevertIf_NotExecutor() public {
    string memory newHatDetails = "Ops Execution Hat";

    // create + approve proposal (timelock 0 for simplicity)
    (bytes32 proposalId,, IProposalHatterTypes.ProposalData memory expectedProposal) =
    _createApprovedProposalWithHatCreation(
      opsBranchId, newHatDetails, 1e18, ETH, 0, recipientHat, 0, bytes32("not-executor")
    );

    // confirm snapshot after approval
    IProposalHatterTypes.ProposalData memory proposalDataAfterApproval = _getProposalData(proposalId);
    _assertProposalData(proposalDataAfterApproval, expectedProposal);

    // have the real executor renounce their hat to simulate unauthorized access locally
    vm.prank(executor);
    hats.renounceHat(executorHat);

    // unauthorized caller (no executor hat) should revert
    vm.prank(executor);
    vm.expectRevert(abi.encodeWithSelector(IProposalHatterErrors.NotAuthorized.selector));
    proposalHatter.execute(proposalId);

    // state should remain Approved after failed execution
    IProposalHatterTypes.ProposalData memory proposalData = _getProposalData(proposalId);
    _assertProposalData(proposalData, expectedProposal);
  }

  function test_RevertIf_ExecuteAllowanceOverflow() public {
    uint88 baseAllowance = type(uint88).max - 10;
    uint88 fundingAmount = 11;

    // seed the allowance ledger near the uint88 limit
    (, IProposalHatterTypes.ProposalData memory firstExpected) =
      _executeFullProposalLifecycle(ETH, baseAllowance, recipientHat);

    // confirm base allowance is recorded for the correct safe
    address safe_ = firstExpected.safe;
    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, ETH)),
      uint256(baseAllowance),
      "base allowance not recorded"
    );

    // stage a second proposal that would overflow the ledger
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _createTestProposal(fundingAmount, ETH, 0, recipientHat, 0, "", bytes32("allowance-overflow"));

    // approve but do not execute yet (still Approved)
    _approveProposal(proposalId);
    expectedProposal.state = IProposalHatterTypes.ProposalState.Approved;
    expectedProposal.eta = uint64(block.timestamp);
    _assertProposalData(_getProposalData(proposalId), expectedProposal);
    vm.warp(block.timestamp + 1);

    // expect arithmetic overflow during execute
    vm.expectRevert(stdError.arithmeticError);
    _executeProposal(proposalId);

    // proposal stays Approved and allowance unchanged after revert
    _assertProposalData(_getProposalData(proposalId), expectedProposal);
    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, ETH)),
      uint256(baseAllowance),
      "allowance should remain unchanged"
    );
  }

  function test_ExecuteUsesProposalSafe() public {
    uint88 fundingAmount = 5 ether;

    // create + approve proposal using primary safe
    (bytes32 proposalId,, IProposalHatterTypes.ProposalData memory expectedProposal) =
    _createApprovedProposalWithHatCreation(
      opsBranchId, "Safe-bound Execute", fundingAmount, ETH, 0, recipientHat, 0, bytes32("proposal-safe")
    );

    // verify snapshot before changing global safe
    _assertProposalData(_getProposalData(proposalId), expectedProposal);

    // change the global safe before execution; proposal should still target its stored safe
    vm.prank(org);
    proposalHatter.setSafe(secondarySafe);

    // execute and confirm stored safe is honored
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    IProposalHatterTypes.ProposalData memory proposalData = _getProposalData(proposalId);
    expectedProposal.state = IProposalHatterTypes.ProposalState.Executed;
    expectedProposal.hatsMulticall = bytes("");
    _assertProposalData(proposalData, expectedProposal);

    assertEq(
      uint256(proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, ETH)),
      uint256(fundingAmount),
      "allowance recorded for proposal safe"
    );
    assertEq(
      uint256(proposalHatter.allowanceOf(secondarySafe, recipientHat, ETH)),
      0,
      "changing global safe must not affect existing proposals"
    );
  }

  function test_ExecuteAtExactETA() public {
    uint32 timelock = 2 hours;

    // create + approve proposal with non-zero timelock
    (bytes32 proposalId,, IProposalHatterTypes.ProposalData memory expectedProposal) =
    _createApprovedProposalWithHatCreation(
      opsBranchId, "Exact ETA", 1 ether, ETH, timelock, recipientHat, 0, bytes32("exact-eta")
    );

    // confirm snapshot prior to execution
    _assertProposalData(_getProposalData(proposalId), expectedProposal);

    // warp exactly to eta and execute
    vm.warp(expectedProposal.eta);
    _executeProposal(proposalId);

    // proposal transitions to Executed at eta boundary
    IProposalHatterTypes.ProposalData memory proposalData = _getProposalData(proposalId);
    expectedProposal.state = IProposalHatterTypes.ProposalState.Executed;
    expectedProposal.hatsMulticall = bytes("");
    _assertProposalData(proposalData, expectedProposal);

    // allowance should be recorded for the proposal safe
    assertEq(
      uint256(proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, ETH)),
      uint256(expectedProposal.fundingAmount),
      "allowance recorded for proposal safe"
    );
  }

  function test_ExecuteWithMulticall() public {
    // create + approve proposal that should create a hat on execution
    (bytes32 proposalId, uint256 expectedNewHatId, IProposalHatterTypes.ProposalData memory expectedProposal) =
    _createApprovedProposalWithHatCreation(
      opsBranchId, "Multicall Hat", 1 ether, ETH, 0, recipientHat, 0, bytes32("with-multicall")
    );

    // ensure hatsMulticall payload is persisted before execution
    bytes memory storedBefore = _getProposalData(proposalId).hatsMulticall;
    assertEq(storedBefore, expectedProposal.hatsMulticall, "hatsMulticall should be stored before execution");

    // execute and expect multicall to run + storage cleared
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    IProposalHatterTypes.ProposalData memory proposalData = _getProposalData(proposalId);
    expectedProposal.state = IProposalHatterTypes.ProposalState.Executed;
    expectedProposal.hatsMulticall = bytes("");
    _assertProposalData(proposalData, expectedProposal);
    _assertHatCreated(expectedNewHatId, opsBranchId, "Multicall Hat");

    // allowance should be recorded for the proposal safe
    assertEq(
      uint256(proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, ETH)),
      uint256(expectedProposal.fundingAmount),
      "allowance recorded for proposal safe"
    );
  }

  function test_ExecuteWithoutMulticall() public {
    bytes memory hatsMulticall;
    uint256 nextHatBefore = _getNextHatId(opsBranchId);

    // create proposal with empty multicall payload
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _createTestProposal(2 ether, ETH, 0, recipientHat, 0, hatsMulticall, bytes32("no-multicall"));

    // approve and confirm hatsMulticall remains empty
    _approveProposal(proposalId);
    expectedProposal.state = IProposalHatterTypes.ProposalState.Approved;
    expectedProposal.eta = uint64(block.timestamp);
    _assertProposalData(_getProposalData(proposalId), expectedProposal);

    // execute and ensure no hat creation occurred
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    IProposalHatterTypes.ProposalData memory proposalData = _getProposalData(proposalId);
    expectedProposal.state = IProposalHatterTypes.ProposalState.Executed;
    _assertProposalData(proposalData, expectedProposal);
    assertEq(_getNextHatId(opsBranchId), nextHatBefore, "no hats should have been created");

    // Verify allowance was recorded for the proposal safe
    assertEq(
      uint256(proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, ETH)),
      uint256(expectedProposal.fundingAmount),
      "allowance recorded for proposal safe"
    );
  }

  function test_RevertIf_MulticallFails() public {
    uint256 targetHatId = approverBranchId;
    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeWithSelector(IHats.setHatStatus.selector, targetHatId, false);
    bytes memory failingMulticall = abi.encode(calls);

    // craft proposal whose multicall will revert (unauthorized toggle call)
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _createTestProposal(1 ether, ETH, 0, recipientHat, 0, failingMulticall, bytes32("multicall-fail"));

    // approve and track snapshot prior to execution
    _approveProposal(proposalId);
    expectedProposal.state = IProposalHatterTypes.ProposalState.Approved;
    expectedProposal.eta = uint64(block.timestamp);
    _assertProposalData(_getProposalData(proposalId), expectedProposal);

    // expect entire execute to revert when hats multicall fails
    _warpPastETA(proposalId);

    vm.expectRevert();
    _executeProposal(proposalId);

    // proposal remains Approved with original data
    _assertProposalData(_getProposalData(proposalId), expectedProposal);
  }

  function test_RevertIf_Execute_None() public {
    bytes32 nonexistentProposalId = keccak256("nonexistent proposal");

    // executing a proposal id that does not exist should revert with InvalidState(None)
    vm.prank(executor);
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.None)
    );
    proposalHatter.execute(nonexistentProposalId);
  }

  function test_RevertIf_Execute_Escalated() public {
    // create + approve proposal
    (bytes32 proposalId,, IProposalHatterTypes.ProposalData memory expectedProposal) =
    _createApprovedProposalWithHatCreation(
      opsBranchId, "Escalated", 1 ether, ETH, 0, recipientHat, 0, bytes32("escalated")
    );

    // escalate and confirm state change
    vm.prank(escalator);
    proposalHatter.escalate(proposalId);
    expectedProposal.state = IProposalHatterTypes.ProposalState.Escalated;
    _assertProposalData(_getProposalData(proposalId), expectedProposal);

    // escalated proposals revert when executed
    vm.prank(executor);
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Escalated)
    );
    proposalHatter.execute(proposalId);
  }

  function test_RevertIf_Execute_Canceled() public {
    // create + approve proposal
    (bytes32 proposalId,, IProposalHatterTypes.ProposalData memory expectedProposal) =
    _createApprovedProposalWithHatCreation(
      opsBranchId, "Canceled", 1 ether, ETH, 0, recipientHat, 0, bytes32("canceled")
    );

    // cancel proposal and verify state
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);
    expectedProposal.state = IProposalHatterTypes.ProposalState.Canceled;
    _assertProposalData(_getProposalData(proposalId), expectedProposal);

    // executing canceled proposal should revert
    vm.prank(executor);
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Canceled)
    );
    proposalHatter.execute(proposalId);
  }

  function test_RevertIf_Execute_Rejected() public {
    // create proposal with multicall so we can reject it after approval stage
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expectedProposal) = _createTestProposal(
      1 ether,
      ETH,
      0,
      recipientHat,
      0,
      _buildSingleHatCreationMulticall(opsBranchId, "Rejected Hat"),
      bytes32("rejected")
    );

    // mint approver ticket hat and reject proposal
    _rejectProposal(proposalId);

    expectedProposal.state = IProposalHatterTypes.ProposalState.Rejected;
    _assertProposalData(_getProposalData(proposalId), expectedProposal);

    // rejected proposals cannot execute
    vm.prank(executor);
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Rejected)
    );
    proposalHatter.execute(proposalId);
  }

  function test_RevertIf_Execute_AlreadyExecuted() public {
    // run full lifecycle to executed state
    (bytes32 proposalId,) = _executeFullProposalLifecycle();

    // second execution attempt should revert with Executed state
    vm.prank(executor);
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Executed)
    );
    proposalHatter.execute(proposalId);
  }

  // --------------------
  // Public Execution Tests
  // --------------------

  function test_ExecutePublic() public {
    // set executor hat to sentinel meaning anyone can execute
    vm.prank(org);
    proposalHatter.setExecutorHat(PUBLIC_SENTINEL);

    // create + approve proposal under public execution
    (bytes32 proposalId,, IProposalHatterTypes.ProposalData memory expectedProposal) =
    _createApprovedProposalWithHatCreation(
      opsBranchId, "Public Execute", 1 ether, ETH, 0, recipientHat, 0, bytes32("public-execute")
    );

    // confirm snapshot before open execution
    _assertProposalData(_getProposalData(proposalId), expectedProposal);
    vm.warp(block.timestamp + 1);

    // arbitrary caller executes successfully
    vm.prank(maliciousActor);
    proposalHatter.execute(proposalId);

    // proposal finalized and hatsMulticall cleared
    IProposalHatterTypes.ProposalData memory proposalData = _getProposalData(proposalId);
    expectedProposal.state = IProposalHatterTypes.ProposalState.Executed;
    expectedProposal.hatsMulticall = bytes("");
    _assertProposalData(proposalData, expectedProposal);
  }

  function test_RevertIf_Execute_NotPublicAndNotExecutor() public {
    // create + approve proposal with executor hat requirement
    (bytes32 proposalId,, IProposalHatterTypes.ProposalData memory expectedProposal) =
    _createApprovedProposalWithHatCreation(
      opsBranchId, "Auth Check", 1 ether, ETH, 0, recipientHat, 0, bytes32("not-public")
    );

    // confirm initial snapshot
    _assertProposalData(_getProposalData(proposalId), expectedProposal);

    // temporarily give maliciousActor the executor hat then revoke locally to touch storage
    vm.prank(org);
    hats.transferHat(executorHat, executor, maliciousActor);
    vm.prank(maliciousActor);
    hats.renounceHat(executorHat);
    vm.prank(org);
    hats.mintHat(executorHat, executor);

    // malicious actor should still be blocked from executing
    vm.warp(block.timestamp + 1);

    vm.prank(maliciousActor);
    vm.expectRevert(abi.encodeWithSelector(IProposalHatterErrors.NotAuthorized.selector));
    proposalHatter.execute(proposalId);

    // proposal remains Approved for legitimate executor
    _assertProposalData(_getProposalData(proposalId), expectedProposal);
  }
}

/// @title ApproveAndExecute Tests for ProposalHatter
/// @notice Tests for proposal approval and execution functionality
contract ApproveAndExecute_Tests is ForkTestBase {
  // --------------------
  // ApproveAndExecute Tests
  // --------------------

  function test_ApproveAndExecuteZeroTimelock() public {
    // Create an active proposal with zero timelock and multicall
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expectedProposal) = _createTestProposal(
      2 ether,
      ETH,
      0, // zero timelock enables atomic approve+execute
      recipientHat,
      0,
      _buildSingleHatCreationMulticall(opsBranchId, "Atomic Approve+Execute"),
      bytes32("approve-execute-zero-timelock")
    );

    // Verify initial state is Active
    _assertProposalData(_getProposalData(proposalId), expectedProposal);

    // Mint approver ticket hat to approver
    vm.prank(approverAdmin);
    hats.mintHat(expectedProposal.approverHatId, approver);

    // Mint executor hat to approver (approveAndExecute requires both approver AND executor authorization)
    vm.prank(org);
    hats.mintHat(executorHat, approver);

    // Check initial allowance is zero
    uint88 initialAllowance = proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, ETH);
    assertEq(uint256(initialAllowance), 0, "pre-execution allowance should be zero");

    // Expect both Approved and Executed events in single atomic call
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.Approved(proposalId, approver, uint64(block.timestamp));
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.Executed(
      proposalId,
      expectedProposal.recipientHatId,
      expectedProposal.safe,
      expectedProposal.fundingToken,
      expectedProposal.fundingAmount,
      expectedProposal.fundingAmount
    );

    // Execute approveAndExecute as approver (who now also wears executor hat)
    vm.prank(approver);
    proposalHatter.approveAndExecute(proposalId);

    // Update expected state to Executed with ETA set and multicall cleared
    expectedProposal.state = IProposalHatterTypes.ProposalState.Executed;
    expectedProposal.eta = uint64(block.timestamp);
    expectedProposal.hatsMulticall = bytes(""); // cleared after execution

    // Verify proposal data is correct after atomic approve+execute
    _assertProposalData(_getProposalData(proposalId), expectedProposal);

    // Verify allowance was recorded for the proposal safe
    uint88 finalAllowance = proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, ETH);
    assertEq(uint256(finalAllowance), uint256(expectedProposal.fundingAmount), "allowance should match funding amount");
  }

  function test_RevertIf_NonZeroTimelock() public {
    // Create a proposal with non-zero timelock
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expectedProposal) = _createTestProposal(
      1 ether,
      ETH,
      1 hours, // non-zero timelock should prevent atomic approve+execute
      recipientHat,
      0,
      "",
      bytes32("non-zero-timelock")
    );

    // Mint approver ticket hat to approver
    vm.prank(approverAdmin);
    hats.mintHat(expectedProposal.approverHatId, approver);

    // Mint executor hat to approver
    vm.prank(org);
    hats.mintHat(executorHat, approver);

    // Attempt to approveAndExecute with non-zero timelock should revert
    vm.expectRevert(
      abi.encodeWithSelector(
        IProposalHatterErrors.TooEarly.selector,
        expectedProposal.timelockSec + uint64(block.timestamp), // eta
        uint64(block.timestamp) // nowTs
      )
    );
    vm.prank(approver);
    proposalHatter.approveAndExecute(proposalId);

    // Verify state remains Active (approval never happened)
    _assertProposalData(_getProposalData(proposalId), expectedProposal);
  }

  function test_RevertIf_NotApprover() public {
    // Create a proposal with zero timelock
    (bytes32 proposalId,) = _createTestProposal(1 ether, ETH, 0, recipientHat, 0, "", bytes32("not-approver"));

    // Mint executor hat to maliciousActor (but NOT approver hat)
    vm.prank(org);
    hats.mintHat(executorHat, maliciousActor);

    // Attempt to approveAndExecute as non-approver should revert
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.approveAndExecute(proposalId);
  }

  function test_RevertIf_NotExecutor() public {
    // Create a proposal with zero timelock
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _createTestProposal(1 ether, ETH, 0, recipientHat, 0, "", bytes32("not-executor"));

    // Mint approver ticket hat to maliciousActor (but NOT executor hat)
    vm.prank(approverAdmin);
    hats.mintHat(expectedProposal.approverHatId, maliciousActor);

    // Attempt to approveAndExecute as approver without executor hat should revert
    vm.expectRevert(IProposalHatterErrors.NotAuthorized.selector);
    vm.prank(maliciousActor);
    proposalHatter.approveAndExecute(proposalId);
  }

  function test_RevertIf_ApproveAndExecute_None() public {
    // Create a fake proposal ID that doesn't exist
    bytes32 nonExistentProposalId = bytes32(uint256(999_999));

    // Attempt to approveAndExecute a non-existent proposal
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.None)
    );
    vm.prank(approver);
    proposalHatter.approveAndExecute(nonExistentProposalId);
  }

  function test_RevertIf_ApproveAndExecute_Approved() public {
    // Create and approve a proposal
    (bytes32 proposalId,) = _createTestProposal(1 ether, ETH, 0, recipientHat, 0, "", bytes32("already-approved"));

    // Approve the proposal normally
    _approveProposal(proposalId);

    // Mint executor hat to approver
    vm.prank(org);
    hats.mintHat(executorHat, approver);

    // Attempt to approveAndExecute an already approved proposal should revert
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Approved)
    );
    vm.prank(approver);
    proposalHatter.approveAndExecute(proposalId);
  }

  function test_RevertIf_ApproveAndExecute_Executed() public {
    // Create, approve, and execute a proposal
    (bytes32 proposalId,) = _executeFullProposalLifecycle();

    // Mint executor hat to approver
    vm.prank(org);
    hats.mintHat(executorHat, approver);

    // Attempt to approveAndExecute an executed proposal should revert
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Executed)
    );
    vm.prank(approver);
    proposalHatter.approveAndExecute(proposalId);
  }

  function test_RevertIf_ApproveAndExecute_Canceled() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 ether, ETH, 0, recipientHat, 0, "", bytes32("canceled"));

    // Cancel the proposal (toggling off the approver hat)
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);

    // Attempt to approveAndExecute a canceled proposal should revert
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Canceled)
    );
    vm.prank(approver);
    proposalHatter.approveAndExecute(proposalId);
  }

  function test_RevertIf_ApproveAndExecute_Rejected() public {
    // Create a proposal
    (bytes32 proposalId,) = _createTestProposal(1 ether, ETH, 0, recipientHat, 0, "", bytes32("rejected"));

    // Reject the proposal
    _rejectProposal(proposalId);

    // Mint executor hat to approver
    vm.prank(org);
    hats.mintHat(executorHat, approver);

    // Attempt to approveAndExecute a rejected proposal should revert
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Rejected)
    );
    vm.prank(approver);
    proposalHatter.approveAndExecute(proposalId);
  }

  function test_RevertIf_ApproveAndExecute_ProposalsPaused() public {
    // Create a proposal with zero timelock
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expectedProposal) =
      _createTestProposal(1 ether, ETH, 0, recipientHat, 0, "", bytes32("paused"));

    // Mint approver ticket hat and executor hat to approver
    vm.prank(approverAdmin);
    hats.mintHat(expectedProposal.approverHatId, approver);
    vm.prank(org);
    hats.mintHat(executorHat, approver);

    // Owner pauses proposals
    vm.prank(org);
    proposalHatter.pauseProposals(true);

    // Attempt to approveAndExecute while paused should revert
    vm.expectRevert(IProposalHatterErrors.ProposalsArePaused.selector);
    vm.prank(approver);
    proposalHatter.approveAndExecute(proposalId);
  }

  function test_ApproveAndExecutePublic() public {
    // allow public execution
    vm.prank(org);
    proposalHatter.setExecutorHat(PUBLIC_SENTINEL);

    // create active proposal that will approve+execute atomically
    (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expectedProposal) = _createTestProposal(
      3 ether,
      ETH,
      0,
      recipientHat,
      0,
      _buildSingleHatCreationMulticall(opsBranchId, "Approve+Execute Public"),
      bytes32("approve-execute-public")
    );

    // mint approver ticket hat to authorised approver
    (,,,,,,,, uint256 approverHatId,,) = proposalHatter.proposals(proposalId);
    vm.prank(address(proposalHatter));
    hats.mintHat(approverHatId, approver);

    // expect approval + execution events in single call
    vm.prank(approver);
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.Approved(proposalId, approver, uint64(block.timestamp));
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.Executed(
      proposalId,
      expectedProposal.recipientHatId,
      expectedProposal.safe,
      expectedProposal.fundingToken,
      expectedProposal.fundingAmount,
      expectedProposal.fundingAmount
    );
    proposalHatter.approveAndExecute(proposalId);

    // verify proposal finalized and allowance recorded
    expectedProposal.state = IProposalHatterTypes.ProposalState.Executed;
    expectedProposal.eta = uint64(block.timestamp);
    expectedProposal.hatsMulticall = bytes("");
    _assertProposalData(_getProposalData(proposalId), expectedProposal);
    assertEq(
      uint256(proposalHatter.allowanceOf(expectedProposal.safe, recipientHat, expectedProposal.fundingToken)),
      uint256(expectedProposal.fundingAmount),
      "allowance recorded"
    );
  }
}
