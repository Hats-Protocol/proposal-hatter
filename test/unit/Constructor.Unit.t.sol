// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import { ProposalHatter } from "../../src/ProposalHatter.sol";
import { IProposalHatterEvents, IProposalHatterErrors } from "../../src/interfaces/IProposalHatter.sol";

/// @title Constructor Tests for ProposalHatter
/// @notice Tests for deployment and constructor validation
contract Constructor_Tests is ForkTestBase {
  // --------------------
  // Constructor Tests
  // --------------------

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
