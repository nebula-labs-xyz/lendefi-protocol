// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol"; // solhint-disable-line
import {IPROTOCOL} from "../contracts/interfaces/IProtocol.sol";
import {USDC} from "../contracts/mock/USDC.sol";
import {WETHPriceConsumerV3} from "../contracts/mock/WETHOracle.sol";
import {WETH9} from "../contracts/vendor/canonical-weth/contracts/WETH9.sol";
import {ITREASURY} from "../contracts/interfaces/ITreasury.sol";
import {IECOSYSTEM} from "../contracts/interfaces/IEcosystem.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treasury} from "../contracts/ecosystem/Treasury.sol";
import {TreasuryV2} from "../contracts/upgrades/TreasuryV2.sol";
import {Ecosystem} from "../contracts/ecosystem/Ecosystem.sol";
import {EcosystemV2} from "../contracts/upgrades/EcosystemV2.sol";
import {GovernanceToken} from "../contracts/ecosystem/GovernanceToken.sol";
import {GovernanceTokenV2} from "../contracts/upgrades/GovernanceTokenV2.sol";
import {LendefiGovernor} from "../contracts/ecosystem/LendefiGovernor.sol";
import {LendefiGovernorV2} from "../contracts/upgrades/LendefiGovernorV2.sol";
import {InvestmentManager} from "../contracts/ecosystem/InvestmentManager.sol";
import {InvestmentManagerV2} from "../contracts/upgrades/InvestmentManagerV2.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockV2} from "../contracts/upgrades/TimelockV2.sol";
import {TeamManager} from "../contracts/ecosystem/TeamManager.sol";
import {TeamManagerV2} from "../contracts/upgrades/TeamManagerV2.sol";
import {Lendefi} from "../contracts/lender/Lendefi.sol";
import {LendefiV2} from "../contracts/upgrades/LendefiV2.sol";
import {LendefiYieldToken} from "../contracts/lender/LendefiYieldToken.sol";
import {LendefiYieldTokenV2} from "../contracts/upgrades/LendefiYieldTokenV2.sol";
import {LendefiAssets} from "../contracts/lender/LendefiAssets.sol";
import {LendefiAssetsV2} from "../contracts/upgrades/LendefiAssetsV2.sol";
import {IASSETS} from "../contracts/interfaces/IASSETS.sol";

