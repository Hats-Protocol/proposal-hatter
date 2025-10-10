// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";

/// @title Gas Benchmarks for ProposalHatter
/// @notice Gas cost tracking using forge snapshot
contract ProposalHatter_Gas_Test is ForkTestBase {
  // =============================================================================
  // Propose Costs
  // =============================================================================

  function Gas_ProposeEmptyMulticall() public {
    // TODO: Funding-only proposal (0 bytes hatsMulticall)
  }

  function Gas_ProposeSmallMulticall() public {
    // TODO: 100 bytes hatsMulticall
  }

  function Gas_ProposeLargeMulticall() public {
    // TODO: 5KB hatsMulticall
  }

  function Gas_ProposeWithReservedHat() public {
    // TODO: Additional cost of reservedHatId creation
  }

  // =============================================================================
  // Execute Costs
  // =============================================================================

  function Gas_ExecuteFundingOnly() public {
    // TODO: No multicall, baseline cost
  }

  function Gas_ExecuteSmallMulticall() public {
    // TODO: 1-5 Hats calls
  }

  function Gas_ExecuteLargeMulticall() public {
    // TODO: 50+ Hats calls
  }

  function Gas_ExecuteHatsMulticallDeletion() public {
    // TODO: Verify delete provides refund (compare with/without)
  }

  // =============================================================================
  // Withdraw Costs
  // =============================================================================

  function Gas_WithdrawETH() public {
    // TODO: Native ETH transfer
  }

  function Gas_WithdrawERC20() public {
    // TODO: Standard ERC20 transfer
  }

  function Gas_WithdrawColdVsWarm() public {
    // TODO: First withdrawal (cold SLOAD) vs subsequent (warm)
  }
}
