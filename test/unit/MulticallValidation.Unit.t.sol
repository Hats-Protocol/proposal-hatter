// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ForkTestBase, HarnessTestBase } from "../Base.t.sol";
import { IProposalHatterErrors } from "../../src/interfaces/IProposalHatter.sol";
import { IMulticallable } from "../../src/interfaces/IMulticallable.sol";
import { EfficientHashLib } from "../../lib/solady/src/utils/EfficientHashLib.sol";

/// @title DecodeMulticallPayload Tests for ProposalHatter
/// @notice Tests for decodeMulticallPayload and _checkMulticall validation
contract DecodeMulticallPayload_Tests is ForkTestBase {
  uint256 hatId;

  function setUp() public override {
    super.setUp();
    hatId = recipientHat;
  }

  /// @notice Test decoding a valid single-element bytes[] array
  /// @dev Verifies that decodeMulticallPayload correctly handles one element
  function test_DecodeMulticallPayload_ValidSingle() public view {
    // Arrange: Create valid bytes[] with one element
    bytes[] memory expected = new bytes[](1);
    expected[0] = hex"aabbccdd";
    bytes memory encoded = abi.encode(expected);

    // Act: Decode using the public helper function
    bytes[] memory result = proposalHatter.decodeMulticallPayload(encoded);

    // Assert: Verify decoded array matches expected
    assertEq(result.length, 1, "Array length should be 1");
    assertEq(result[0], expected[0], "Element should match expected value");
  }

  /// @notice Test decoding a valid multi-element bytes[] array
  /// @dev Verifies that decodeMulticallPayload correctly handles multiple elements
  function test_DecodeMulticallPayload_ValidMultiple() public view {
    // Arrange: Create valid bytes[] with multiple elements
    bytes[] memory expected = new bytes[](3);
    expected[0] = hex"11223344";
    expected[1] = hex"aabbccdd";
    expected[2] = hex"deadbeef";
    bytes memory encoded = abi.encode(expected);

    // Act: Decode using the public helper function
    bytes[] memory result = proposalHatter.decodeMulticallPayload(encoded);

    // Assert: Verify decoded array matches expected
    assertEq(result.length, 3, "Array length should be 3");
    assertEq(result[0], expected[0], "Element 0 should match");
    assertEq(result[1], expected[1], "Element 1 should match");
    assertEq(result[2], expected[2], "Element 2 should match");
  }

  /// @notice Test decoding an empty bytes[] array
  /// @dev Verifies that decodeMulticallPayload correctly handles zero elements
  function test_DecodeMulticallPayload_Empty() public view {
    // Arrange: Create empty bytes[] array
    bytes[] memory expected = new bytes[](0);
    bytes memory encoded = abi.encode(expected);

    // Act: Decode using the public helper function
    bytes[] memory result = proposalHatter.decodeMulticallPayload(encoded);

    // Assert: Verify decoded array is empty
    assertEq(result.length, 0, "Array length should be 0");
  }

  function test_RevertIf_DecodeMulticallPayload_Invalid() public {
    // Arrange: Create invalid bytes[] array
    bytes memory invalidEncoded = hex"0000000000000000000000000000000000000000000000000000000000000020"; // Missing data

    // Act & Assert: Expect revert when decoding invalid ABI data
    vm.expectRevert();
    proposalHatter.decodeMulticallPayload(invalidEncoded);
  }

  /// @notice Test decoding with invalid ABI encoding (truncated data)
  /// @dev Verifies that decodeMulticallPayload reverts with invalid ABI data
  function test_DecodeMulticallPayload_RevertIf_InvalidABI() public {
    // Arrange: Create truncated/invalid ABI-encoded data
    bytes memory invalidEncoded = hex"0000000000000000000000000000000000000000000000000000000000000020"; // Missing data

    // Act & Assert: Expect revert when decoding invalid ABI data
    vm.expectRevert();
    proposalHatter.decodeMulticallPayload(invalidEncoded);
  }

  /// @notice Test decoding with non-array encoded data (single address)
  /// @dev Verifies that decodeMulticallPayload reverts when data is not a bytes[] array
  function test_DecodeMulticallPayload_RevertIf_NotArray() public {
    // Arrange: Create ABI-encoded address instead of bytes[]
    bytes memory notArrayEncoded = abi.encode(address(0x1234567890123456789012345678901234567890));

    // Act & Assert: Expect revert when decoding non-array data
    vm.expectRevert();
    proposalHatter.decodeMulticallPayload(notArrayEncoded);
  }
}

contract CheckMulticall_Tests is HarnessTestBase {
  function test_CheckMulticall_EmptyBytes() public view {
    // Arrange: Create empty bytes
    bytes memory raw = bytes("");

    // Act & Assert: Should return bytes32(0)
    bytes32 multicallHash = proposalHatterHarness.checkMulticall(raw);
    assertEq(multicallHash, bytes32(0));
  }

  function test_CheckMulticall_ValidPayload() public view {
    // Arrange: Create valid call
    bytes memory raw = _buildSingleHatCreationMulticall(topHatId, "Details");

    // Act & Assert: Should not revert
    bytes32 multicallHash = proposalHatterHarness.checkMulticall(raw);

    // Should return the hash of the multicall
    assertEq(multicallHash, EfficientHashLib.hash(raw));
  }

  function test_CheckMulticall_RevertIf_TooShort() public {
    // Arrange: Create call with only 3 bytes (incomplete selector)
    bytes memory raw = hex"aabbcc";

    // Act & Assert: Should revert with InvalidMulticall error
    vm.expectRevert(IProposalHatterErrors.InvalidMulticall.selector);
    proposalHatterHarness.checkMulticall(raw);
  }

  function testFuzz_CheckMulticall_RevertIf_WrongSelector(bytes4 selector) public {
    // ensure it's not accidentally the correct multicall selector
    vm.assume(selector != IMulticallable.multicall.selector);
    // Arrange: Create call with wrong selector
    bytes32 args = bytes32(uint256(1));
    bytes memory raw = abi.encodeWithSelector(selector, args);

    // Act & Assert: Should revert with InvalidMulticall error
    vm.expectRevert(IProposalHatterErrors.InvalidMulticall.selector);
    proposalHatterHarness.checkMulticall(raw);
  }

  function testFuzz_CheckMulticall_RevertIf_InvalidPayload(bytes32 args) public {
    // Arrange: Create call with correct selector but invalid payload
    bytes memory raw = abi.encodeWithSelector(IMulticallable.multicall.selector, args);

    // Act & Assert: Should revert with InvalidMulticall error
    vm.expectRevert(IProposalHatterErrors.InvalidMulticall.selector);
    proposalHatterHarness.checkMulticall(raw);
  }
}
