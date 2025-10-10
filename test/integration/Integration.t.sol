// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import {
  IProposalHatterEvents, IProposalHatterTypes, IProposalHatterErrors
} from "../../src/interfaces/IProposalHatter.sol";
import { Strings } from "../../lib/openzeppelin-contracts/contracts/utils/Strings.sol";

/// @title Integration/E2E Tests for ProposalHatter
/// @notice Full lifecycle tests with real Hats and Safe interactions
contract Integration_Test is ForkTestBase {
  function test_executeEthHappyPath(address safe_) internal {
    uint88 fundingAmount = uint88(5 ether);
    uint32 timelock = 2 hours;
    uint256 expectedNewHatId = _getNextHatId(opsBranchId);
    string memory newHatDetails = "Integration: Ops Hat (ETH)";
    bytes32 proposalId;
    uint256 approverHatId;
    uint64 expectedEta;

    {
      bytes memory hatsMulticall = _buildSingleHatCreationMulticall(opsBranchId, newHatDetails);
      bytes32 salt = keccak256("integration-eth");
      IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
        proposer,
        fundingAmount,
        ETH,
        timelock,
        recipientHat,
        0,
        hatsMulticall,
        IProposalHatterTypes.ProposalState.Active
      );

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

      vm.expectEmit(true, true, true, true, address(proposalHatter));
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

      vm.prank(proposer);
      proposalId = proposalHatter.propose(
        expected.fundingAmount,
        expected.fundingToken,
        expected.timelockSec,
        expected.recipientHatId,
        expected.reservedHatId,
        expected.hatsMulticall,
        salt
      );

      assertEq(proposalId, expectedProposalId, "ETH proposal id mismatch");
      _assertProposalData(_getProposalData(proposalId), expected);
      _assertHatCreated(expected.approverHatId, approverBranchId, Strings.toHexString(uint256(proposalId), 32));
      approverHatId = expected.approverHatId;
    }

    vm.prank(approverAdmin);
    hats.mintHat(approverHatId, approver);
    assertTrue(hats.isWearerOfHat(approver, approverHatId), "Approver must wear hat pre-approval");

    expectedEta = uint64(block.timestamp) + uint64(timelock);
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.Approved(proposalId, approver, expectedEta);
    vm.prank(approver);
    proposalHatter.approve(proposalId);

    assertFalse(hats.isWearerOfHat(approver, approverHatId), "Approver hat toggled off after approval");
    _assertHatToggle(approverHatId, address(proposalHatter), false);

    {
      IProposalHatterTypes.ProposalData memory snapshot = _getProposalData(proposalId);
      assertEq(
        uint8(snapshot.state), uint8(IProposalHatterTypes.ProposalState.Approved), "ETH state should be Approved"
      );
      assertEq(snapshot.eta, expectedEta, "ETH eta mismatch");
    }

    _warpPastETA(proposalId);
    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, ETH)), 0, "ETH allowance should be zero before execution"
    );

    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.Executed(proposalId, recipientHat, safe_, ETH, fundingAmount, fundingAmount);
    vm.prank(executor);
    proposalHatter.execute(proposalId);

    {
      IProposalHatterTypes.ProposalData memory snapshot = _getProposalData(proposalId);
      assertEq(
        uint8(snapshot.state), uint8(IProposalHatterTypes.ProposalState.Executed), "ETH state should be Executed"
      );
      assertEq(snapshot.hatsMulticall.length, 0, "ETH hatsMulticall should be cleared");
    }

    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, ETH)),
      uint256(fundingAmount),
      "ETH allowance should equal funding amount"
    );
    _assertHatCreated(expectedNewHatId, opsBranchId, newHatDetails);

    uint256 recipientBalanceBefore = _getBalance(ETH, recipient);
    uint256 safeBalanceBefore = _getBalance(ETH, safe_);

    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(recipientHat, safe_, ETH, fundingAmount, 0, recipient);
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, safe_, ETH, fundingAmount);

    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, ETH)), 0, "ETH allowance should be zero after withdrawal"
    );
    assertEq(
      _getBalance(ETH, recipient) - recipientBalanceBefore,
      uint256(fundingAmount),
      "Recipient should receive ETH funding"
    );
    assertEq(
      safeBalanceBefore - _getBalance(ETH, safe_),
      uint256(fundingAmount),
      "Safe balance should decrease by withdrawn ETH"
    );
  }

  function test_executeUsdcHappyPath(address safe_) internal {
    uint88 fundingAmount = 25_000 * 1e6;
    uint32 timelock = 4 hours;
    bytes32 proposalId;
    uint256 approverHatId;
    uint64 expectedEta;

    {
      bytes32 salt = keccak256("integration-usdc");
      IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
        proposer, fundingAmount, USDC, timelock, recipientHat, 0, bytes(""), IProposalHatterTypes.ProposalState.Active
      );

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

      vm.expectEmit(true, true, true, true, address(proposalHatter));
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

      vm.prank(proposer);
      proposalId = proposalHatter.propose(
        expected.fundingAmount,
        expected.fundingToken,
        expected.timelockSec,
        expected.recipientHatId,
        expected.reservedHatId,
        expected.hatsMulticall,
        salt
      );

      assertEq(proposalId, expectedProposalId, "USDC proposal id mismatch");
      _assertProposalData(_getProposalData(proposalId), expected);
      _assertHatCreated(expected.approverHatId, approverBranchId, Strings.toHexString(uint256(proposalId), 32));
      approverHatId = expected.approverHatId;
    }

    vm.prank(approverAdmin);
    hats.mintHat(approverHatId, approver);
    assertTrue(hats.isWearerOfHat(approver, approverHatId), "Approver must wear USDC hat pre-approval");

    expectedEta = uint64(block.timestamp) + uint64(timelock);
    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.Approved(proposalId, approver, expectedEta);
    vm.prank(approver);
    proposalHatter.approve(proposalId);

    assertFalse(hats.isWearerOfHat(approver, approverHatId), "USDC hat toggled off after approval");
    _assertHatToggle(approverHatId, address(proposalHatter), false);

    {
      IProposalHatterTypes.ProposalData memory snapshot = _getProposalData(proposalId);
      assertEq(
        uint8(snapshot.state), uint8(IProposalHatterTypes.ProposalState.Approved), "USDC state should be Approved"
      );
      assertEq(snapshot.eta, expectedEta, "USDC eta mismatch");
    }

    _warpPastETA(proposalId);
    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, USDC)),
      0,
      "USDC allowance should be zero before execution"
    );

    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.Executed(proposalId, recipientHat, safe_, USDC, fundingAmount, fundingAmount);
    vm.prank(executor);
    proposalHatter.execute(proposalId);

    {
      IProposalHatterTypes.ProposalData memory snapshot = _getProposalData(proposalId);
      assertEq(
        uint8(snapshot.state), uint8(IProposalHatterTypes.ProposalState.Executed), "USDC state should be Executed"
      );
    }

    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, USDC)),
      uint256(fundingAmount),
      "USDC allowance should equal funding amount"
    );

    uint256 recipientBalanceBefore = _getBalance(USDC, recipient);
    uint256 safeBalanceBefore = _getBalance(USDC, safe_);

    vm.expectEmit(true, true, true, true, address(proposalHatter));
    emit IProposalHatterEvents.AllowanceConsumed(recipientHat, safe_, USDC, fundingAmount, 0, recipient);
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, safe_, USDC, fundingAmount);

    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, USDC)),
      0,
      "USDC allowance should be zero after withdrawal"
    );
    assertEq(
      _getBalance(USDC, recipient) - recipientBalanceBefore,
      uint256(fundingAmount),
      "Recipient should receive USDC funding"
    );
    assertEq(
      safeBalanceBefore - _getBalance(USDC, safe_),
      uint256(fundingAmount),
      "Safe balance should decrease by withdrawn USDC"
    );
  }

  function testEndToEnd_ReservedHat() public {
    // Arrange: Create proposal with reserved hat, then test reject/cancel toggle behavior
    uint256 reservedHatId = _getNextHatId(opsBranchId);
    bytes32 proposalId;

    // Create proposal with reserved hat
    vm.prank(proposer);
    proposalId = proposalHatter.propose(
      uint88(3 ether), ETH, 1 hours, recipientHat, reservedHatId, bytes(""), keccak256("reserved-hat-test")
    );

    // Verify reserved hat was created and is active
    {
      (,,,,,,,, bool active) = hats.viewHat(reservedHatId);
      assertTrue(active, "Reserved hat should be active after creation");
    }

    // Test scenario: reject toggles off reserved hat (can only reject Active proposals)
    uint256 approverHatId = _getProposalData(proposalId).approverHatId;
    vm.prank(approverAdmin);
    hats.mintHat(approverHatId, approver);

    vm.prank(approver);
    proposalHatter.reject(proposalId);

    // Verify reserved hat was toggled off after rejection
    _assertHatToggle(reservedHatId, address(proposalHatter), false);

    // Create another proposal to test cancel
    uint256 reservedHatId2 = _getNextHatId(opsBranchId);
    bytes32 proposalId2;

    vm.prank(proposer);
    proposalId2 = proposalHatter.propose(
      uint88(2 ether), ETH, 30 minutes, recipientHat, reservedHatId2, bytes(""), keccak256("reserved-hat-cancel")
    );

    // Verify second reserved hat is active
    {
      (,,,,,,,, bool active) = hats.viewHat(reservedHatId2);
      assertTrue(active, "Second reserved hat should be active after creation");
    }

    // Test scenario: cancel toggles off reserved hat
    vm.prank(proposer);
    proposalHatter.cancel(proposalId2);

    // Verify reserved hat was toggled off after cancellation
    _assertHatToggle(reservedHatId2, address(proposalHatter), false);

    // Create third proposal to test execute doesn't toggle off
    uint256 reservedHatId3 = _getNextHatId(opsBranchId);
    bytes32 proposalId3;

    vm.prank(proposer);
    proposalId3 = proposalHatter.propose(
      uint88(1 ether), ETH, 10 minutes, recipientHat, reservedHatId3, bytes(""), keccak256("reserved-hat-execute")
    );

    _approveProposal(proposalId3);
    _warpPastETA(proposalId3);
    _executeProposal(proposalId3);

    // Verify reserved hat remains active after execution
    _assertHatToggle(reservedHatId3, address(1), true);
  }

  function testEndToEnd_FundingOnly() public {
    // Arrange: Create proposal with empty multicall (funding only)
    address safe_ = proposalHatter.safe();
    bytes32 proposalId;

    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, uint88(10 ether), ETH, 2 hours, recipientHat, 0, bytes(""), IProposalHatterTypes.ProposalState.Active
    );

    vm.prank(proposer);
    proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      keccak256("funding-only")
    );

    // Execute full lifecycle
    _approveProposal(proposalId);
    expected.eta = uint64(block.timestamp) + uint64(expected.timelockSec);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    // Verify allowance was created
    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, ETH)),
      uint256(10 ether),
      "Allowance should be created for funding-only proposal"
    );

    // Verify proposal state
    IProposalHatterTypes.ProposalData memory proposal = _getProposalData(proposalId);
    expected.state = IProposalHatterTypes.ProposalState.Executed;
    _assertProposalData(proposal, expected);
    assertEq(proposal.hatsMulticall.length, 0, "HatsMulticall should be empty");
  }

  function testEndToEnd_ApproveAndExecute() public {
    // Arrange: Create proposal with zero timelock for atomic approve+execute
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, uint88(5 ether), ETH, 0, recipientHat, 0, bytes(""), IProposalHatterTypes.ProposalState.Active
    );

    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      keccak256("approve-and-execute")
    );

    // Mint approver hat to executor (executor must wear both approver and executor hats)
    uint256 approverHatId = _getProposalData(proposalId).approverHatId;
    vm.prank(approverAdmin);
    hats.mintHat(approverHatId, executor);

    // Execute approveAndExecute atomically (executor wears both hats)
    vm.prank(executor);
    proposalHatter.approveAndExecute(proposalId);
    expected.eta = uint64(block.timestamp) + uint64(expected.timelockSec);
    expected.state = IProposalHatterTypes.ProposalState.Executed;
    expected.hatsMulticall = bytes("");

    // Verify proposal state is executed
    _assertProposalData(_getProposalData(proposalId), expected);

    // Verify allowance was created
    assertEq(
      uint256(proposalHatter.allowanceOf(proposalHatter.safe(), recipientHat, ETH)),
      uint256(5 ether),
      "Allowance should be created via approveAndExecute"
    );
  }

  function testEndToEnd_PublicExecution() public {
    // Arrange: Set executorHat to PUBLIC_SENTINEL (1) for public execution
    vm.prank(org);
    proposalHatter.setExecutorHat(1); // PUBLIC_SENTINEL

    bytes32 proposalId;

    vm.prank(proposer);
    proposalId =
      proposalHatter.propose(uint88(3 ether), ETH, 30 minutes, recipientHat, 0, bytes(""), keccak256("public-exec"));

    _approveProposal(proposalId);
    _warpPastETA(proposalId);

    // Execute as malicious actor (anyone can execute when PUBLIC_SENTINEL)
    vm.prank(maliciousActor);
    proposalHatter.execute(proposalId);

    // Verify execution succeeded
    IProposalHatterTypes.ProposalData memory proposal = _getProposalData(proposalId);
    assertEq(
      uint8(proposal.state), uint8(IProposalHatterTypes.ProposalState.Executed), "Proposal should be executed publicly"
    );
  }

  function testRevertOnEscalate() public {
    // Arrange: Create and escalate proposal, verify execute is blocked
    bytes32 proposalId;

    vm.prank(proposer);
    proposalId =
      proposalHatter.propose(uint88(2 ether), ETH, 1 hours, recipientHat, 0, bytes(""), keccak256("escalate-test"));

    _approveProposal(proposalId);
    _warpPastETA(proposalId);

    // Escalate the proposal
    vm.prank(escalator);
    proposalHatter.escalate(proposalId);

    // Verify proposal state is Escalated
    IProposalHatterTypes.ProposalData memory proposal = _getProposalData(proposalId);
    assertEq(uint8(proposal.state), uint8(IProposalHatterTypes.ProposalState.Escalated), "Proposal should be escalated");

    // Attempt to execute should revert
    vm.prank(executor);
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Escalated)
    );
    proposalHatter.execute(proposalId);
  }

  function testRevertOnReject() public {
    // Arrange: Create and reject proposal (must reject Active proposals), verify execute is blocked
    bytes32 proposalId;

    vm.prank(proposer);
    proposalId =
      proposalHatter.propose(uint88(2 ether), ETH, 1 hours, recipientHat, 0, bytes(""), keccak256("reject-test"));

    // Mint approver hat and reject the proposal (can only reject Active proposals)
    uint256 approverHatId = _getProposalData(proposalId).approverHatId;
    vm.prank(approverAdmin);
    hats.mintHat(approverHatId, approver);

    vm.prank(approver);
    proposalHatter.reject(proposalId);

    // Verify proposal state is Rejected
    IProposalHatterTypes.ProposalData memory proposal = _getProposalData(proposalId);
    assertEq(uint8(proposal.state), uint8(IProposalHatterTypes.ProposalState.Rejected), "Proposal should be rejected");

    // Attempt to execute should revert
    _warpPastETA(proposalId);
    vm.prank(executor);
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Rejected)
    );
    proposalHatter.execute(proposalId);
  }

  function testRevertOnCancel() public {
    // Arrange: Create and cancel proposal, verify execute is blocked
    bytes32 proposalId;

    vm.prank(proposer);
    proposalId =
      proposalHatter.propose(uint88(2 ether), ETH, 1 hours, recipientHat, 0, bytes(""), keccak256("cancel-test"));

    _approveProposal(proposalId);

    // Cancel the proposal
    vm.prank(proposer);
    proposalHatter.cancel(proposalId);

    // Verify proposal state is Canceled
    IProposalHatterTypes.ProposalData memory proposal = _getProposalData(proposalId);
    assertEq(uint8(proposal.state), uint8(IProposalHatterTypes.ProposalState.Canceled), "Proposal should be canceled");

    // Attempt to execute should revert
    _warpPastETA(proposalId);
    vm.prank(executor);
    vm.expectRevert(
      abi.encodeWithSelector(IProposalHatterErrors.InvalidState.selector, IProposalHatterTypes.ProposalState.Canceled)
    );
    proposalHatter.execute(proposalId);
  }

  function testSafeMigration() public {
    // Arrange: Create proposal, then migrate safe, verify old allowances persist
    address oldSafe = proposalHatter.safe();
    bytes32 proposalId;

    vm.prank(proposer);
    proposalId =
      proposalHatter.propose(uint88(5 ether), ETH, 30 minutes, recipientHat, 0, bytes(""), keccak256("safe-migration"));

    _approveProposal(proposalId);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    // Verify allowance on old safe
    assertEq(
      uint256(proposalHatter.allowanceOf(oldSafe, recipientHat, ETH)),
      uint256(5 ether),
      "Allowance should exist on old safe"
    );

    // Migrate to new safe (use secondarySafe which is already set up)
    address newSafe = secondarySafe;

    vm.prank(org);
    proposalHatter.setSafe(newSafe);

    // Verify global safe changed
    assertEq(proposalHatter.safe(), newSafe, "Global safe should be updated");

    // Verify old allowance persists on old safe
    assertEq(
      uint256(proposalHatter.allowanceOf(oldSafe, recipientHat, ETH)),
      uint256(5 ether),
      "Old allowance should persist after safe migration"
    );

    // Verify new safe has no allowance
    assertEq(uint256(proposalHatter.allowanceOf(newSafe, recipientHat, ETH)), 0, "New safe should have zero allowance");

    // Create new proposal on new safe
    vm.prank(proposer);
    bytes32 proposalId2 = proposalHatter.propose(
      uint88(3 ether), ETH, 30 minutes, recipientHat, 0, bytes(""), keccak256("new-safe-proposal")
    );

    _approveProposal(proposalId2);
    _warpPastETA(proposalId2);
    _executeProposal(proposalId2);

    // Verify new allowance on new safe
    assertEq(
      uint256(proposalHatter.allowanceOf(newSafe, recipientHat, ETH)),
      uint256(3 ether),
      "New allowance should be on new safe"
    );

    // Verify old allowance still persists
    assertEq(
      uint256(proposalHatter.allowanceOf(oldSafe, recipientHat, ETH)),
      uint256(5 ether),
      "Old allowance should still persist"
    );
  }

  function testTokenVariants_USDT() public {
    // Arrange: Test USDT withdrawal (no return value)
    address safe_ = proposalHatter.safe();
    bytes32 proposalId;

    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer,
      uint88(10_000 * 1e6),
      USDT,
      30 minutes,
      recipientHat,
      0,
      bytes(""),
      IProposalHatterTypes.ProposalState.Active
    );

    vm.prank(proposer);
    proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      keccak256("usdt-test")
    );

    _approveProposal(proposalId);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    // Verify allowance
    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, USDT)),
      uint256(10_000 * 1e6),
      "USDT allowance should be created"
    );

    // Withdraw USDT (no return value from transfer)
    uint256 recipientBalanceBefore = _getBalance(USDT, recipient);
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, safe_, USDT, uint88(10_000 * 1e6));

    // Verify withdrawal succeeded despite no return value
    assertEq(
      _getBalance(USDT, recipient) - recipientBalanceBefore, uint256(10_000 * 1e6), "Recipient should receive USDT"
    );
    assertEq(uint256(proposalHatter.allowanceOf(safe_, recipientHat, USDT)), 0, "USDT allowance should be zero");
  }

  function testTokenVariants_DAI() public {
    // Arrange: Test DAI withdrawal (18 decimals)
    address safe_ = proposalHatter.safe();
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer,
      uint88(5000 ether),
      DAI,
      30 minutes,
      recipientHat,
      0,
      bytes(""),
      IProposalHatterTypes.ProposalState.Active
    );

    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      keccak256("dai-test")
    );

    _approveProposal(proposalId);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    // Verify allowance
    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, DAI)),
      uint256(5000 ether),
      "DAI allowance should be created"
    );

    // Withdraw DAI
    uint256 recipientBalanceBefore = _getBalance(DAI, recipient);
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, safe_, DAI, uint88(5000 ether));

    // Verify withdrawal succeeded
    assertEq(_getBalance(DAI, recipient) - recipientBalanceBefore, uint256(5000 ether), "Recipient should receive DAI");
    assertEq(uint256(proposalHatter.allowanceOf(safe_, recipientHat, DAI)), 0, "DAI allowance should be zero");
  }

  function testReentrancy() public {
    // Note: Full reentrancy testing requires malicious contracts which are complex to implement
    // This test verifies the ReentrancyGuard is in place by checking state transitions
    // More comprehensive reentrancy tests should be in test/attacks/Reentrancy.t.sol

    address safe_ = proposalHatter.safe();
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer, uint88(1 ether), ETH, 30 minutes, recipientHat, 0, bytes(""), IProposalHatterTypes.ProposalState.Active
    );

    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      expected.fundingAmount,
      expected.fundingToken,
      expected.timelockSec,
      expected.recipientHatId,
      expected.reservedHatId,
      expected.hatsMulticall,
      keccak256("reentrancy-test")
    );

    _approveProposal(proposalId);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    // Verify execution completed successfully with reentrancy guard active
    IProposalHatterTypes.ProposalData memory proposal = _getProposalData(proposalId);
    assertEq(
      uint8(proposal.state), uint8(IProposalHatterTypes.ProposalState.Executed), "Execution should complete normally"
    );

    // Verify withdrawal completes successfully with reentrancy guard active
    vm.prank(recipient);
    proposalHatter.withdraw(recipientHat, safe_, ETH, uint88(1 ether));

    assertEq(uint256(proposalHatter.allowanceOf(safe_, recipientHat, ETH)), 0, "Withdrawal should complete normally");
  }

  function testMulticall_CreateMultipleHats() public {
    // Arrange: Build a multicall that creates 3 sibling hats under opsBranchId
    address safe_ = proposalHatter.safe();
    string memory hatDetails = "Integration: Multi-Hat Creation";
    bytes memory hatsMulticall = _buildThreeSiblingHatCreationMulticall(opsBranchId, hatDetails);

    // Capture expected hat IDs before proposal creation
    // The first hat will use getNextId, then subsequent hats increment the lastHatId
    (,,,,,, uint16 lastHatId,,) = hats.viewHat(opsBranchId);
    uint256 expectedHatId1 = _getNextHatId(opsBranchId); // buildHatId(opsBranchId, lastHatId + 1)
    uint256 expectedHatId2 = hats.buildHatId(opsBranchId, lastHatId + 2);
    uint256 expectedHatId3 = hats.buildHatId(opsBranchId, lastHatId + 3);

    // Build expected proposal data
    IProposalHatterTypes.ProposalData memory expected = _buildExpectedProposal(
      proposer,
      uint88(10 ether),
      ETH,
      1 hours,
      recipientHat,
      0,
      hatsMulticall,
      IProposalHatterTypes.ProposalState.Active
    );

    // Act: Create proposal
    vm.prank(proposer);
    bytes32 proposalId = proposalHatter.propose(
      uint88(10 ether), ETH, 1 hours, recipientHat, 0, hatsMulticall, keccak256("multicall-create-multiple-hats")
    );

    // Assert: Verify proposal created correctly
    _assertProposalData(_getProposalData(proposalId), expected);

    // Approve proposal
    _approveProposal(proposalId);

    // Warp past timelock and execute
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    // Assert: Verify all three hats were created during execution
    _assertHatCreated(expectedHatId1, opsBranchId, hatDetails);
    _assertHatCreated(expectedHatId2, opsBranchId, hatDetails);
    _assertHatCreated(expectedHatId3, opsBranchId, hatDetails);

    // Assert: Verify proposal state is Executed
    IProposalHatterTypes.ProposalData memory executedProposal = _getProposalData(proposalId);
    assertEq(
      uint8(executedProposal.state),
      uint8(IProposalHatterTypes.ProposalState.Executed),
      "Proposal state should be Executed"
    );

    // Assert: Verify hatsMulticall was deleted after execution
    assertEq(executedProposal.hatsMulticall.length, 0, "HatsMulticall should be deleted after execution");

    // Assert: Verify allowance was created correctly
    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, recipientHat, ETH)),
      uint256(10 ether),
      "Allowance should equal funding amount"
    );
  }

  function testMulticall_CreateAndChangeHats() public {
    // Arrange: Pre-create a hat under opsBranchId that we'll modify in the multicall
    address safe_ = proposalHatter.safe();
    uint256 parentHatId;
    uint256 expectedChildHatId;
    bytes32 proposalId;

    {
      string memory originalDetails = "Original Hat Details";

      // Create the parent hat that we'll modify
      vm.prank(org);
      parentHatId = hats.createHat(opsBranchId, originalDetails, 5, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

      // Verify parent hat was created with original details
      (string memory details,,,,,, uint16 lastHatId,,) = hats.viewHat(parentHatId);
      assertEq(details, originalDetails, "Parent hat should have original details");
      assertEq(lastHatId, 0, "Parent hat should have no children yet");
    }

    {
      string memory updatedDetails = "Updated Hat Details";
      string memory childDetails = "Child of Updated Hat";

      // Build a multicall that changes the parent hat and creates a child under it
      bytes[] memory calls = new bytes[](3);
      calls[0] = abi.encodeCall(hats.changeHatDetails, (parentHatId, updatedDetails));
      calls[1] = abi.encodeCall(hats.changeHatMaxSupply, (parentHatId, 10));
      calls[2] =
        abi.encodeCall(hats.createHat, (parentHatId, childDetails, 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, ""));
      bytes memory hatsMulticall = _buildValidMulticall(calls);

      expectedChildHatId = hats.buildHatId(parentHatId, 1);

      // Create proposal
      vm.prank(proposer);
      proposalId = proposalHatter.propose(
        uint88(5 ether), ETH, 30 minutes, recipientHat, 0, hatsMulticall, keccak256("multicall-create-and-change")
      );
    }

    // Approve and execute proposal
    _approveProposal(proposalId);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    // Assert: Verify parent hat was modified
    {
      (string memory newDetails, uint32 newMaxSupply,,,,, uint16 newLastHatId,,) = hats.viewHat(parentHatId);
      assertEq(newDetails, "Updated Hat Details", "Parent hat details should be updated");
      assertEq(newMaxSupply, 10, "Parent hat max supply should be updated to 10");
      assertEq(newLastHatId, 1, "Parent hat should now have 1 child");
    }

    // Assert: Verify child hat was created
    _assertHatCreated(expectedChildHatId, parentHatId, "Child of Updated Hat");

    // Assert: Verify proposal state and allowance
    {
      IProposalHatterTypes.ProposalData memory executedProposal = _getProposalData(proposalId);
      assertEq(
        uint8(executedProposal.state),
        uint8(IProposalHatterTypes.ProposalState.Executed),
        "Proposal state should be Executed"
      );
      assertEq(executedProposal.hatsMulticall.length, 0, "HatsMulticall should be deleted after execution");
      assertEq(
        uint256(proposalHatter.allowanceOf(safe_, recipientHat, ETH)),
        uint256(5 ether),
        "Allowance should equal funding amount"
      );
    }
  }

  function testMulticall_CreateRecipientHat() public {
    // Arrange: Build a multicall that creates the recipient hat itself
    address safe_ = proposalHatter.safe();
    string memory newRecipientDetails = "Newly Created Recipient Hat";
    uint256 expectedRecipientHatId;
    bytes32 proposalId;

    {
      // Build a multicall that creates a new hat under opsBranchId
      bytes[] memory calls = new bytes[](1);
      calls[0] =
        abi.encodeCall(hats.createHat, (opsBranchId, newRecipientDetails, 5, EMPTY_SENTINEL, EMPTY_SENTINEL, true, ""));
      bytes memory hatsMulticall = _buildValidMulticall(calls);

      // Calculate the expected recipient hat ID (which doesn't exist yet)
      expectedRecipientHatId = _getNextHatId(opsBranchId);

      // Create proposal using the not-yet-created hat as recipient
      vm.prank(proposer);
      proposalId = proposalHatter.propose(
        uint88(7 ether),
        ETH,
        45 minutes,
        expectedRecipientHatId,
        0,
        hatsMulticall,
        keccak256("multicall-create-recipient-hat")
      );
    }

    // Approve and execute proposal
    _approveProposal(proposalId);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    // Assert: Verify recipient hat was created during execution
    _assertHatCreated(
      expectedRecipientHatId, opsBranchId, newRecipientDetails, 5, EMPTY_SENTINEL, EMPTY_SENTINEL, true, true
    );

    // Assert: Verify allowance was created for the newly created recipient hat
    assertEq(
      uint256(proposalHatter.allowanceOf(safe_, expectedRecipientHatId, ETH)),
      uint256(7 ether),
      "Allowance should be created for newly created recipient hat"
    );

    // Assert: Verify proposal state
    {
      IProposalHatterTypes.ProposalData memory executedProposal = _getProposalData(proposalId);
      assertEq(
        uint8(executedProposal.state),
        uint8(IProposalHatterTypes.ProposalState.Executed),
        "Proposal state should be Executed"
      );
      assertEq(executedProposal.hatsMulticall.length, 0, "HatsMulticall should be deleted after execution");
    }
  }

  function testMulticall_CreateDeepChildHats() public {
    // Arrange: Build a multicall that creates multiple levels of child hats (3 levels deep)
    uint256 level1HatId;
    uint256 level2HatId;
    uint256 level3HatId;
    bytes32 proposalId;

    {
      string memory level1Details = "Level 1 Child";
      string memory level2Details = "Level 2 Grandchild";
      string memory level3Details = "Level 3 Great-grandchild";

      // Calculate expected hat IDs for the three levels
      (,,,,,, uint16 lastHatId,,) = hats.viewHat(opsBranchId);
      level1HatId = hats.buildHatId(opsBranchId, lastHatId + 1);
      level2HatId = hats.buildHatId(level1HatId, 1);
      level3HatId = hats.buildHatId(level2HatId, 1);

      // Build a multicall that creates three levels of hats
      bytes[] memory calls = new bytes[](3);
      calls[0] =
        abi.encodeCall(hats.createHat, (opsBranchId, level1Details, 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, ""));
      calls[1] =
        abi.encodeCall(hats.createHat, (level1HatId, level2Details, 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, ""));
      calls[2] =
        abi.encodeCall(hats.createHat, (level2HatId, level3Details, 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, ""));
      bytes memory hatsMulticall = _buildValidMulticall(calls);

      // Create proposal
      vm.prank(proposer);
      proposalId = proposalHatter.propose(
        uint88(3 ether), ETH, 20 minutes, recipientHat, 0, hatsMulticall, keccak256("multicall-deep-children")
      );
    }

    // Approve and execute proposal
    _approveProposal(proposalId);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    // Assert: Verify all three levels were created
    _assertHatCreated(level1HatId, opsBranchId, "Level 1 Child");
    _assertHatCreated(level2HatId, level1HatId, "Level 2 Grandchild");
    _assertHatCreated(level3HatId, level2HatId, "Level 3 Great-grandchild");

    // Assert: Verify the parent-child relationships
    {
      (,,,,,, uint16 level1Children,,) = hats.viewHat(level1HatId);
      (,,,,,, uint16 level2Children,,) = hats.viewHat(level2HatId);
      assertEq(level1Children, 1, "Level 1 hat should have 1 child");
      assertEq(level2Children, 1, "Level 2 hat should have 1 child");
    }

    // Assert: Verify proposal state
    {
      IProposalHatterTypes.ProposalData memory executedProposal = _getProposalData(proposalId);
      assertEq(
        uint8(executedProposal.state),
        uint8(IProposalHatterTypes.ProposalState.Executed),
        "Proposal state should be Executed"
      );
      assertEq(executedProposal.hatsMulticall.length, 0, "HatsMulticall should be deleted after execution");
    }
  }

  function testMulticall_ChangeReservedHat() public {
    // Arrange: Create a proposal with a reserved hat, then modify the reserved hat in the multicall
    uint256 reservedHatId;
    bytes32 proposalId;

    {
      string memory updatedDetails = "Updated Reserved Hat";

      // Calculate the reserved hat ID (will be created during propose)
      reservedHatId = _getNextHatId(opsBranchId);

      // Build a multicall that changes the reserved hat's details and max supply
      bytes[] memory calls = new bytes[](2);
      calls[0] = abi.encodeCall(hats.changeHatDetails, (reservedHatId, updatedDetails));
      calls[1] = abi.encodeCall(hats.changeHatMaxSupply, (reservedHatId, 100));
      bytes memory hatsMulticall = _buildValidMulticall(calls);

      // Create proposal with reserved hat
      vm.prank(proposer);
      proposalId = proposalHatter.propose(
        uint88(2 ether),
        ETH,
        15 minutes,
        recipientHat,
        reservedHatId,
        hatsMulticall,
        keccak256("multicall-change-reserved-hat")
      );

      // Verify reserved hat was created (details are hex string of proposal ID)
      {
        (string memory details, uint32 maxSupply, uint32 supply,,,,,,) = hats.viewHat(reservedHatId);
        assertEq(details, Strings.toHexString(uint256(proposalId), 32), "Reserved hat details should be proposal ID");
        assertEq(maxSupply, 1, "Reserved hat max supply should be 1 initially");
        assertEq(supply, 0, "Reserved hat should have 0 supply");
      }
    }

    // Approve and execute proposal
    _approveProposal(proposalId);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    // Assert: Verify reserved hat was modified during execution
    {
      (string memory newDetails, uint32 newMaxSupply,,,,,,,) = hats.viewHat(reservedHatId);
      assertEq(newDetails, "Updated Reserved Hat", "Reserved hat details should be updated");
      assertEq(newMaxSupply, 100, "Reserved hat max supply should be updated to 100");
    }

    // Assert: Verify reserved hat is still active (not toggled off since proposal executed)
    {
      (,,,,,,,, bool active) = hats.viewHat(reservedHatId);
      assertTrue(active, "Reserved hat should still be active after execution");
    }

    // Assert: Verify proposal state
    {
      IProposalHatterTypes.ProposalData memory executedProposal = _getProposalData(proposalId);
      assertEq(
        uint8(executedProposal.state),
        uint8(IProposalHatterTypes.ProposalState.Executed),
        "Proposal state should be Executed"
      );
    }
  }

  function testMulticall_CreateReservedHatChild() public {
    // Arrange: Create a proposal with a reserved hat, then create a child hat under it in the multicall
    uint256 reservedHatId;
    uint256 childHatId;
    bytes32 proposalId;

    {
      string memory childDetails = "Child of Reserved Hat";

      // Calculate the reserved hat ID and its expected child
      reservedHatId = _getNextHatId(opsBranchId);
      childHatId = hats.buildHatId(reservedHatId, 1);

      // Build a multicall that creates a child under the reserved hat
      bytes[] memory calls = new bytes[](1);
      calls[0] =
        abi.encodeCall(hats.createHat, (reservedHatId, childDetails, 3, EMPTY_SENTINEL, EMPTY_SENTINEL, true, ""));
      bytes memory hatsMulticall = _buildValidMulticall(calls);

      // Create proposal with reserved hat
      vm.prank(proposer);
      proposalId = proposalHatter.propose(
        uint88(4 ether),
        ETH,
        25 minutes,
        recipientHat,
        reservedHatId,
        hatsMulticall,
        keccak256("multicall-create-reserved-child")
      );

      // Verify reserved hat was created (details are hex string of proposal ID)
      {
        (string memory details,, uint32 supply,,,,,,) = hats.viewHat(reservedHatId);
        assertEq(details, Strings.toHexString(uint256(proposalId), 32), "Reserved hat details should be proposal ID");
        assertEq(supply, 0, "Reserved hat should have 0 supply");
      }
    }

    // Approve and execute proposal
    _approveProposal(proposalId);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);

    // Assert: Verify child hat was created under reserved hat
    _assertHatCreated(childHatId, reservedHatId, "Child of Reserved Hat", 3, EMPTY_SENTINEL, EMPTY_SENTINEL, true, true);

    // Assert: Verify reserved hat now has a child
    {
      (,,,,,, uint16 lastHatId,,) = hats.viewHat(reservedHatId);
      assertEq(lastHatId, 1, "Reserved hat should have 1 child");
    }

    // Assert: Verify proposal state
    {
      IProposalHatterTypes.ProposalData memory executedProposal = _getProposalData(proposalId);
      assertEq(
        uint8(executedProposal.state),
        uint8(IProposalHatterTypes.ProposalState.Executed),
        "Proposal state should be Executed"
      );
      assertEq(executedProposal.hatsMulticall.length, 0, "HatsMulticall should be deleted after execution");
    }
  }
}
