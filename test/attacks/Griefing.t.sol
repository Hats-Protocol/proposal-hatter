// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";

/// @title Griefing Attack Tests
/// @notice Tests for griefing attack vectors
contract ProposalHatter_Griefing_Test is ForkTestBase {
  function Attack_ReservedHatIndexRace() public {
    // TODO: Attacker front-runs propose to create hats under opsBranchId
  }

  function Attack_AllowanceExhaustion() public {
    // TODO: Create proposals accumulating allowances approaching uint88.max
  }

  function Attack_SpamProposals() public {
    // TODO: Malicious proposer creates many proposals with different salts
  }
}