contract BasicDeploy is Test {
    event Upgrade(address indexed src, address indexed implementation);

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant CIRCUIT_BREAKER_ROLE = keccak256("CIRCUIT_BREAKER_ROLE");
    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant PROTOCOL_ROLE = keccak256("PROTOCOL_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 internal constant CORE_ROLE = keccak256("CORE_ROLE");
    bytes32 internal constant DAO_ROLE = keccak256("DAO_ROLE");

    uint256 constant INIT_BALANCE_USDC = 100_000_000e6;
    uint256 constant INITIAL_SUPPLY = 50_000_000 ether;
    address constant ethereum = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant usdcWhale = 0x0A59649758aa4d66E25f08Dd01271e891fe52199;
    address constant bridge = address(0x9999988);
    address constant partner = address(0x9999989);
    address constant guardian = address(0x9999990);
    address constant alice = address(0x9999991);
    address constant bob = address(0x9999992);
    address constant charlie = address(0x9999993);
    address constant registryAdmin = address(0x9999994);
    address constant managerAdmin = address(0x9999995);
    address constant pauser = address(0x9999996);
    address constant assetSender = address(0x9999997);
    address constant assetRecipient = address(0x9999998);
    address constant feeRecipient = address(0x9999999);
    address constant liquidator = address(0x3); // Add liquidator
    address[] users;

    GovernanceToken internal tokenInstance;
    Ecosystem internal ecoInstance;
    TimelockControllerUpgradeable internal timelockInstance;
    LendefiGovernor internal govInstance;
    Treasury internal treasuryInstance;
    InvestmentManager internal managerInstance;
    TeamManager internal tmInstance;
    USDC internal usdcInstance; // mock usdc
    WETH9 internal wethInstance;
    Lendefi internal LendefiInstance;
    LendefiYieldToken internal yieldTokenInstance;
    LendefiAssets internal assetsInstance;
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    function deployTokenUpgrade() internal {
        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);

        // upgrade token
        vm.prank(guardian);
        tokenInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        vm.startPrank(managerAdmin);
        Upgrades.upgradeProxy(proxy, "GovernanceTokenV2.sol", "", guardian);
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        GovernanceTokenV2 instanceV2 = GovernanceTokenV2(proxy);
        assertEq(instanceV2.version(), 2);
        assertFalse(implAddressV2 == tokenImplementation);

        bool isUpgrader = instanceV2.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader == true);

        vm.prank(guardian);
        instanceV2.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(instanceV2.hasRole(UPGRADER_ROLE, managerAdmin) == true);
    }

    function deployEcosystemUpgrade() internal {
        _deployToken();
        _deployTimelock();

        // ecosystem deploy
        bytes memory data1 =
            abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), address(timelockInstance), guardian, pauser));
        address payable proxy1 = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", data1));
        ecoInstance = Ecosystem(proxy1);
        address ecoImplementation = Upgrades.getImplementationAddress(proxy1);
        assertFalse(address(ecoInstance) == ecoImplementation);

        // upgrade Ecosystem
        vm.prank(guardian);
        ecoInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        vm.startPrank(managerAdmin);
        Upgrades.upgradeProxy(proxy1, "EcosystemV2.sol", "", guardian);
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy1);
        EcosystemV2 ecoInstanceV2 = EcosystemV2(proxy1);
        assertEq(ecoInstanceV2.version(), 2);
        assertFalse(implAddressV2 == ecoImplementation);

        bool isUpgrader = ecoInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader == true);

        vm.prank(guardian);
        ecoInstanceV2.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(ecoInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin) == true);
    }

    function deployTreasuryUpgrade() internal {
        vm.warp(365 days);

        _deployToken();
        _deployTimelock();

        //deploy Treasury
        bytes memory data1 = abi.encodeCall(Treasury.initialize, (guardian, address(timelockInstance)));
        address payable proxy1 = payable(Upgrades.deployUUPSProxy("Treasury.sol", data1));
        treasuryInstance = Treasury(proxy1);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy1);
        assertFalse(address(treasuryInstance) == implAddressV1);

        // upgrade Treasury
        vm.prank(guardian);
        treasuryInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        vm.startPrank(managerAdmin);
        Upgrades.upgradeProxy(proxy1, "TreasuryV2.sol", "", guardian);
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy1);
        TreasuryV2 treasuryInstanceV2 = TreasuryV2(proxy1);
        assertEq(treasuryInstanceV2.version(), 2);
        assertFalse(implAddressV2 == implAddressV1);

        bool isUpgrader = treasuryInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader == true);

        vm.prank(guardian);
        treasuryInstanceV2.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(treasuryInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin) == true);
    }

    function deployTimelockUpgrade() internal {
        // timelock deploy
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = ethereum;

        TimelockControllerUpgradeable implementation = new TimelockControllerUpgradeable();
        bytes memory initData = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, timelockDelay, temp, temp, guardian
        );
        ERC1967Proxy proxy1 = new ERC1967Proxy(address(implementation), initData);

        timelockInstance = TimelockControllerUpgradeable(payable(address(proxy1)));

        // deploy Timelock Upgrade, ERC1967Proxy
        TimelockV2 newImplementation = new TimelockV2();
        bytes memory initData2 = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, timelockDelay, temp, temp, guardian
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(newImplementation), initData2);
        timelockInstance = TimelockControllerUpgradeable(payable(address(proxy2)));
    }

    function deployGovernorUpgrade() internal {
        _deployToken();
        _deployTimelock();

        // deploy Governor
        bytes memory data2 = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockInstance, guardian));
        address payable proxy2 = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data2));
        LendefiGovernor govInstanceV1 = LendefiGovernor(proxy2);
        address govImplAddressV1 = Upgrades.getImplementationAddress(proxy2);
        assertFalse(address(govInstanceV1) == govImplAddressV1);
        assertEq(govInstanceV1.uupsVersion(), 1);

        // upgrade Governor
        Upgrades.upgradeProxy(proxy2, "LendefiGovernorV2.sol", "", guardian);
        address govImplAddressV2 = Upgrades.getImplementationAddress(proxy2);

        LendefiGovernorV2 govInstanceV2 = LendefiGovernorV2(proxy2);
        assertEq(govInstanceV2.uupsVersion(), 2);
        assertFalse(govImplAddressV2 == govImplAddressV1);
    }

    function deployIMUpgrade() internal {
        vm.warp(365 days);

        _deployToken();
        _deployTimelock();
        _deployTreasury();

        // deploy Investment Manager
        bytes memory data4 = abi.encodeCall(
            InvestmentManager.initialize,
            (address(tokenInstance), address(timelockInstance), address(treasuryInstance), guardian)
        );
        address payable proxy4 = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data4));
        managerInstance = InvestmentManager(proxy4);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy4);
        assertFalse(address(managerInstance) == implAddressV1);

        // upgrade InvestmentManager
        vm.prank(guardian);
        managerInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        vm.startPrank(managerAdmin);
        Upgrades.upgradeProxy(proxy4, "InvestmentManagerV2.sol:InvestmentManagerV2", "", guardian);
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy4);
        InvestmentManagerV2 imInstanceV2 = InvestmentManagerV2(proxy4);
        assertEq(imInstanceV2.version(), 2);
        assertFalse(implAddressV2 == implAddressV1);

        bool isUpgrader = imInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader == true);

        vm.prank(guardian);
        imInstanceV2.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(imInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin) == true);
    }

    function deployTeamManagerUpgrade() internal {
        vm.warp(365 days);

        deployComplete();

        // deploy Team Manager
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implAddressV1);

        // upgrade Team Manager
        vm.prank(guardian);
        tmInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        vm.startPrank(managerAdmin);
        Upgrades.upgradeProxy(proxy, "TeamManagerV2.sol:TeamManagerV2", "", guardian);
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        TeamManagerV2 tmInstanceV2 = TeamManagerV2(proxy);
        assertEq(tmInstanceV2.version(), 2);
        assertFalse(implAddressV2 == implAddressV1);

        bool isUpgrader = tmInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader == true);

        vm.prank(guardian);
        tmInstanceV2.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(tmInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin) == true);
    }

    function deployComplete() internal {
        vm.warp(365 days);
        usdcInstance = new USDC();
        _deployToken();
        _deployTimelock();
        _deployEcosystem();
        _deployGovernor();

        // reset timelock proposers and executors
        vm.startPrank(guardian);
        timelockInstance.revokeRole(PROPOSER_ROLE, ethereum);
        timelockInstance.revokeRole(EXECUTOR_ROLE, ethereum);
        timelockInstance.revokeRole(CANCELLER_ROLE, ethereum);
        timelockInstance.grantRole(PROPOSER_ROLE, address(govInstance));
        timelockInstance.grantRole(EXECUTOR_ROLE, address(govInstance));
        timelockInstance.grantRole(CANCELLER_ROLE, address(govInstance));
        vm.stopPrank();

        //deploy Treasury
        _deployTreasury();
    }

    function _deployToken() internal {
        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
    }

    function _deployEcosystem() internal {
        // ecosystem deploy
        bytes memory data =
            abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), address(timelockInstance), guardian, pauser));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", data));
        ecoInstance = Ecosystem(proxy);
        address ecoImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(ecoInstance) == ecoImplementation);
    }

    function _deployTimelock() internal {
        // timelock deploy
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = ethereum;
        TimelockControllerUpgradeable timelock = new TimelockControllerUpgradeable();

        bytes memory initData = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, timelockDelay, temp, temp, guardian
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(timelock), initData);
        timelockInstance = TimelockControllerUpgradeable(payable(address(proxy)));
    }

    function _deployGovernor() internal {
        // deploy Governor
        bytes memory data = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockInstance, guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data));
        govInstance = LendefiGovernor(proxy);
        address govImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(govInstance) == govImplementation);
        assertEq(govInstance.uupsVersion(), 1);
    }

    function _deployTreasury() internal {
        // deploy Treasury
        bytes memory data = abi.encodeCall(Treasury.initialize, (guardian, address(timelockInstance)));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Treasury.sol", data));
        treasuryInstance = Treasury(proxy);
        address implAddress = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(treasuryInstance) == implAddress);
    }

    function _deployInvestmentManager() internal {
        // deploy Investment Manager
        bytes memory data = abi.encodeCall(
            InvestmentManager.initialize,
            (address(tokenInstance), address(timelockInstance), address(treasuryInstance), guardian)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data));
        managerInstance = InvestmentManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(managerInstance) == implementation);
    }

    function _deployTeamManager() internal {
        // deploy Team Manager
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implementation);
    }

    function _deployLendefi() internal {
        // Make sure oracle is deployed first
        if (address(assetsInstance) == address(0)) {
            _deployAssetsModule();
        }

        // Now deploy Lendefi with oracle address
        bytes memory data = abi.encodeCall(
            Lendefi.initialize,
            (
                address(usdcInstance),
                address(tokenInstance),
                address(ecoInstance),
                address(treasuryInstance),
                address(timelockInstance),
                address(yieldTokenInstance),
                address(assetsInstance),
                guardian
            )
        );

        address payable proxy = payable(Upgrades.deployUUPSProxy("Lendefi.sol", data));
        LendefiInstance = Lendefi(proxy);

        address lendingImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(LendefiInstance) == lendingImplementation);
    }

    /**
     * @notice Deploys the LendefiYieldToken contract
     * @dev Follows the same pattern as other internal deploy functions
     */
    function _deployYieldToken() internal {
        // Deploy LendefiYieldToken
        bytes memory data = abi.encodeCall(LendefiYieldToken.initialize, (address(ethereum), guardian));

        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiYieldToken.sol", data));
        yieldTokenInstance = LendefiYieldToken(proxy);

        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(yieldTokenInstance) == implementation);
    }

    /**
     * @notice Upgrades the LendefiYieldToken implementation
     * @dev For future use when yield token needs to be upgraded
     */
    function deployYieldTokenUpgrade() internal {
        // First make sure the token is deployed
        if (address(yieldTokenInstance) == address(0)) {
            _deployYieldToken();
        }

        // Get the proxy address
        address payable proxy = payable(address(yieldTokenInstance));

        // Get the current implementation address for assertion later
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);

        // Grant upgrader role to manager admin
        vm.prank(guardian);
        yieldTokenInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        // Perform the upgrade
        vm.startPrank(managerAdmin);
        // Note: You'll need to create a V2 version when needed
        Upgrades.upgradeProxy(proxy, "LendefiYieldTokenV2.sol", "", guardian);
        vm.stopPrank();

        // Verify the upgrade
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        assertFalse(implAddressV2 == implAddressV1);

        // Check version
        assertEq(yieldTokenInstance.version(), 2);
    }

    /**
     * @notice Deploys the combined LendefiAssetOracle contract
     * @dev Replaces the separate Oracle and Assets modules with the combined contract
     */
    function _deployAssetsModule() internal {
        // Protocol Oracle deploy (combined Oracle + Assets)
        bytes memory data = abi.encodeCall(LendefiAssets.initialize, (address(timelockInstance), guardian));

        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", data));

        // Store the instance in both variables to maintain compatibility with existing tests
        assetsInstance = LendefiAssets(proxy);

        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(assetsInstance) == implementation);

        // Grant necessary roles
        vm.startPrank(guardian);
        assetsInstance.grantRole(MANAGER_ROLE, address(timelockInstance));
        assetsInstance.grantRole(CIRCUIT_BREAKER_ROLE, address(timelockInstance));
        assetsInstance.grantRole(PAUSER_ROLE, guardian);
        vm.stopPrank();
    }
    /**
     * @notice Upgrades the LendefiAssets implementation
     * @dev Follows the same pattern as other module upgrades
     */

    function deployAssetsModuleUpgrade() internal {
        // First make sure the assets module is deployed
        _deployTimelock();
        bytes memory data = abi.encodeCall(LendefiAssets.initialize, (address(timelockInstance), guardian));

        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", data));

        // Store the instance in both variables to maintain compatibility with existing tests
        assetsInstance = LendefiAssets(proxy);

        // Get the current implementation address for assertion later
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(assetsInstance) == implAddressV1);

        // Grant upgrader role to manager admin
        vm.startPrank(guardian);
        assetsInstance.grantRole(UPGRADER_ROLE, managerAdmin);
        vm.stopPrank();

        // Perform the upgrade
        vm.startPrank(managerAdmin);
        // Assuming LendefiAssetsV2 exists in the upgrades folder
        Upgrades.upgradeProxy(proxy, "LendefiAssetsV2.sol", "", guardian);
        vm.stopPrank();

        // Verify the upgrade
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        assertFalse(implAddressV2 == implAddressV1, "Implementation should change after upgrade");

        // Check version - assuming V2 has a version() function that returns 2
        assertEq(LendefiAssetsV2(address(assetsInstance)).version(), 2, "Version should be updated to 2");

        // Verify role management works
        bool isUpgrader = assetsInstance.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader, "Manager admin should have upgrader role");

        vm.prank(guardian);
        assetsInstance.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(assetsInstance.hasRole(UPGRADER_ROLE, managerAdmin), "Role should be revoked successfully");
    }
    /**
     * @notice Updates the _deployLendefiModules function to use the combined protocol oracle
     */

    function _deployLendefiModules() internal {
        // First deploy combined protocol oracle if not already deployed
        if (address(assetsInstance) == address(0)) {
            _deployAssetsModule();
        }

        // Then deploy the yield token with address(1) as a placeholder for Lendefi
        bytes memory tokenData = abi.encodeCall(LendefiYieldToken.initialize, (address(ethereum), guardian));

        address payable tokenProxy = payable(Upgrades.deployUUPSProxy("LendefiYieldToken.sol", tokenData));
        yieldTokenInstance = LendefiYieldToken(tokenProxy);

        // Deploy Lendefi with the combined protocol oracle
        bytes memory lendingData = abi.encodeCall(
            Lendefi.initialize,
            (
                address(usdcInstance),
                address(tokenInstance),
                address(ecoInstance),
                address(treasuryInstance),
                address(timelockInstance),
                address(yieldTokenInstance),
                address(assetsInstance), // Use the combined contract for asset management
                guardian
            )
        );

        address payable lendingProxy = payable(Upgrades.deployUUPSProxy("Lendefi.sol", lendingData));
        LendefiInstance = Lendefi(lendingProxy);

        // Update the protocol role in the yield token to point to the real Lendefi address
        vm.startPrank(address(guardian));
        yieldTokenInstance.revokeRole(PROTOCOL_ROLE, address(ethereum));
        yieldTokenInstance.grantRole(PROTOCOL_ROLE, address(LendefiInstance));
        yieldTokenInstance.grantRole(DEFAULT_ADMIN_ROLE, address(timelockInstance));
        yieldTokenInstance.renounceRole(DEFAULT_ADMIN_ROLE, address(guardian));

        // Update the core address in the protocol oracle to point to the real Lendefi address
        assetsInstance.setCoreAddress(address(LendefiInstance));
        assetsInstance.grantRole(CORE_ROLE, address(LendefiInstance));
        assetsInstance.grantRole(DEFAULT_ADMIN_ROLE, address(timelockInstance));
        assetsInstance.renounceRole(DEFAULT_ADMIN_ROLE, address(guardian));

        vm.stopPrank();
    }

    /**
     * @notice Modify deployCompleteWithOracle to use the combined protocol oracle
     */
    function deployCompleteWithOracle() internal {
        vm.warp(365 days);
        // Deploy mock tokens for testing
        usdcInstance = new USDC();
        _deployToken();
        _deployTimelock();
        _deployEcosystem();
        _deployTreasury();
        _deployGovernor();
        _deployAssetsModule();
        _deployLendefiModules();

        // Setup roles
        vm.startPrank(guardian);
        timelockInstance.revokeRole(PROPOSER_ROLE, ethereum);
        timelockInstance.revokeRole(EXECUTOR_ROLE, ethereum);
        timelockInstance.revokeRole(CANCELLER_ROLE, ethereum);
        timelockInstance.grantRole(PROPOSER_ROLE, address(govInstance));
        timelockInstance.grantRole(EXECUTOR_ROLE, address(govInstance));
        timelockInstance.grantRole(CANCELLER_ROLE, address(govInstance));
        vm.stopPrank();
    }
}
