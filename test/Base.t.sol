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

  /// @dev Array of funding tokens for fuzz testing
  address[4] internal FUNDING_TOKENS;

  /// @dev Array of test actors for fuzz testing (deterministic addresses)
  address[20] internal TEST_ACTORS;

  // Test Accounts (labeled for debugging)
  address internal deployer;
  address internal org;
  address internal proposer;
  address internal approver;
  address internal executor;
  address internal escalator;
  address internal recipient;
  address internal approverAdmin;
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
    approverAdmin = makeAddr("approverAdmin");
    maliciousActor = makeAddr("malicious");

    // Initialize Hats Protocol
    hats = IHats(HATS_PROTOCOL);

    // Initialize funding tokens array for fuzz testing
    FUNDING_TOKENS = [ETH, USDC, USDT, DAI];

    // Initialize test actors array for fuzz testing
    TEST_ACTORS = [
      makeAddr("actor1"),
      makeAddr("actor2"),
      makeAddr("actor3"),
      makeAddr("actor4"),
      makeAddr("actor5"),
      makeAddr("actor6"),
      makeAddr("actor7"),
      makeAddr("actor8"),
      makeAddr("actor9"),
      makeAddr("actor10"),
      makeAddr("actor11"),
      makeAddr("actor12"),
      makeAddr("actor13"),
      makeAddr("actor14"),
      makeAddr("actor15"),
      makeAddr("actor16"),
      makeAddr("actor17"),
      makeAddr("actor18"),
      makeAddr("actor19"),
      makeAddr("actor20")
    ];

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

    // Create approver branch root (x.1) with a maxSupply of 2 (for approverAdmin and ProposalHatter)
    approverBranchId = hats.createHat(topHatId, "Approver Branch Root", 2, EMPTY_SENTINEL, EMPTY_SENTINEL, true, "");

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
    hats.mintHat(approverBranchId, approverAdmin);

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
  /// @return expected The expected proposal data
  function _createTestProposal()
    internal
    returns (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected)
  {
    return _createTestProposal(1e18, ETH, 0, recipientHat, 0, "", bytes32(0));
  }

  /// @dev Creates a test proposal with custom timelock
  /// @param timelockSec Timelock in seconds
  /// @param salt Salt for uniqueness
  /// @return proposalId The created proposal ID
  /// @return expected The expected proposal data
  function _createTestProposal(uint32 timelockSec, bytes32 salt)
    internal
    returns (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected)
  {
    return _createTestProposal(1e18, ETH, timelockSec, recipientHat, 0, "", salt);
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
  /// @return expected The expected proposal data
  function _createTestProposal(
    uint88 fundingAmount,
    address fundingToken,
    uint32 timelockSec,
    uint256 recipientHatId,
    uint256 reservedHatId,
    bytes memory hatsMulticall,
    bytes32 salt
  ) internal returns (bytes32 proposalId, IProposalHatterTypes.ProposalData memory expected) {
    // Build expected proposal data
    expected = _buildExpectedProposal(
      proposer,
      fundingAmount,
      fundingToken,
      timelockSec,
      recipientHatId,
      reservedHatId,
      hatsMulticall,
      IProposalHatterTypes.ProposalState.Active
    );

    // Create the proposal
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
    (proposalId,) = _createTestProposal();
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

  /// @dev Helper to build expected proposal data struct with contract-provided defaults.
  /// @param submitter The proposal submitter
  /// @param fundingAmount The funding amount
  /// @param fundingToken The funding token address
  /// @param timelockSec The timelock duration
  /// @param recipientHatId The recipient hat ID
  /// @param reservedHatId The reserved hat ID (0 if none)
  /// @param hatsMulticall The hats multicall bytes
  /// @param state The expected proposal state
  /// @return expected The expected proposal data with defaults set
  function _buildExpectedProposal(
    address submitter,
    uint88 fundingAmount,
    address fundingToken,
    uint32 timelockSec,
    uint256 recipientHatId,
    uint256 reservedHatId,
    bytes memory hatsMulticall,
    IProposalHatterTypes.ProposalState state
  ) internal view returns (IProposalHatterTypes.ProposalData memory expected) {
    return IProposalHatterTypes.ProposalData({
      submitter: submitter,
      fundingAmount: fundingAmount,
      state: state,
      fundingToken: fundingToken,
      eta: 0,
      timelockSec: timelockSec,
      safe: proposalHatter.safe(),
      recipientHatId: recipientHatId,
      approverHatId: _getNextHatId(proposalHatter.APPROVER_BRANCH_ID()),
      reservedHatId: reservedHatId,
      hatsMulticall: hatsMulticall
    });
  }

  /// @dev Helper to assert that a hat was created correctly
  /// @param hatId The hat ID to check
  /// @param expectedAdmin The expected admin hat ID
  /// @param expectedDetails The expected details string
  function _assertHatCreated(uint256 hatId, uint256 expectedAdmin, string memory expectedDetails) internal view {
    // Get hat data
    (
      string memory details,
      uint32 maxSupply,
      uint32 supply,
      address eligibility,
      address toggle,
      ,
      , // skip imageURI and lastHatId (imageURI may have default value from Hats Protocol)
      bool mutable_,
      bool active
    ) = hats.viewHat(hatId);

    // Verify hat properties
    assertEq(details, expectedDetails, "Hat details mismatch");
    assertEq(maxSupply, 1, "Max supply should be 1");
    assertEq(supply, 0, "Supply should be 0 (not minted yet)");
    assertEq(eligibility, EMPTY_SENTINEL, "Eligibility should be EMPTY_SENTINEL");
    assertEq(toggle, EMPTY_SENTINEL, "Toggle should be EMPTY_SENTINEL");
    assertTrue(mutable_, "Hat should be mutable");
    assertTrue(active, "Hat should be active");

    // Verify it's a child of the expected admin
    assertEq(hats.getHatLevel(hatId), hats.getHatLevel(expectedAdmin) + 1, "Hat should be child of admin");
  }

  /// @dev Helper to assert that a hat was toggled correctly
  /// @param hatId The hat ID to check
  /// @param toggle The expected toggle module
  /// @param active The expected hat status
  function _assertHatToggle(uint256 hatId, address toggle, bool active) internal view {
    (,,,, address toggle_,,,, bool active_) = hats.viewHat(hatId);
    assertEq(toggle_, toggle, "Hat toggle module mismatch");
    assertEq(active_, active, "Hat status mismatch");
  }

  /// @dev Helper to get proposal data as a struct
  /// @param proposalId The proposal ID to fetch
  /// @return data The proposal data struct
  function _getProposalData(bytes32 proposalId) internal view returns (IProposalHatterTypes.ProposalData memory data) {
    // Fetch in two calls to avoid stack depth issues
    (data.submitter, data.fundingAmount, data.state, data.fundingToken, data.eta, data.timelockSec,,,,,) =
      proposalHatter.proposals(proposalId);

    (,,,,,, data.safe, data.recipientHatId, data.approverHatId, data.reservedHatId, data.hatsMulticall) =
      proposalHatter.proposals(proposalId);
  }

  /// @dev Helper to assert proposal data matches expectations
  /// @param actual The actual proposal data
  /// @param expected The expected proposal data
  function _assertProposalData(
    IProposalHatterTypes.ProposalData memory actual,
    IProposalHatterTypes.ProposalData memory expected
  ) internal pure {
    assertEq(actual.submitter, expected.submitter, "Submitter mismatch");
    assertEq(actual.fundingAmount, expected.fundingAmount, "Funding amount mismatch");
    assertEq(uint8(actual.state), uint8(expected.state), "State mismatch");
    assertEq(actual.fundingToken, expected.fundingToken, "Funding token mismatch");
    assertEq(actual.eta, expected.eta, "ETA mismatch");
    assertEq(actual.timelockSec, expected.timelockSec, "Timelock mismatch");
    assertEq(actual.safe, expected.safe, "Safe mismatch");
    assertEq(actual.recipientHatId, expected.recipientHatId, "Recipient hat mismatch");
    assertEq(actual.approverHatId, expected.approverHatId, "Approver hat mismatch");
    assertEq(actual.reservedHatId, expected.reservedHatId, "Reserved hat mismatch");
    assertEq(actual.hatsMulticall, expected.hatsMulticall, "Hats multicall mismatch");
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

  /// @dev Helper to get a funding token by index for fuzz testing
  /// @param tokenSeed Seed to select token (will be modulo'd by array length)
  /// @return token The selected funding token address
  function _getFundingToken(uint256 tokenSeed) internal view returns (address token) {
    return FUNDING_TOKENS[tokenSeed % FUNDING_TOKENS.length];
  }

  /// @dev Helper to get a test actor by index for fuzz testing
  /// @param actorSeed Seed to select actor (will be modulo'd by array length)
  /// @return actor The selected test actor address
  function _getTestActor(uint256 actorSeed) internal view returns (address actor) {
    return TEST_ACTORS[actorSeed % TEST_ACTORS.length];
  }

  /// @dev Helper to get multiple distinct test actors for multi-actor tests
  /// @param seed1 Seed for first actor
  /// @param seed2 Seed for second actor
  /// @return actor1 First test actor
  /// @return actor2 Second test actor (guaranteed different from first)
  function _getTwoTestActors(uint256 seed1, uint256 seed2) internal view returns (address actor1, address actor2) {
    actor1 = _getTestActor(seed1);
    // Ensure actor2 is different from actor1
    actor2 = _getTestActor(seed2);
    if (actor1 == actor2) {
      actor2 = _getTestActor(seed2 + 1);
    }
  }

  /// @dev Helper to get a random subset of test actors
  /// @param count Number of actors to return (max 20)
  /// @param startSeed Starting seed for selection
  /// @return actors Array of distinct test actors
  function _getTestActors(uint256 count, uint256 startSeed) internal view returns (address[] memory actors) {
    require(count <= TEST_ACTORS.length, "Count exceeds available actors");

    actors = new address[](count);
    bool[] memory used = new bool[](TEST_ACTORS.length);

    for (uint256 i = 0; i < count; i++) {
      uint256 index = (startSeed + i) % TEST_ACTORS.length;
      // Find next unused actor
      while (used[index]) {
        index = (index + 1) % TEST_ACTORS.length;
      }
      used[index] = true;
      actors[i] = TEST_ACTORS[index];
    }
  }
}
