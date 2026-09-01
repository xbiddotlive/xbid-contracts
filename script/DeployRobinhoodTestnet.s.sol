// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script} from "solady/test/utils/forge-std/Script.sol";
import {FeeVault} from "../src/core/FeeVault.sol";
import {MarketRegistry} from "../src/core/MarketRegistry.sol";
import {MarketVault} from "../src/core/MarketVault.sol";
import {RiskController} from "../src/core/RiskController.sol";
import {SideToken} from "../src/core/SideToken.sol";
import {XBIDFactory} from "../src/core/XBIDFactory.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";

/// @notice Deploys XBID on Robinhood Chain Testnet in a safe pre-activation state.
/// @dev Governance must later atomically execute the two activation calldata
///      entries written to the manifest. No private key is written to disk.
contract DeployRobinhoodTestnet is Script {
    struct Deployment {
        MarketRegistry registry;
        RiskController riskController;
        FeeVault feeVault;
        MarketVault marketImplementation;
        SideToken sideTokenImplementation;
        XBIDFactory factoryImplementation;
        XBIDFactory factory;
    }

    error DeployerMustDifferFromGovernance(address account);
    error InvalidSourceCommit();
    error UnsafeInitialState();

    function run() external returns (Deployment memory deployment) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address governanceTimelock = vm.envAddress("XBID_GOVERNANCE_TIMELOCK");
        address emergencyRole = RobinhoodDeploymentConfig.EMERGENCY_SAFE;
        address teamTreasury = RobinhoodDeploymentConfig.TEAM_TREASURY;
        address protocolTreasury = RobinhoodDeploymentConfig.PROTOCOL_TREASURY;
        string memory sourceCommit = vm.envString("SOURCE_COMMIT");

        RobinhoodDeploymentConfig.validateLockedPreflight(
            deployer, governanceTimelock, emergencyRole, teamTreasury, protocolTreasury
        );
        if (deployer == governanceTimelock) revert DeployerMustDifferFromGovernance(deployer);
        uint256 sourceCommitLength = bytes(sourceCommit).length;
        if (sourceCommitLength != 40 && sourceCommitLength != 64) revert InvalidSourceCommit();

        vm.startBroadcast(deployerPrivateKey);
        deployment.registry = new MarketRegistry(governanceTimelock, deployer);
        deployment.riskController =
            new RiskController(RobinhoodDeploymentConfig.RISK_CONTROLLER_VERSION, governanceTimelock, emergencyRole);
        deployment.feeVault = new FeeVault(
            RobinhoodDeploymentConfig.FEE_VAULT_VERSION,
            RobinhoodDeploymentConfig.SETTLEMENT_TOKEN,
            address(deployment.registry),
            governanceTimelock,
            emergencyRole,
            protocolTreasury,
            RobinhoodDeploymentConfig.PROTOCOL_BPS,
            RobinhoodDeploymentConfig.CREATOR_BPS,
            RobinhoodDeploymentConfig.REFERRER_BPS
        );
        deployment.marketImplementation = new MarketVault();
        deployment.sideTokenImplementation = new SideToken();
        deployment.factoryImplementation = new XBIDFactory();
        deployment.factory = XBIDFactory(
            address(
                new ERC1967Proxy(
                    address(deployment.factoryImplementation),
                    abi.encodeCall(
                        XBIDFactory.initialize,
                        (
                            governanceTimelock,
                            RobinhoodDeploymentConfig.SETTLEMENT_TOKEN,
                            address(deployment.registry),
                            teamTreasury
                        )
                    )
                )
            )
        );

        deployment.registry.registerVersion(_versionRegistration(deployment));
        vm.stopBroadcast();

        if (
            deployment.registry.registrar() != deployer || deployment.factory.defaultMarketVersion() != 0
                || deployment.registry.versionCount() != 1
        ) revert UnsafeInitialState();

        _writeManifest(
            deployment, deployer, governanceTimelock, emergencyRole, teamTreasury, protocolTreasury, sourceCommit
        );
    }

    function _versionRegistration(Deployment memory deployment)
        private
        view
        returns (IMarketRegistry.VersionRegistration memory)
    {
        return IMarketRegistry.VersionRegistration({
            versionId: RobinhoodDeploymentConfig.MARKET_VERSION,
            marketImplementation: address(deployment.marketImplementation),
            marketImplementationCodeHash: address(deployment.marketImplementation).codehash,
            marketCloneRuntimeCodeHash: deployment.registry
            .expectedCloneRuntimeCodeHash(address(deployment.marketImplementation)),
            sideTokenImplementation: address(deployment.sideTokenImplementation),
            sideTokenImplementationCodeHash: address(deployment.sideTokenImplementation).codehash,
            sideTokenCloneRuntimeCodeHash: deployment.registry
            .expectedCloneRuntimeCodeHash(address(deployment.sideTokenImplementation)),
            settlementToken: RobinhoodDeploymentConfig.SETTLEMENT_TOKEN,
            feeVault: address(deployment.feeVault),
            feeVaultVersion: RobinhoodDeploymentConfig.FEE_VAULT_VERSION,
            riskController: address(deployment.riskController),
            riskControllerVersion: RobinhoodDeploymentConfig.RISK_CONTROLLER_VERSION,
            abiVersion: RobinhoodDeploymentConfig.ABI_VERSION
        });
    }

    function _writeManifest(
        Deployment memory deployment,
        address deployer,
        address governanceTimelock,
        address emergencyRole,
        address teamTreasury,
        address protocolTreasury,
        string memory sourceCommit
    ) private {
        string memory object = "deployment";
        vm.serializeUint(object, "manifestVersion", 1);
        vm.serializeString(object, "environment", "robinhood-testnet");
        vm.serializeString(object, "status", "PENDING_GOVERNANCE_ACTIVATION");
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeUint(object, "indexerStartBlock", block.number);
        vm.serializeString(object, "sourceCommit", sourceCommit);
        vm.serializeAddress(object, "deployer", deployer);
        vm.serializeAddress(object, "governanceTimelock", governanceTimelock);
        vm.serializeAddress(object, "emergencyRole", emergencyRole);
        vm.serializeAddress(object, "teamTreasury", teamTreasury);
        vm.serializeAddress(object, "protocolTreasury", protocolTreasury);
        vm.serializeAddress(object, "settlementToken", RobinhoodDeploymentConfig.SETTLEMENT_TOKEN);
        vm.serializeBytes32(
            object, "settlementTokenRuntimeHash", RobinhoodDeploymentConfig.SETTLEMENT_TOKEN_RUNTIME_HASH
        );
        vm.serializeAddress(object, "marketRegistry", address(deployment.registry));
        vm.serializeBytes32(object, "marketRegistryCodeHash", address(deployment.registry).codehash);
        vm.serializeAddress(object, "riskController", address(deployment.riskController));
        vm.serializeBytes32(object, "riskControllerCodeHash", address(deployment.riskController).codehash);
        vm.serializeAddress(object, "feeVault", address(deployment.feeVault));
        vm.serializeBytes32(object, "feeVaultCodeHash", address(deployment.feeVault).codehash);
        vm.serializeAddress(object, "marketVaultImplementation", address(deployment.marketImplementation));
        vm.serializeBytes32(
            object, "marketVaultImplementationCodeHash", address(deployment.marketImplementation).codehash
        );
        vm.serializeAddress(object, "sideTokenImplementation", address(deployment.sideTokenImplementation));
        vm.serializeBytes32(
            object, "sideTokenImplementationCodeHash", address(deployment.sideTokenImplementation).codehash
        );
        vm.serializeAddress(object, "factoryImplementation", address(deployment.factoryImplementation));
        vm.serializeBytes32(object, "factoryImplementationCodeHash", address(deployment.factoryImplementation).codehash);
        vm.serializeAddress(object, "factoryProxy", address(deployment.factory));
        vm.serializeBytes32(object, "factoryProxyCodeHash", address(deployment.factory).codehash);
        vm.serializeUint(object, "marketVersion", RobinhoodDeploymentConfig.MARKET_VERSION);
        vm.serializeUint(object, "feeVaultVersion", RobinhoodDeploymentConfig.FEE_VAULT_VERSION);
        vm.serializeUint(object, "riskControllerVersion", RobinhoodDeploymentConfig.RISK_CONTROLLER_VERSION);
        vm.serializeUint(object, "abiVersion", RobinhoodDeploymentConfig.ABI_VERSION);
        vm.serializeUint(object, "creationFeeUnits", deployment.factory.CONTEST_CREATION_FEE_UNITS());
        vm.serializeAddress(object, "activationSetRegistrarTarget", address(deployment.registry));
        vm.serializeBytes(
            object,
            "activationSetRegistrarCalldata",
            abi.encodeCall(MarketRegistry.setRegistrar, (address(deployment.factory)))
        );
        vm.serializeAddress(object, "activationSetDefaultVersionTarget", address(deployment.factory));
        string memory json = vm.serializeBytes(
            object,
            "activationSetDefaultVersionCalldata",
            abi.encodeCall(XBIDFactory.setDefaultMarketVersion, (RobinhoodDeploymentConfig.MARKET_VERSION))
        );

        string memory defaultPath = string.concat(vm.projectRoot(), "/deployments/robinhood-testnet/latest.json");
        vm.writeJson(json, vm.envOr("DEPLOYMENT_OUTPUT_PATH", defaultPath));
    }
}
