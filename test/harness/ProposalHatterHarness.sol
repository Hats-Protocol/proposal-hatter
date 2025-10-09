// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ProposalHatter } from "../../src/ProposalHatter.sol";

/// @title ProposalHatterHarness
/// @notice Harness for ProposalHatter
/// @dev This contract is used to test ProposalHatter contract internal functions
contract ProposalHatterHarness is ProposalHatter {
  constructor(
    address hatsProtocolAddress,
    address safe,
    uint256 ownerHatId,
    uint256 proposerHatId,
    uint256 executorHatId,
    uint256 escalatorHatId,
    uint256 approverBranchId,
    uint256 opsBranchId
  )
    ProposalHatter(
      hatsProtocolAddress,
      safe,
      ownerHatId,
      proposerHatId,
      executorHatId,
      escalatorHatId,
      approverBranchId,
      opsBranchId
    )
  { }

  /// @notice Validate the multicall, getting the multicall hash if valid, or reverting if invalid
  /// @param hatsMulticall The multicall to check
  /// @return The hash of the multicall
  function checkMulticall(bytes calldata hatsMulticall) public view returns (bytes32) {
    return _checkMulticall(hatsMulticall);
  }
}
