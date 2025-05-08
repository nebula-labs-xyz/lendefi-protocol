// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol"; // solhint-disable-line
import {USDC} from "../../contracts/mock/USDC.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {WETH9} from "../../contracts/vendor/canonical-weth/contracts/WETH9.sol";
import {ITREASURY} from "../../contracts/interfaces/ITreasury.sol";
import {IECOSYSTEM} from "../../contracts/interfaces/IEcosystem.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {Treasury} from "../../contracts/ecosystem/Treasury.sol";
import {TreasuryV2} from "../../contracts/upgrades/TreasuryV2.sol";
import {Ecosystem} from "../../contracts/ecosystem/Ecosystem.sol";
import {EcosystemV2} from "../../contracts/upgrades/EcosystemV2.sol";
import {GovernanceToken} from "../../contracts/ecosystem/GovernanceToken.sol";
import {GovernanceTokenV2} from "../../contracts/upgrades/GovernanceTokenV2.sol";
import {LendefiGovernor} from "../../contracts/ecosystem/LendefiGovernor.sol";
import {LendefiGovernorV2} from "../../contracts/upgrades/LendefiGovernorV2.sol";
import {InvestmentManager} from "../../contracts/ecosystem/InvestmentManager.sol";
import {InvestmentManagerV2} from "../../contracts/upgrades/InvestmentManagerV2.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DefenderOptions} from "openzeppelin-foundry-upgrades/Options.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockV2} from "../../contracts/upgrades/TimelockV2.sol";
import {TeamManager} from "../../contracts/ecosystem/TeamManager.sol";
import {TeamManagerV2} from "../../contracts/upgrades/TeamManagerV2.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {LendefiV2} from "../../contracts/upgrades/LendefiV2.sol";
import {LendefiYieldToken} from "../../contracts/lender/LendefiYieldToken.sol";
import {LendefiYieldTokenV2} from "../../contracts/upgrades/LendefiYieldTokenV2.sol";
import {LendefiAssets} from "../../contracts/lender/LendefiAssets.sol";
import {LendefiAssetsV2} from "../../contracts/upgrades/LendefiAssetsV2.sol";
import {LendefiPoRFactory} from "../../contracts/lender/LendefiPoRFactory.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

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
    address constant gnosisSafe = address(0x9999987);
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
    WETH9 internal wethInstance;
    Lendefi internal LendefiInstance;
    LendefiYieldToken internal yieldTokenInstance;
    LendefiAssets internal assetsInstance;
    //USDC internal usdcInstance;
    IERC20 usdcInstance = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); //real usdc ethereum for fork testing
    LendefiPoRFactory internal porFactoryInstance;

    function deployTokenUpgrade() internal {
        if (address(timelockInstance) == address(0)) {
            _deployTimelock();
        }

        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, address(timelockInstance)));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
        assertTrue(tokenInstance.hasRole(UPGRADER_ROLE, address(timelockInstance)) == true);

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "GovernanceToken.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("GovernanceTokenV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(address(timelockInstance));
        tokenInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        GovernanceTokenV2 instanceV2 = GovernanceTokenV2(proxy);
        assertEq(instanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == tokenImplementation, "Implementation address didn't change");
        assertTrue(instanceV2.hasRole(UPGRADER_ROLE, address(timelockInstance)) == true, "Lost UPGRADER_ROLE");
    }

    function deployEcosystemUpgrade() internal {
        vm.warp(365 days);
        _deployToken();
        _deployTimelock();

        // ecosystem deploy
        bytes memory data =
            abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), address(timelockInstance), gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", data));
        ecoInstance = Ecosystem(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(ecoInstance) == implAddressV1);

        // Verify gnosis multisig has the required role
        assertTrue(ecoInstance.hasRole(UPGRADER_ROLE, gnosisSafe), "Multisig should have UPGRADER_ROLE");

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "Ecosystem.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("EcosystemV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        ecoInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Ecosystem)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        EcosystemV2 ecoInstanceV2 = EcosystemV2(proxy);
        assertEq(ecoInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(ecoInstanceV2.hasRole(UPGRADER_ROLE, gnosisSafe), "Lost UPGRADER_ROLE");
    }

    function deployTreasuryUpgrade() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();

        // deploy Treasury
        uint256 startOffset = 180 days;
        uint256 vestingDuration = 3 * 365 days;

        bytes memory data =
            abi.encodeCall(Treasury.initialize, (address(timelockInstance), gnosisSafe, startOffset, vestingDuration));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Treasury.sol", data));
        treasuryInstance = Treasury(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(treasuryInstance) == implAddressV1);

        // Verify gnosis multisig has the required role
        assertTrue(treasuryInstance.hasRole(treasuryInstance.UPGRADER_ROLE(), gnosisSafe));

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "Treasury.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("TreasuryV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        treasuryInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Treasury)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        TreasuryV2 treasuryInstanceV2 = TreasuryV2(proxy);
        assertEq(treasuryInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(treasuryInstanceV2.hasRole(treasuryInstanceV2.UPGRADER_ROLE(), gnosisSafe), "Lost UPGRADER_ROLE");
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
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();

        // deploy Governor
        bytes memory data = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockInstance, gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data));
        govInstance = LendefiGovernor(proxy);
        address govImplAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(govInstance) == govImplAddressV1);
        assertEq(govInstance.uupsVersion(), 1);

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "LendefiGovernor.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("LendefiGovernorV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        govInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Governor)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address govImplAddressV2 = Upgrades.getImplementationAddress(proxy);
        LendefiGovernorV2 govInstanceV2 = LendefiGovernorV2(proxy);
        assertEq(govInstanceV2.uupsVersion(), 2, "Version not incremented to 2");
        assertFalse(govImplAddressV2 == govImplAddressV1, "Implementation address didn't change");
    }

    function deployIMUpgrade() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();
        _deployTreasury();

        // deploy Investment Manager
        bytes memory data = abi.encodeCall(
            InvestmentManager.initialize, (address(tokenInstance), address(timelockInstance), address(treasuryInstance))
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data));
        managerInstance = InvestmentManager(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(managerInstance) == implAddressV1);

        // Verify gnosis multisig has the required role
        assertTrue(
            managerInstance.hasRole(UPGRADER_ROLE, address(timelockInstance)), "Timelock should have UPGRADER_ROLE"
        );

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "InvestmentManager.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("InvestmentManagerV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(address(timelockInstance));
        managerInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for InvestmentManager)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        InvestmentManagerV2 imInstanceV2 = InvestmentManagerV2(proxy);
        assertEq(imInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(imInstanceV2.hasRole(UPGRADER_ROLE, address(timelockInstance)), "Lost UPGRADER_ROLE");
    }

    function deployTeamManagerUpgrade() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();

        // deploy Team Manager with gnosisSafe as the upgrader role
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implAddressV1);
        assertTrue(tmInstance.hasRole(UPGRADER_ROLE, gnosisSafe) == true);

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "TeamManager.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("TeamManagerV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        tmInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for TeamManager)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        TeamManagerV2 tmInstanceV2 = TeamManagerV2(proxy);
        assertEq(tmInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(tmInstanceV2.hasRole(UPGRADER_ROLE, gnosisSafe) == true, "Lost UPGRADER_ROLE");
    }

    function deployComplete() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();
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
        if (address(timelockInstance) == address(0)) {
            _deployTimelock();
        }
        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, address(timelockInstance)));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
    }

    function _deployEcosystem() internal {
        // ecosystem deploy
        bytes memory data =
            abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), address(timelockInstance), gnosisSafe));
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
        bytes memory data = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockInstance, gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data));
        govInstance = LendefiGovernor(proxy);
        address govImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(govInstance) == govImplementation);
        assertEq(govInstance.uupsVersion(), 1);
    }

    function _deployTreasury() internal {
        // deploy Treasury
        uint256 startOffset = 180 days;
        uint256 vestingDuration = 3 * 365 days;
        bytes memory data =
            abi.encodeCall(Treasury.initialize, (address(timelockInstance), gnosisSafe, startOffset, vestingDuration));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Treasury.sol", data));
        treasuryInstance = Treasury(proxy);
        address implAddress = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(treasuryInstance) == implAddress);
    }

    function _deployInvestmentManager() internal {
        // deploy Investment Manager
        bytes memory data = abi.encodeCall(
            InvestmentManager.initialize, (address(tokenInstance), address(timelockInstance), address(treasuryInstance))
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data));
        managerInstance = InvestmentManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(managerInstance) == implementation);
    }

    function _deployTeamManager() internal {
        // deploy Team Manager
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), gnosisSafe));
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
     * @dev Initializes with proper role assignment for protocol, timelock, guardian, and multisig
     */
    function _deployYieldToken() internal {
        // Make sure USDC is deployed first and is valid
        if (address(usdcInstance) == address(0)) {
            usdcInstance = new USDC();
        }

        // Deploy LendefiYieldToken
        if (address(timelockInstance) == address(0)) {
            _deployTimelock();
        }

        // Use more explicit parameter encoding to avoid confusion
        bytes memory data = abi.encodeCall(
            LendefiYieldToken.initialize,
            (address(ethereum), address(timelockInstance), address(gnosisSafe), address(usdcInstance))
        );

        // Debug output to verify addresses
        console2.log("Protocol address:", address(ethereum));
        console2.log("Timelock address:", address(timelockInstance));
        console2.log("Gnosis address:", gnosisSafe);
        console2.log("USDC address:", address(usdcInstance));

        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiYieldToken.sol", data));
        yieldTokenInstance = LendefiYieldToken(proxy);

        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(yieldTokenInstance) == implementation);

        // Verify roles are properly assigned
        assertTrue(yieldTokenInstance.hasRole(PAUSER_ROLE, gnosisSafe));
        assertTrue(yieldTokenInstance.hasRole(UPGRADER_ROLE, gnosisSafe));
        assertTrue(yieldTokenInstance.hasRole(PROTOCOL_ROLE, address(ethereum)));
        assertTrue(yieldTokenInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)));
    }

    /**
     * @notice Upgrades the LendefiYieldToken implementation using timelocked pattern
     * @dev Uses the two-phase upgrade process: schedule → wait → execute
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

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "LendefiYieldToken.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("LendefiYieldTokenV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        yieldTokenInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for YieldToken)
        vm.warp(block.timestamp + 3 days + 1);

        // Execute the upgrade
        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        LendefiYieldTokenV2 yieldTokenInstanceV2 = LendefiYieldTokenV2(proxy);

        // Assert that upgrade was successful
        assertEq(yieldTokenInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(yieldTokenInstanceV2.hasRole(UPGRADER_ROLE, gnosisSafe), "Lost UPGRADER_ROLE");
    }

    /**
     * @notice Deploys the combined LendefiAssetOracle contract
     * @dev Replaces the separate Oracle and Assets modules with the combined contract
     */
    function _deployAssetsModule() internal {
        if (address(timelockInstance) == address(0)) {
            _deployTimelock();
        }
        // Protocol Oracle deploy (combined Oracle + Assets)
        bytes memory data =
            abi.encodeCall(LendefiAssets.initialize, (address(timelockInstance), gnosisSafe, address(usdcInstance)));

        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", data));

        // Store the instance in both variables to maintain compatibility with existing tests
        assetsInstance = LendefiAssets(proxy);

        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(assetsInstance) == implementation);
    }
    /**
     * @notice Upgrades the LendefiAssets implementation
     * @dev Follows the same pattern as other module upgrades
     */

    /**
     * @notice Upgrades the LendefiAssets implementation using timelocked pattern
     * @dev Uses the two-phase upgrade process: schedule → wait → execute
     */
    function deployAssetsModuleUpgrade() internal {
        // First make sure the assets module is deployed
        if (address(assetsInstance) == address(0)) {
            _deployAssetsModule();
        }

        // Get the proxy address
        address payable proxy = payable(address(assetsInstance));

        // Get the current implementation address for assertion later
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "LendefiAssets.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("LendefiAssetsV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        assetsInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Assets)
        vm.warp(block.timestamp + 3 days + 1);

        // Execute the upgrade
        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        LendefiAssetsV2 assetsInstanceV2 = LendefiAssetsV2(proxy);

        // Assert that upgrade was successful
        assertEq(assetsInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(assetsInstanceV2.hasRole(UPGRADER_ROLE, gnosisSafe), "Lost UPGRADER_ROLE");

        // Test role management still works
        vm.startPrank(address(timelockInstance));
        assetsInstanceV2.revokeRole(UPGRADER_ROLE, gnosisSafe);
        assertFalse(assetsInstanceV2.hasRole(UPGRADER_ROLE, gnosisSafe), "Role should be revoked successfully");
        assetsInstance.grantRole(UPGRADER_ROLE, gnosisSafe);
        assertTrue(assetsInstanceV2.hasRole(UPGRADER_ROLE, gnosisSafe), "Lost UPGRADER_ROLE");
        vm.stopPrank();
    }

    /**
     * @notice Deploys the Lendefi contract with the combined protocol oracle
     * @dev This function is called internally and should not be used directly
     */
    function _deployLendefiModules() internal {
        // First deploy combined protocol oracle if not already deployed
        if (address(assetsInstance) == address(0)) {
            _deployAssetsModule();
        }

        // Deploy mock USDC if needed
        if (address(usdcInstance) == address(0)) {
            usdcInstance = new USDC();
        }
        // Then deploy the yield token with proper initialization parameters
        bytes memory tokenData = abi.encodeCall(
            LendefiYieldToken.initialize,
            (address(ethereum), address(timelockInstance), gnosisSafe, address(usdcInstance))
        );

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
                gnosisSafe
            )
        );

        address payable lendingProxy = payable(Upgrades.deployUUPSProxy("Lendefi.sol", lendingData));
        LendefiInstance = Lendefi(lendingProxy);

        // Deploy and configure PoR factory after Lendefi is deployed
        _deployPoRFactory();

        // Update the protocol role in the yield token to point to the real Lendefi address
        vm.startPrank(address(timelockInstance));
        yieldTokenInstance.revokeRole(PROTOCOL_ROLE, address(ethereum));
        yieldTokenInstance.grantRole(PROTOCOL_ROLE, address(LendefiInstance));
        vm.stopPrank();

        // Update the core address in the protocol oracle to point to the real Lendefi address
        vm.startPrank(address(timelockInstance));
        assetsInstance.setCoreAddress(address(LendefiInstance));
        assetsInstance.grantRole(CORE_ROLE, address(LendefiInstance));
        vm.stopPrank();
    }

    /**
     * @notice Modify deployCompleteWithOracle to use the combined protocol oracle
     */
    function deployCompleteWithOracle() internal {
        vm.warp(365 days);
        // Deploy mock tokens for testing
        if (address(usdcInstance) == address(0)) {
            usdcInstance = new USDC();
        }
        _deployTimelock();
        _deployToken();
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

    /**
     * @notice Deploys and initializes the Proof of Reserve factory
     * @dev Uses the real implementation, not a mock
     */
    function _deployPoRFactory() internal {
        // Deploy PoR factory using UUPS pattern
        bytes memory data = abi.encodeCall(
            LendefiPoRFactory.initialize, (address(LendefiInstance), address(assetsInstance), gnosisSafe)
        );

        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiPoRFactory.sol", data));
        porFactoryInstance = LendefiPoRFactory(proxy);

        // Set factory in assets module
        vm.startPrank(address(timelockInstance));
        assetsInstance.setPoRFactory(address(porFactoryInstance));
        vm.stopPrank();
    }
}
