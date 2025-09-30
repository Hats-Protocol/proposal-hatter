// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IAllowanceModule {
  function executeAllowanceTransfer(
    address safe,
    address token,
    address to,
    uint96 amount,
    address paymentToken,
    uint96 payment,
    address delegate,
    bytes calldata signature
  ) external;
}
