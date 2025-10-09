// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title Malicious Token Implementations for Testing
/// @notice Various non-standard ERC20 behaviors for attack testing

/// @dev Token that returns false on transfer
contract FalseReturningToken is ERC20 {
  constructor() ERC20("False Token", "FALSE") {
    _mint(msg.sender, 1_000_000 * 10 ** decimals());
  }

  function transfer(address, uint256) public pure override returns (bool) {
    return false;
  }
}

/// @dev Token that returns no data on transfer (like USDT)
contract NoReturnToken is ERC20 {
  constructor() ERC20("No Return Token", "NORET") {
    _mint(msg.sender, 1_000_000 * 10 ** decimals());
  }

  function transfer(address to, uint256 amount) public override returns (bool) {
    _transfer(msg.sender, to, amount);
    assembly {
      return(0, 0) // Return no data
    }
  }
}

/// @dev Token that returns malformed data (not 32 bytes)
contract MalformedReturnToken is ERC20 {
  constructor() ERC20("Malformed Token", "MALFORM") {
    _mint(msg.sender, 1_000_000 * 10 ** decimals());
  }

  function transfer(address to, uint256 amount) public override returns (bool) {
    _transfer(msg.sender, to, amount);
    assembly {
      mstore(0, 0x01)
      return(0, 16) // Return 16 bytes instead of 32
    }
  }
}

/// @dev Token with reentrancy hook
contract ReentrantToken is ERC20 {
  address public targetContract;
  bytes public reentrantCalldata;
  bool public shouldReenter;

  constructor() ERC20("Reentrant Token", "REENT") {
    _mint(msg.sender, 1_000_000 * 10 ** decimals());
  }

  function setReentrantCall(address target, bytes memory callData) external {
    targetContract = target;
    reentrantCalldata = callData;
    shouldReenter = true;
  }

  function transfer(address to, uint256 amount) public override returns (bool) {
    if (shouldReenter && targetContract != address(0)) {
      shouldReenter = false; // Prevent infinite loop
      (bool success,) = targetContract.call(reentrantCalldata);
      require(success, "Reentrant call failed");
    }
    return super.transfer(to, amount);
  }
}
