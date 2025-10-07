// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Deploy } from "../script/Deploy.s.sol";
import { ProposalHatter } from "../src/ProposalHatter.sol";
import { IHats } from "../lib/hats-protocol/src/Interfaces/IHats.sol";
import { IProposalHatter, IProposalHatterTypes } from "../src/interfaces/IProposalHatter.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface ISafe {
  function setup(
    address[] calldata _owners,
    uint256 _threshold,
    address to,
    bytes calldata data,
    address fallbackHandler,
    address paymentToken,
    uint256 payment,
    address payable paymentReceiver
  ) external;

  function enableModule(address module) external;

  function execTransaction(
    address to,
    uint256 value,
    bytes calldata data,
    uint8 operation,
    uint256 safeTxGas,
    uint256 baseGas,
    uint256 gasPrice,
    address gasToken,
    address payable refundReceiver,
    bytes memory signatures
  ) external payable returns (bool success);

  function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
    external
    returns (bool success);

  function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, uint8 operation)
    external
    returns (bool success, bytes memory returnData);
}

interface ISafeProxyFactory {
  function createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce)
    external
    returns (address proxy);
}

/// @title Base Test Contract for ProposalHatter
/// @notice Provides comprehensive fork-based test environment with real Hats Protocol and Safe v1.4.1
/// @dev All test contracts should inherit from this base to get consistent setup
contract ForkTestBase is Test {
  // --------------------
  // Constants
  // --------------------

  /// @dev Mainnet fork block (recent, post-Dencun)
  uint256 internal constant FORK_BLOCK = 23_000_000;

  /// @dev Hats Protocol mainnet address
  address internal constant HATS_PROTOCOL = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

  /// @dev Safe v1.4.1 addresses
  address internal constant SAFE_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
  address internal constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
  address internal constant SAFE_COMPATIBILITY_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

  /// @dev Mainnet token addresses
  address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
  address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address internal constant ETH = address(0);

  /// @dev Sentinel values
  uint256 internal constant PUBLIC_SENTINEL = 1;
  address internal constant EMPTY_SENTINEL = address(1);

  // --------------------
  // State Variables
  // --------------------

  /// @dev ProposalHatter instance under test
  ProposalHatter internal proposalHatter;

  /// @dev Hats Protocol instance
  IHats internal hats;

  // Test Accounts (labeled for debugging)
  address internal deployer;
  address internal org;
  address internal proposer;
  address internal approver;
  address internal executor;
  address internal escalator;
  address internal recipient;
  address internal maliciousActor;

  // Test Hats
  uint256 internal topHatId;
  uint256 internal approverBranchId;
  uint256 internal opsBranchId;
  uint256 internal proposerHat;
  uint256 internal executorHat;
  uint256 internal escalatorHat;
  uint256 internal ownerHat;
  uint256 internal recipientHat;

  // Test Safes
  address internal primarySafe;
  address internal secondarySafe;
  address internal disabledSafe;
  address internal underfundedSafe;

  // --------------------
  // Setup
  // --------------------

  function setUp() public virtual {
    // Create and select mainnet fork
    vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);

    // Initialize labeled test accounts
    deployer = makeAddr("deployer");
    org = makeAddr("org");
    proposer = makeAddr("proposer");
    approver = makeAddr("approver");
    executor = makeAddr("executor");
    escalator = makeAddr("escalator");
    recipient = makeAddr("recipient");
    maliciousActor = makeAddr("malicious");

    // Fund accounts with ETH
    // vm.deal(deployer, 100 ether);
    // vm.deal(org, 100 ether);
    // vm.deal(proposer, 10 ether);
    // vm.deal(approver, 10 ether);
    // vm.deal(executor, 10 ether);
    // vm.deal(escalator, 10 ether);
    // vm.deal(recipient, 10 ether);
    // vm.deal(maliciousActor, 10 ether);

    // Initialize Hats Protocol
    hats = IHats(HATS_PROTOCOL);

    // Create test hats tree
    _createHatsTree();

    // Deploy test Safes
    _deployTestSafes();

    // Deploy ProposalHatter
    _deployProposalHatter();

    // Configure ProposalHatter as admin of approver and ops branches
    vm.startPrank(org);
    hats.mintHat(approverBranchId, address(proposalHatter));
    hats.mintHat(opsBranchId, address(proposalHatter));
    vm.stopPrank();

    // Enable ProposalHatter as module on primary, secondary and underfunded Safes (org is the owner)
    _enableModuleOnSafe(primarySafe, address(proposalHatter));
    _enableModuleOnSafe(secondarySafe, address(proposalHatter));
    _enableModuleOnSafe(underfundedSafe, address(proposalHatter));
  }

  // --------------------
  // Internal Setup Helpers
  // --------------------

  /// @dev Creates the complete hats tree for testing
  function _createHatsTree() internal {
    vm.startPrank(org);

    // Create top hat (x)
    topHatId = hats.mintTopHat(org, "Test Top Hat", "");

    // Create approver branch root (x.1)
    approverBranchId = hats.createHat(topHatId, "Approver Branch Root", 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

    // Create ops branch root (x.2)
    opsBranchId = hats.createHat(topHatId, "Ops Branch Root", 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

    // Create proposer hat (x.3)
    proposerHat = hats.createHat(topHatId, "Proposer", 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

    // Create executor hat (x.4)
    executorHat = hats.createHat(topHatId, "Executor", 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

    // Create escalator hat (x.5)
    escalatorHat = hats.createHat(topHatId, "Escalator", 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

    // Create owner hat (x.6)
    ownerHat = hats.createHat(topHatId, "Owner", 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

    // Create recipient hat (x.7)
    recipientHat = hats.createHat(topHatId, "Recipient", 1, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

    // Mint role hats to test accounts
    hats.mintHat(proposerHat, proposer);
    hats.mintHat(executorHat, executor);
    hats.mintHat(escalatorHat, escalator);
    hats.mintHat(ownerHat, org);
    hats.mintHat(recipientHat, recipient);

    vm.stopPrank();
  }

  /// @dev Deploys test Safe instances using Safe v1.4.1 factory
  /// @notice All Safes are owned by `org` account
  function _deployTestSafes() internal {
    ISafeProxyFactory factory = ISafeProxyFactory(SAFE_FACTORY);

    // Primary Safe: Module enabled, funded, owned by org
    primarySafe = _deploySafe(factory, org, 1);
    _dealTokens(ETH, primarySafe, 100 ether);
    _dealTokens(USDC, primarySafe, 1_000_000 * 1e6); // 1M USDC
    _dealTokens(USDT, primarySafe, 1_000_000 * 1e6); // 1M USDT
    _dealTokens(DAI, primarySafe, 1_000_000 * 1e18); // 1M DAI

    // Secondary Safe: For multi-safe tests, owned by org
    secondarySafe = _deploySafe(factory, org, 2);
    _dealTokens(ETH, secondarySafe, 50 ether);
    _dealTokens(USDC, secondarySafe, 500_000 * 1e6); // 500K USDC
    _dealTokens(USDT, secondarySafe, 500_000 * 1e6); // 500K USDT
    _dealTokens(DAI, secondarySafe, 500_000 * 1e18); // 500K DAI

    // Disabled Safe: Module will NOT be enabled, owned by org
    disabledSafe = _deploySafe(factory, org, 3);
    _dealTokens(ETH, disabledSafe, 10 ether);
    _dealTokens(USDC, disabledSafe, 100_000 * 1e6); // 100K USDC
    _dealTokens(USDT, disabledSafe, 100_000 * 1e6); // 100K USDT
    _dealTokens(DAI, disabledSafe, 100_000 * 1e18); // 100K DAI

    // Underfunded Safe: Low balance for revert tests, owned by org
    underfundedSafe = _deploySafe(factory, org, 4);
    _dealTokens(ETH, underfundedSafe, 0.1 ether);
    _dealTokens(USDC, underfundedSafe, 100 * 1e6); // 100 USDC
    _dealTokens(USDT, underfundedSafe, 100 * 1e6); // 100 USDT
    _dealTokens(DAI, underfundedSafe, 100 * 1e18); // 100 DAI
  }

  /// @dev Helper to deploy a Safe with a single owner
  function _deploySafe(ISafeProxyFactory _factory, address _owner, uint256 _saltNonce) internal returns (address) {
    address[] memory owners = new address[](1);
    owners[0] = _owner;

    bytes memory initializer = abi.encodeWithSelector(
      ISafe.setup.selector,
      owners, // _owners
      1, // _threshold
      address(0), // to
      "", // data
      SAFE_COMPATIBILITY_FALLBACK_HANDLER, // fallbackHandler
      address(0), // paymentToken
      0, // payment
      payable(address(0)) // paymentReceiver
    );

    return _factory.createProxyWithNonce(SAFE_L2_SINGLETON, initializer, _saltNonce);
  }

  /// @dev Deploys ProposalHatter contract using the Deploy script
  /// @notice This ensures tests validate the actual deployment script
  function _deployProposalHatter() internal {
    vm.startPrank(deployer);

    // Instantiate the Deploy script
    Deploy deployScript = new Deploy();

    // Use a deterministic salt for tests
    bytes32 testSalt = bytes32(uint256(1));

    // Deploy via the script's deploy() function
    proposalHatter = deployScript.deploy(
      HATS_PROTOCOL,
      primarySafe, // initial safe
      ownerHat,
      proposerHat,
      executorHat,
      escalatorHat,
      approverBranchId,
      opsBranchId,
      testSalt
    );

    vm.stopPrank();
  }

  /// @dev Helper to enable a module on a Safe using vm.prank as the Safe itself
  /// @param safe The Safe address
  /// @param module The module to enable
  function _enableModuleOnSafe(address safe, address module) internal {
    // For testing, we use vm.prank to call enableModule as the Safe itself
    // This simulates the module being enabled via Safe's execTransaction
    vm.prank(safe);
    ISafe(safe).enableModule(module);
  }

  // --------------------
  // Test Helper Functions
  // --------------------

  /// @dev Creates a test proposal with default parameters
  /// @return proposalId The created proposal ID
  function _createTestProposal() internal returns (bytes32 proposalId) {
    return _createTestProposal(1e18, ETH, 0, recipientHat, 0, "", bytes32(0));
  }

  /// @dev Creates a test proposal with custom parameters
  /// @param fundingAmount Amount to fund
  /// @param fundingToken Token to fund
  /// @param timelockSec Timelock in seconds
  /// @param recipientHatId Recipient hat
  /// @param reservedHatId Reserved hat (0 for none)
  /// @param hatsMulticall Hats multicall bytes
  /// @param salt Salt for uniqueness
  /// @return proposalId The created proposal ID
  function _createTestProposal(
    uint88 fundingAmount,
    address fundingToken,
    uint32 timelockSec,
    uint256 recipientHatId,
    uint256 reservedHatId,
    bytes memory hatsMulticall,
    bytes32 salt
  ) internal returns (bytes32 proposalId) {
    vm.prank(proposer);
    proposalId = proposalHatter.propose(
      fundingAmount, fundingToken, timelockSec, recipientHatId, reservedHatId, hatsMulticall, salt
    );
  }

  /// @dev Approves a proposal as the approver
  /// @param proposalId The proposal to approve
  function _approveProposal(bytes32 proposalId) internal {
    // Get the proposal to find its approver hat
    (,, IProposalHatterTypes.ProposalState state,,,,,, uint256 approverHatId,,) = proposalHatter.proposals(proposalId);

    require(state == IProposalHatterTypes.ProposalState.Active, "Proposal not active");

    // Mint approver hat to approver account
    vm.prank(address(proposalHatter));
    hats.mintHat(approverHatId, approver);

    // Approve as approver
    vm.prank(approver);
    proposalHatter.approve(proposalId);
  }

  /// @dev Executes a proposal as the executor
  /// @param proposalId The proposal to execute
  function _executeProposal(bytes32 proposalId) internal {
    vm.prank(executor);
    proposalHatter.execute(proposalId);
  }

  /// @dev Advances time past the ETA
  /// @param proposalId The proposal whose ETA to pass
  function _warpPastETA(bytes32 proposalId) internal {
    (,,,, uint64 eta,,,,,,) = proposalHatter.proposals(proposalId);
    vm.warp(eta + 1);
  }

  /// @dev Full proposal lifecycle: propose -> approve -> wait -> execute
  /// @return proposalId The executed proposal ID
  function _executeFullProposalLifecycle() internal returns (bytes32 proposalId) {
    proposalId = _createTestProposal();
    _approveProposal(proposalId);
    _warpPastETA(proposalId);
    _executeProposal(proposalId);
  }

  /// @dev Creates and returns a malicious ERC20 token for testing
  /// @return token The malicious token address
  function _deployMaliciousToken() internal returns (address token) {
    // Will be implemented in helpers/MaliciousTokens.sol
    // For now, return a placeholder
    token = makeAddr("maliciousToken");
  }

  /// @dev Helper to get the next hat ID under an admin
  /// @param admin The admin hat ID
  /// @return nextId The next child hat ID
  function _getNextHatId(uint256 admin) internal view returns (uint256 nextId) {
    return hats.getNextId(admin);
  }

  /// @dev Helper to check if an address wears a hat
  /// @param wearer The address to check
  /// @param hatId The hat ID
  /// @return isWearer True if wearer has the hat
  function _isWearerOfHat(address wearer, uint256 hatId) internal view returns (bool isWearer) {
    return hats.isWearerOfHat(wearer, hatId);
  }

  /// @dev Helper to get token balance
  /// @param token Token address (address(0) for ETH)
  /// @param account Account to check
  /// @return balance The balance
  function _getBalance(address token, address account) internal view returns (uint256 balance) {
    if (token == ETH) {
      return account.balance;
    } else {
      return IERC20(token).balanceOf(account);
    }
  }

  /// @dev Helper to deal tokens to an address
  /// @param token Token address
  /// @param to Recipient
  /// @param amount Amount to deal
  function _dealTokens(address token, address to, uint256 amount) internal {
    if (token == ETH) {
      vm.deal(to, amount);
    } else {
      deal(token, to, amount);
    }
  }
}
