// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";

/// @title Reentrancy Attack Tests
/// @notice Tests for reentrancy vulnerabilities
contract ProposalHatter_Reentrancy_Test is ForkTestBase {
  function Attack_ReentrantWithdraw() public {
    // TODO: Deploy malicious ERC20 with reentrancy hook
  }

  function Attack_ReentrantExecute() public {
    // TODO: Deploy malicious Hats multicall payload
  }

  function ReadOnlyReentrancy() public {
    // TODO: During execute, external call reads ProposalHatter state
  }
}
