// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IHats } from "../../lib/hats-protocol/src/Interfaces/IHats.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IProposalHatterTypes } from "../../src/interfaces/IProposalHatter.sol";
import { IProposalHatter } from "../../src/interfaces/IProposalHatter.sol";

/// @title Test Helpers for ProposalHatter
/// @notice Shared utilities for testing
library TestHelpers {
  address internal constant EMPTY_SENTINEL = address(1);
  address internal constant ETH = address(0);

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

  /// @dev Get token balance (ETH or ERC20)
  function getBalance(address token, address account) internal view returns (uint256) {
    if (token == ETH) {
      return account.balance;
    } else {
      return IERC20(token).balanceOf(account);
    }
  }

  /// @dev Get proposal data as a struct
  function getProposalData(IProposalHatter proposalHatter, bytes32 proposalId)
    internal
    view
    returns (IProposalHatterTypes.ProposalData memory data)
  {
    // Fetch in two calls to avoid stack depth issues
    (data.submitter, data.fundingAmount, data.state, data.fundingToken, data.eta, data.timelockSec,,,,,) =
      proposalHatter.proposals(proposalId);

    (,,,,,, data.safe, data.recipientHatId, data.approverHatId, data.reservedHatId, data.hatsMulticall) =
      proposalHatter.proposals(proposalId);
  }
}
