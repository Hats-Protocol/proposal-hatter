// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ProposalHatter } from "../../../src/ProposalHatter.sol";
import { IProposalHatterTypes } from "../../../src/interfaces/IProposalHatter.sol";
import { IHats } from "../../../lib/hats-protocol/src/Interfaces/IHats.sol";
import { TestHelpers } from "../../helpers/TestHelpers.sol";

/// @title ProposalHatterHandler
/// @notice Handler contract for invariant testing with comprehensive ghost variable tracking
/// @dev Lightweight handler using Test and TestHelpers library
contract ProposalHatterHandler is Test {
  // --------------------
  // Constants
  // --------------------

  address internal constant ETH = address(0);
  uint256 internal constant PUBLIC_SENTINEL = 1;

  // --------------------
  // State passed from test contract
  // --------------------

  ProposalHatter public proposalHatter;
  IHats public hats;
  address public approverAdmin;
  address public proposer;
  address public executor;
  uint256 public recipientHat;
  address[20] public testActors;
  address[4] public fundingTokens;
  address public primarySafe;
  address public secondarySafe;
  address public underfundedSafe;

  // --------------------
  // Ghost Variables for Invariant Tracking
  // --------------------

  /// @dev Track initial proposal data at creation (for immutability checks)
  mapping(bytes32 proposalId => IProposalHatterTypes.ProposalData) public ghost_proposalInitialData;

  /// @dev Track all executed proposals per (safe, hat, token) tuple
  mapping(address safe => mapping(uint256 hat => mapping(address token => ExecutedProposal[]))) public
    ghost_executedProposals;

  /// @dev Track all withdrawals per (safe, hat, token) tuple
  mapping(address safe => mapping(uint256 hat => mapping(address token => Withdrawal[]))) public ghost_withdrawals;

  /// @dev Track total executed funding amounts per (safe, hat, token) tuple
  mapping(address safe => mapping(uint256 hat => mapping(address token => uint256))) public ghost_totalExecutedFunding;

  /// @dev Track total withdrawn amounts per (safe, hat, token) tuple
  mapping(address safe => mapping(uint256 hat => mapping(address token => uint256))) public ghost_totalWithdrawn;

  /// @dev Track Safe balances at various points for custody verification
  mapping(address safe => mapping(address token => uint256)) public ghost_safeInitialBalance;

  /// @dev Track proposals that reached terminal states (for immutability checks)
  mapping(bytes32 proposalId => IProposalHatterTypes.ProposalState) public ghost_terminalStates;

  /// @dev Track ETA setting events (should only be set once per proposal)
  mapping(bytes32 proposalId => ETAChangeEvent) public ghost_etaChanges;

  /// @dev Track all created approver hats (for uniqueness checks)
  uint256[] public ghost_approverHats;
  mapping(uint256 approverHatId => bool) public ghost_approverHatExists;

  /// @dev Track all created proposal IDs (for uniqueness checks)
  bytes32[] public ghost_allProposalIds;
  mapping(bytes32 proposalId => bool) public ghost_proposalExists;

  /// @dev Track allowance changes for monotonicity verification
  mapping(address safe => mapping(uint256 hat => mapping(address token => AllowanceChange[]))) public
    ghost_allowanceChanges;

  /// @dev Track multicall storage deletions (for consistency checks)
  mapping(bytes32 proposalId => bool) public ghost_multicallDeleted;

  /// @dev Track reserved hat toggle events
  mapping(uint256 reservedHatId => ReservedHatToggle[]) public ghost_reservedHatToggles;

  // --------------------
  // Structs for Ghost Variables
  // --------------------

  struct ExecutedProposal {
    bytes32 proposalId;
    uint88 fundingAmount;
    uint256 timestamp;
  }

  struct Withdrawal {
    address caller;
    uint88 amount;
    uint256 timestamp;
  }

  struct ETAChangeEvent {
    uint64 eta;
    uint256 timestamp;
    bool wasSet;
  }

  struct AllowanceChange {
    uint88 oldAllowance;
    uint88 newAllowance;
    uint256 timestamp;
    ActionType actionType;
  }

  struct ReservedHatToggle {
    bytes32 proposalId;
    bool toggledOff;
    uint256 timestamp;
  }

  enum ActionType {
    Execute,
    Withdraw
  }

  // --------------------
  // Call Counters for Statistics
  // --------------------

  uint256 public callCount_propose;
  uint256 public callCount_approve;
  uint256 public callCount_execute;
  uint256 public callCount_withdraw;
  uint256 public callCount_escalate;
  uint256 public callCount_reject;
  uint256 public callCount_cancel;

  // --------------------
  // Constructor
  // --------------------

  struct HandlerConfig {
    ProposalHatter proposalHatter;
    IHats hats;
    address approverAdmin;
    address proposer;
    address executor;
    uint256 recipientHat;
    address[20] testActors;
    address[4] fundingTokens;
    address primarySafe;
    address secondarySafe;
    address underfundedSafe;
  }

  constructor(HandlerConfig memory config) {
    proposalHatter = config.proposalHatter;
    hats = config.hats;
    approverAdmin = config.approverAdmin;
    proposer = config.proposer;
    executor = config.executor;
    recipientHat = config.recipientHat;
    testActors = config.testActors;
    fundingTokens = config.fundingTokens;
    primarySafe = config.primarySafe;
    secondarySafe = config.secondarySafe;
    underfundedSafe = config.underfundedSafe;
  }

  bool private _initialized;

  /// @dev Initialize ghost variables (must be called after construction, before invariant testing)
  function initialize() external {
    // Only initialize once to avoid issues with invariant fuzzing
    if (_initialized) return;
    _initialized = true;

    // Record initial safe balances
    address[3] memory safes = [primarySafe, secondarySafe, underfundedSafe];
    for (uint256 i = 0; i < safes.length; i++) {
      for (uint256 j = 0; j < fundingTokens.length; j++) {
        ghost_safeInitialBalance[safes[i]][fundingTokens[j]] = TestHelpers.getBalance(fundingTokens[j], safes[i]);
      }
    }
  }

  // --------------------
  // Handler Actions
  // --------------------

  /// @dev Propose a new proposal with fuzzed parameters
  function propose(uint256 fundingAmountSeed, uint256 tokenSeed, uint256 timelockSeed, uint256 saltSeed)
    external
    returns (bytes32 proposalId)
  {
    callCount_propose++;

    // Bound inputs to reasonable ranges
    uint88 fundingAmount = uint88(bound(fundingAmountSeed, 0, type(uint88).max / 100)); // Avoid overflow
    address fundingToken = fundingTokens[tokenSeed % fundingTokens.length];
    uint32 timelockSec = uint32(bound(timelockSeed, 0, 7 days));
    bytes32 salt = bytes32(saltSeed);

    // Use proposer to create proposal
    vm.startPrank(proposer);
    try proposalHatter.propose(fundingAmount, fundingToken, timelockSec, recipientHat, 0, "", salt) returns (
      bytes32 _proposalId
    ) {
      proposalId = _proposalId;

      // Track initial proposal data
      IProposalHatterTypes.ProposalData memory proposalData = TestHelpers.getProposalData(proposalHatter, proposalId);
      ghost_proposalInitialData[proposalId] = proposalData;

      // Track proposal ID
      if (!ghost_proposalExists[proposalId]) {
        ghost_allProposalIds.push(proposalId);
        ghost_proposalExists[proposalId] = true;
      }

      // Track approver hat
      if (!ghost_approverHatExists[proposalData.approverHatId]) {
        ghost_approverHats.push(proposalData.approverHatId);
        ghost_approverHatExists[proposalData.approverHatId] = true;
      }
    } catch {
      // Proposal failed (e.g., paused, duplicate), skip tracking
    }
    vm.stopPrank();
  }

  /// @dev Approve a random active proposal using a random actor
  function approve(uint256 proposalIndexSeed, uint256 actorSeed) external {
    callCount_approve++;

    if (ghost_allProposalIds.length == 0) return;

    bytes32 proposalId = ghost_allProposalIds[proposalIndexSeed % ghost_allProposalIds.length];
    IProposalHatterTypes.ProposalData memory proposalData = TestHelpers.getProposalData(proposalHatter, proposalId);

    // Only approve if Active
    if (proposalData.state != IProposalHatterTypes.ProposalState.Active) return;

    // Select a random actor to be the approver
    address approver_ = testActors[actorSeed % testActors.length];

    // Mint approver hat to the random actor
    vm.prank(approverAdmin);
    try hats.mintHat(proposalData.approverHatId, approver_) {
      // Approve as the random actor
      vm.prank(approver_);
      try proposalHatter.approve(proposalId) {
        // Track ETA setting
        uint64 newEta = TestHelpers.getProposalData(proposalHatter, proposalId).eta;
        if (!ghost_etaChanges[proposalId].wasSet) {
          ghost_etaChanges[proposalId] = ETAChangeEvent({ eta: newEta, timestamp: block.timestamp, wasSet: true });
        }
      } catch {
        // Approval failed (e.g., paused)
      }
    } catch {
      // Hat minting failed
    }
  }

  /// @dev Execute a random approved proposal
  function execute(uint256 proposalIndexSeed) external {
    callCount_execute++;

    if (ghost_allProposalIds.length == 0) return;

    bytes32 proposalId = ghost_allProposalIds[proposalIndexSeed % ghost_allProposalIds.length];
    IProposalHatterTypes.ProposalData memory proposalData = TestHelpers.getProposalData(proposalHatter, proposalId);

    // Only execute if Approved and past ETA
    if (proposalData.state != IProposalHatterTypes.ProposalState.Approved) return;
    if (block.timestamp < proposalData.eta) {
      vm.warp(proposalData.eta + 1);
    }

    // Track allowance before
    uint88 allowanceBefore =
      proposalHatter.allowanceOf(proposalData.safe, proposalData.recipientHatId, proposalData.fundingToken);

    // Execute as executor
    vm.prank(executor);
    try proposalHatter.execute(proposalId) {
      // Track allowance after
      uint88 allowanceAfter =
        proposalHatter.allowanceOf(proposalData.safe, proposalData.recipientHatId, proposalData.fundingToken);

      // Track allowance change
      ghost_allowanceChanges[proposalData.safe][proposalData.recipientHatId][proposalData.fundingToken].push(
        AllowanceChange({
          oldAllowance: allowanceBefore,
          newAllowance: allowanceAfter,
          timestamp: block.timestamp,
          actionType: ActionType.Execute
        })
      );

      // Track executed proposal
      ghost_executedProposals[proposalData.safe][proposalData.recipientHatId][proposalData.fundingToken].push(
        ExecutedProposal({
          proposalId: proposalId,
          fundingAmount: proposalData.fundingAmount,
          timestamp: block.timestamp
        })
      );

      // Track total executed funding
      ghost_totalExecutedFunding[proposalData.safe][proposalData.recipientHatId][proposalData.fundingToken] +=
        proposalData.fundingAmount;

      // Track terminal state
      ghost_terminalStates[proposalId] = IProposalHatterTypes.ProposalState.Executed;

      // Track multicall deletion if multicall was non-empty
      if (ghost_proposalInitialData[proposalId].hatsMulticall.length > 0) {
        ghost_multicallDeleted[proposalId] = true;
      }
    } catch {
      // Execution failed (e.g., paused, multicall failed)
    }
  }

  /// @dev Withdraw from a random allowance using a random recipient wearer
  function withdraw(uint256 safeSeed, uint256 tokenSeed, uint256 amountSeed, uint256 actorSeed) external {
    callCount_withdraw++;

    // Select safe and token
    address[3] memory safes = [primarySafe, secondarySafe, underfundedSafe];
    address safe = safes[safeSeed % safes.length];
    address token = fundingTokens[tokenSeed % fundingTokens.length];

    uint88 allowance = proposalHatter.allowanceOf(safe, recipientHat, token);
    if (allowance == 0) return;

    uint88 amount = uint88(bound(amountSeed, 1, allowance));

    // Select a random actor who should wear the recipient hat
    address recipient_ = testActors[actorSeed % testActors.length];

    // Track allowance before
    uint88 allowanceBefore = allowance;

    vm.prank(recipient_);
    try proposalHatter.withdraw(recipientHat, safe, token, amount) {
      // Track allowance after
      uint88 allowanceAfter = proposalHatter.allowanceOf(safe, recipientHat, token);

      // Track allowance change
      ghost_allowanceChanges[safe][recipientHat][token].push(
        AllowanceChange({
          oldAllowance: allowanceBefore,
          newAllowance: allowanceAfter,
          timestamp: block.timestamp,
          actionType: ActionType.Withdraw
        })
      );

      // Track withdrawal
      ghost_withdrawals[safe][recipientHat][token].push(
        Withdrawal({ caller: recipient_, amount: amount, timestamp: block.timestamp })
      );

      // Track total withdrawn
      ghost_totalWithdrawn[safe][recipientHat][token] += amount;
    } catch {
      // Withdrawal failed (e.g., paused, insufficient allowance, not wearing hat)
    }
  }

  /// @dev Escalate a random proposal using the escalator
  function escalate(uint256 proposalIndexSeed) external {
    callCount_escalate++;

    if (ghost_allProposalIds.length == 0) return;

    bytes32 proposalId = ghost_allProposalIds[proposalIndexSeed % ghost_allProposalIds.length];
    IProposalHatterTypes.ProposalData memory proposalData = TestHelpers.getProposalData(proposalHatter, proposalId);

    // Only escalate if Active or Approved
    if (
      proposalData.state != IProposalHatterTypes.ProposalState.Active
        && proposalData.state != IProposalHatterTypes.ProposalState.Approved
    ) return;

    vm.prank(executor);
    try proposalHatter.escalate(proposalId) {
      // Track terminal state
      ghost_terminalStates[proposalId] = IProposalHatterTypes.ProposalState.Escalated;
    } catch {
      // Escalation failed (not wearing escalator hat)
    }
  }

  /// @dev Reject a random proposal using a random actor as approver
  function reject(uint256 proposalIndexSeed, uint256 actorSeed) external {
    callCount_reject++;

    if (ghost_allProposalIds.length == 0) return;

    bytes32 proposalId = ghost_allProposalIds[proposalIndexSeed % ghost_allProposalIds.length];
    IProposalHatterTypes.ProposalData memory proposalData = TestHelpers.getProposalData(proposalHatter, proposalId);

    // Only reject if Active
    if (proposalData.state != IProposalHatterTypes.ProposalState.Active) return;

    // Select a random actor to be the rejecter
    address rejecter = testActors[actorSeed % testActors.length];

    // Mint approver hat to the random actor
    vm.prank(approverAdmin);
    try hats.mintHat(proposalData.approverHatId, rejecter) {
      // Reject as the random actor
      vm.prank(rejecter);
      try proposalHatter.reject(proposalId) {
        // Track terminal state
        ghost_terminalStates[proposalId] = IProposalHatterTypes.ProposalState.Rejected;

        // Track reserved hat toggle if exists
        if (proposalData.reservedHatId != 0) {
          ghost_reservedHatToggles[proposalData.reservedHatId].push(
            ReservedHatToggle({ proposalId: proposalId, toggledOff: true, timestamp: block.timestamp })
          );
        }
      } catch {
        // Rejection failed
      }
    } catch {
      // Hat minting failed
    }
  }

  /// @dev Cancel a random proposal (as the submitter)
  function cancel(uint256 proposalIndexSeed) external {
    callCount_cancel++;

    if (ghost_allProposalIds.length == 0) return;

    bytes32 proposalId = ghost_allProposalIds[proposalIndexSeed % ghost_allProposalIds.length];
    IProposalHatterTypes.ProposalData memory proposalData = TestHelpers.getProposalData(proposalHatter, proposalId);

    // Only cancel if Active or Approved
    if (
      proposalData.state != IProposalHatterTypes.ProposalState.Active
        && proposalData.state != IProposalHatterTypes.ProposalState.Approved
    ) return;

    vm.prank(proposalData.submitter);
    try proposalHatter.cancel(proposalId) {
      // Track terminal state
      ghost_terminalStates[proposalId] = IProposalHatterTypes.ProposalState.Canceled;

      // Track reserved hat toggle if exists
      if (proposalData.reservedHatId != 0) {
        ghost_reservedHatToggles[proposalData.reservedHatId].push(
          ReservedHatToggle({ proposalId: proposalId, toggledOff: true, timestamp: block.timestamp })
        );
      }
    } catch {
      // Cancellation failed
    }
  }

  /// @dev Warp time forward
  function warpTime(uint256 timeDeltaSeed) external {
    uint256 timeDelta = bound(timeDeltaSeed, 1, 30 days);
    vm.warp(block.timestamp + timeDelta);
  }

  // --------------------
  // View Functions for Invariants
  // --------------------

  /// @dev Get total number of executed proposals for a tuple
  function getExecutedProposalCount(address safe, uint256 hat, address token) external view returns (uint256) {
    return ghost_executedProposals[safe][hat][token].length;
  }

  /// @dev Get total number of withdrawals for a tuple
  function getWithdrawalCount(address safe, uint256 hat, address token) external view returns (uint256) {
    return ghost_withdrawals[safe][hat][token].length;
  }

  /// @dev Get total number of allowance changes for a tuple
  function getAllowanceChangeCount(address safe, uint256 hat, address token) external view returns (uint256) {
    return ghost_allowanceChanges[safe][hat][token].length;
  }

  /// @dev Get all proposal IDs
  function getAllProposalIds() external view returns (bytes32[] memory) {
    return ghost_allProposalIds;
  }

  /// @dev Get all approver hats
  function getAllApproverHats() external view returns (uint256[] memory) {
    return ghost_approverHats;
  }
}
