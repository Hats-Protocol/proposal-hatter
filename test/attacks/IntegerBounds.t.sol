// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase } from "../Base.t.sol";

/// @title Integer Boundary Exploit Tests
/// @notice Tests for integer overflow/underflow edge cases
contract ProposalHatter_IntegerBounds_Test is ForkTestBase {
  function Bound_Uint88AllowanceMax() public {
    // TODO: Create proposal with fundingAmount = type(uint88).max
  }

  function Bound_Uint88AllowanceOverflow() public {
    // TODO: Recipient has existing allowance near max, execute new proposal that would overflow
  }

  function Bound_Uint32TimelockMax() public {
    // TODO: Create proposal with timelockSec = type(uint32).max
  }

  function Bound_CumulativeAllowances() public {
    // TODO: Execute 100 proposals for same (safe, recipient, token)
  }
}
