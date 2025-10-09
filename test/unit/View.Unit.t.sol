// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";
import { ProposalHatter } from "../../src/ProposalHatter.sol";
import { IProposalHatterTypes } from "../../src/interfaces/IProposalHatter.sol";

/// @title View Tests for ProposalHatter
/// @notice Tests for view functions and getters
contract View_Tests is ForkTestBase {
  // --------------------
  // View Tests
  // --------------------

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
