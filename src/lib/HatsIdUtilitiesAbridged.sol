// SPDX-License-Identifier: AGPL-3.0
// Copyright (C) 2025 Haberdasher Labs
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.8.13;

import { IProposalHatterErrors } from "../interfaces/IProposalHatter.sol";

/// @title Hats Id Utilities — Abridged
/// @dev Select functions for working with Hat Ids from Hats Protocol. Abridged from TODO
/// @author Haberdasher Labs
contract HatsIdUtilitiesAbridged {
  // --------------------
  // Select functions from original HatsIdUtilities
  // --------------------

  /// @dev Number of bits of address space for each level below the tophat
  uint256 internal constant LOWER_LEVEL_ADDRESS_SPACE = 16;

  /// @dev Maximum number of levels below the tophat, ie max tree depth
  ///      (256 - TOPHAT_ADDRESS_SPACE) / LOWER_LEVEL_ADDRESS_SPACE;
  uint256 internal constant MAX_LEVELS = 14;

  /// @notice Identifies the level a given hat in its local hat tree
  /// @dev Similar to getHatLevel, but does not account for linked trees
  /// @param _hatId the id of the hat in question
  /// @return level The local level, from 0 to 14
  function getLocalHatLevel(uint256 _hatId) public pure returns (uint32 level) {
    if (_hatId & uint256(type(uint224).max) == 0) return 0;
    if (_hatId & uint256(type(uint208).max) == 0) return 1;
    if (_hatId & uint256(type(uint192).max) == 0) return 2;
    if (_hatId & uint256(type(uint176).max) == 0) return 3;
    if (_hatId & uint256(type(uint160).max) == 0) return 4;
    if (_hatId & uint256(type(uint144).max) == 0) return 5;
    if (_hatId & uint256(type(uint128).max) == 0) return 6;
    if (_hatId & uint256(type(uint112).max) == 0) return 7;
    if (_hatId & uint256(type(uint96).max) == 0) return 8;
    if (_hatId & uint256(type(uint80).max) == 0) return 9;
    if (_hatId & uint256(type(uint64).max) == 0) return 10;
    if (_hatId & uint256(type(uint48).max) == 0) return 11;
    if (_hatId & uint256(type(uint32).max) == 0) return 12;
    if (_hatId & uint256(type(uint16).max) == 0) return 13;
    return 14;
  }
  /// @notice Checks whether a hat is a topHat in its local hat tree
  /// @dev Similar to isTopHat, but does not account for linked trees
  /// @param _hatId The hat in question
  /// @return _isLocalTopHat Whether the hat is a topHat for its local tree

  function isLocalTopHat(uint256 _hatId) public pure returns (bool _isLocalTopHat) {
    _isLocalTopHat = _hatId > 0 && uint224(_hatId) == 0;
  }

  /// @notice Gets the hat id of the admin at a given level of a given hat
  ///         local to the tree containing the hat.
  /// @param _hatId the id of the hat in question
  /// @param _level the admin level of interest
  /// @return admin The hat id of the resulting admin
  function getAdminAtLocalLevel(uint256 _hatId, uint32 _level) public pure returns (uint256 admin) {
    uint256 mask = type(uint256).max << (LOWER_LEVEL_ADDRESS_SPACE * (MAX_LEVELS - _level));

    admin = _hatId & mask;
  }

  // --------------------
  // Additional functions for ProposalHatter
  // --------------------

  /// @dev Returns true if `node` is in the branch rooted at `root`.
  /// @param node The node to check.
  /// @param root The root of the branch to check.
  /// @return True if `node` is in the branch rooted at `root`.
  function _isInBranch(uint256 node, uint256 root) internal pure returns (bool) {
    // shortcut if nodes are the same
    if (node == root) return true;
    uint32 level = getLocalHatLevel(node);
    for (uint32 i; i < level; i++) {
      if (getAdminAtLocalLevel(node, i) == root) return true;
    }
    return false;
  }

  /// @dev Returns the admin hat of `node`.
  /// @param node The node to get the admin hat of.
  /// @return The admin hat of `node`.
  function _getAdminHat(uint256 node) internal pure returns (uint256) {
    // Ensure the node is not a top hat to protect against underflows
    if (isLocalTopHat(node)) revert IProposalHatterErrors.InvalidReservedHatId();

    return getAdminAtLocalLevel(node, getLocalHatLevel(node) - 1);
  }
}
