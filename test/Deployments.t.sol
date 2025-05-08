// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./BasicDeploy.sol"; // solhint-disable-line

contract BasicDeployTest is BasicDeploy {
    function test_001_TokenDeploy() public {
        deployTokenUpgrade();
    }

    function test_002_EcosystemDeploy() public {
        deployEcosystemUpgrade();
    }

    function test_003_TreasuryDeploy() public {
        deployTreasuryUpgrade();
    }

    function test_004_TimelockDeploy() public {
        deployTimelockUpgrade();
    }

    function test_005_GovernorDeploy() public {
        deployGovernorUpgrade();
    }

    function test_006_CompleteDeploy() public {
        deployComplete();
        console2.log("token:    ", address(tokenInstance));
        console2.log("ecosystem:", address(ecoInstance));
        console2.log("treasury: ", address(treasuryInstance));
        console2.log("governor: ", address(govInstance));
        console2.log("timelock: ", address(timelockInstance));
    }

    function test_007_InvestmentManagerDeploy() public {
        deployComplete();
        _deployInvestmentManager();

        assertFalse(
            address(managerInstance) == Upgrades.getImplementationAddress(address(managerInstance)),
            "Implementation should be different from proxy"
        );
    }

    function test_008_DeployIMUpgrade() public {
        deployIMUpgrade();
    }

    function test_009_TGE() public {
        deployComplete();
        assertEq(tokenInstance.totalSupply(), 0);
        // this is the TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));
        uint256 guardianBal = tokenInstance.balanceOf(guardian);

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 27_400_000 ether);
        assertEq(guardianBal, 600_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal + guardianBal);
    }

    function test_010_deployTeamManager() public {
        deployComplete();
        _deployTeamManager();
    }

    function test_011_deployTeamManagerUpgrade() public {
        deployTeamManagerUpgrade();
    }

    function test_013_deployYieldToken() public {
        deployComplete();
        _deployYieldToken();

        // Verify YieldToken deployment
        assertFalse(
            address(yieldTokenInstance) == Upgrades.getImplementationAddress(address(yieldTokenInstance)),
            "Implementation should be different from proxy"
        );

        // Test YieldToken functionality
        assertTrue(yieldTokenInstance.hasRole(PAUSER_ROLE, gnosisSafe), "Guardian should have PAUSER_ROLE");
    }

    function test_014_deployYieldTokenUpgrade() public {
        deployYieldTokenUpgrade();

        // Check version after upgrade
        assertEq(yieldTokenInstance.version(), 2, "Version should be 2 after upgrade");
    }

    function test_015_deployLendefiModules() public {
        deployComplete();
        // _deployOracle();
        _deployLendefiModules();

        // Verify deployments
        assertFalse(
            address(yieldTokenInstance) == Upgrades.getImplementationAddress(address(yieldTokenInstance)),
            "YieldToken implementation should be different from proxy"
        );

        assertFalse(
            address(LendefiInstance) == Upgrades.getImplementationAddress(address(LendefiInstance)),
            "Lendefi implementation should be different from proxy"
        );

        // Check YieldToken grants protocol role to Lendefi
        assertTrue(
            yieldTokenInstance.hasRole(PROTOCOL_ROLE, address(LendefiInstance)),
            "Lendefi should have PROTOCOL_ROLE on YieldToken"
        );
    }

    function test_016_deployCompleteWithOracle() public {
        deployCompleteWithOracle();

        // Verify all components are deployed
        assertTrue(address(tokenInstance) != address(0), "Token should be deployed");
        assertTrue(address(ecoInstance) != address(0), "Ecosystem should be deployed");
        assertTrue(address(treasuryInstance) != address(0), "Treasury should be deployed");
        assertTrue(address(govInstance) != address(0), "Governor should be deployed");
        assertTrue(address(timelockInstance) != address(0), "Timelock should be deployed");
        assertTrue(address(assetsInstance) != address(0), "Oracle should be deployed");
        assertTrue(address(yieldTokenInstance) != address(0), "YieldToken should be deployed");
        assertTrue(address(LendefiInstance) != address(0), "Lendefi should be deployed");
        assertTrue(address(usdcInstance) != address(0), "USDC mock should be deployed");
        assertTrue(address(vaultFactoryInstance) != address(0), "Vault Factory mock should be deployed");
        assertTrue(address(porFactoryInstance) != address(0), "PoR Factory mock should be deployed");

        // Log addresses for reference
        console2.log("===== Complete System Deployment =====");
        console2.log("GovToken:     ", address(tokenInstance));
        console2.log("Ecosystem:    ", address(ecoInstance));
        console2.log("Treasury:     ", address(treasuryInstance));
        console2.log("Governor:     ", address(govInstance));
        console2.log("Timelock:     ", address(timelockInstance));
        console2.log("Assets:       ", address(assetsInstance));
        console2.log("YieldToken:   ", address(yieldTokenInstance));
        console2.log("Lendefi:      ", address(LendefiInstance));
        console2.log("VaultFactory: ", address(vaultFactoryInstance));
        console2.log("PoRFactory:   ", address(porFactoryInstance));
        console2.log("USDC:         ", address(usdcInstance));
    }

    function test_017_LendefiAndYieldTokenIntegration() public {
        // Deploy the complete system
        deployCompleteWithOracle();

        // Test mint function access control
        vm.prank(address(LendefiInstance));
        yieldTokenInstance.mint(alice, 100 ether);
        assertEq(yieldTokenInstance.balanceOf(alice), 100 ether, "Mint from Lendefi should work");

        // Test unauthorized access to mint
        vm.startPrank(alice);
        vm.expectRevert(); // Should revert due to missing PROTOCOL_ROLE
        yieldTokenInstance.mint(alice, 100 ether);
        vm.stopPrank();

        // Test burn function
        vm.prank(address(LendefiInstance));
        yieldTokenInstance.burn(alice, 50 ether);
        assertEq(yieldTokenInstance.balanceOf(alice), 50 ether, "Burn from Lendefi should work");
    }

    function test_018_deployAssetsModuleUpgrade() public {
        deployAssetsModuleUpgrade();

        // Check version after upgrade
        assertEq(assetsInstance.version(), 2, "Version should be 2 after upgrade");
    }

    function test_019_deployVaultFactory() public {
        deployCompleteWithOracle();

        // Verify VaultFactory deployment
        assertEq(
            vaultFactoryInstance.protocol(),
            address(LendefiInstance),
            "VaultFactory should be linked to Lendefi protocol"
        );

        // Test creating a vault
        vm.startPrank(address(LendefiInstance));
        address vaultAddress = vaultFactoryInstance.createVault(alice, 1);
        vm.stopPrank();

        // Verify vault was created and registered
        assertNotEq(vaultAddress, address(0), "Vault should be deployed");
        assertEq(vaultFactoryInstance.getVault(alice, 1), vaultAddress, "Vault should be registered");
    }
}
