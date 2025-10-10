// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";

/// @title Multi-Proposal Testing for ProposalHatter
/// @notice Tests for parallel proposals and multi-safe scenarios
contract ProposalHatter_MultiProposal_Test is ForkTestBase {
  function _MultipleProposals_SameRecipient() public {
    // TODO: Accumulate allowances, withdraw partially
  }

  function _MultiSafeSupport() public {
    // TODO: Create proposals for different Safes, verify isolated allowances
  }

  function _ParallelLifecycles() public {
    // TODO: Multiple proposals at different states simultaneously
  }
}
