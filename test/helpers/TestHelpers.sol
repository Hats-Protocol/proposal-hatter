// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IHats } from "../../lib/hats-protocol/src/Interfaces/IHats.sol";

/// @title Test Helpers for ProposalHatter
/// @notice Shared utilities for testing
library TestHelpers {
  address internal constant EMPTY_SENTINEL = address(1);

  /// @dev Encode a Hats createHat call with the provided parameters.
  function encodeCreateHatCall(
    uint256 admin,
    string memory details,
    uint32 maxSupply,
    address eligibility,
    address toggle,
    bool mutable_,
    string memory imageURI
  ) internal pure returns (bytes memory) {
    return abi.encodeWithSelector(
      IHats.createHat.selector, admin, details, maxSupply, eligibility, toggle, mutable_, imageURI
    );
  }

  /// @dev ABI-encode an array of calls for Hats multicall usage.
  function encodeMulticall(bytes[] memory calls) internal pure returns (bytes memory) {
    return abi.encode(calls);
  }

  /// @dev Convenience helper for the common single-hat creation multicall payload.
  function singleHatCreationMulticall(uint256 admin, string memory details) internal pure returns (bytes memory) {
    bytes[] memory calls = new bytes[](1);
    calls[0] = encodeCreateHatCall(admin, details, 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");
    return encodeMulticall(calls);
  }
}
