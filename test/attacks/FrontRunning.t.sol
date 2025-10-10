// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";

/// @title Front-Running Attack Tests
/// @notice Tests for MEV and front-running resistance
contract ProposalHatter_FrontRunning_Test is ForkTestBase {
  function Attack_FrontRunPropose() public {
    // TODO: Attacker front-runs propose with same params + different salt
  }

  function Attack_ProposalIdIncludesSubmitter() public {
    // TODO: Two users propose identical params, verify different IDs
  }
}
