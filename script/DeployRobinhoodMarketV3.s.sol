// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "solady/test/utils/forge-std/Script.sol";
import {MarketRegistry} from "../src/core/MarketRegistry.sol";
import {MarketVaultV3} from "../src/core/MarketVaultV3.sol";
import {XBIDFactory} from "../src/core/XBIDFactory.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";

/// @notice Deploys the immutable b=150,000 V3 implementation with stable buy math.
/// @dev Registration and default-version activation remain a separate atomic
///      Timelock batch controlled by the Governance Safe.
contract DeployRobinhoodMarketV3 is Script {
    uint32 private constant MARKET_VERSION = 3;
    uint32 private constant ABI_VERSION = 2;

    MarketRegistry private constant REGISTRY = MarketRegistry(0x0B68fD82965Fd853907CA4E2f7E6E6d478Aaef8b);
    XBIDFactory private constant FACTORY = XBIDFactory(0x8f9208FD358c62FB4052e4C2FBbCA3152A17E4b6);
    address private constant SIDE_TOKEN_IMPLEMENTATION = 0xdfF5Ed954cFC2ba873539Ffbd093e072C3a38d9C;
    address private constant FEE_VAULT = 0x82D9159cB488175cAcdcD145A7285d80563e69d0;
    address private constant RISK_CONTROLLER = 0xfeebdbB42de39B95f8dE5FcdBDd11e986443c278;

    error InvalidSourceCommit();
    error UnexpectedProtocolState();
    error InvalidMarketImplementation();

    function run() external returns (MarketVaultV3 implementation) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address governanceTimelock = vm.envAddress("XBID_GOVERNANCE_TIMELOCK");
        string memory sourceCommit = vm.envString("SOURCE_COMMIT");

        RobinhoodDeploymentConfig.validateLockedPreflight(
            deployer,
            governanceTimelock,
            RobinhoodDeploymentConfig.EMERGENCY_SAFE,
            RobinhoodDeploymentConfig.TEAM_TREASURY,
            RobinhoodDeploymentConfig.PROTOCOL_TREASURY
        );
        uint256 sourceCommitLength = bytes(sourceCommit).length;
        if (sourceCommitLength != 40 && sourceCommitLength != 64) revert InvalidSourceCommit();
        if (
            address(REGISTRY) != FACTORY.marketRegistry() || REGISTRY.registrar() != address(FACTORY)
                || REGISTRY.versionCount() != 2 || FACTORY.defaultMarketVersion() != 2
        ) revert UnexpectedProtocolState();

        vm.startBroadcast(deployerPrivateKey);
        implementation = new MarketVaultV3();
        vm.stopBroadcast();

        if (implementation.bWad() != 150_000e18 || address(implementation).code.length == 0) {
            revert InvalidMarketImplementation();
        }

        IMarketRegistry.VersionRegistration memory registration = _registration(address(implementation));
        _writeManifest(implementation, registration, deployer, governanceTimelock, sourceCommit);
    }

    function _registration(address implementation) private view returns (IMarketRegistry.VersionRegistration memory) {
        return IMarketRegistry.VersionRegistration({
            versionId: MARKET_VERSION,
            marketImplementation: implementation,
            marketImplementationCodeHash: implementation.codehash,
            marketCloneRuntimeCodeHash: REGISTRY.expectedCloneRuntimeCodeHash(implementation),
            sideTokenImplementation: SIDE_TOKEN_IMPLEMENTATION,
            sideTokenImplementationCodeHash: SIDE_TOKEN_IMPLEMENTATION.codehash,
            sideTokenCloneRuntimeCodeHash: REGISTRY.expectedCloneRuntimeCodeHash(SIDE_TOKEN_IMPLEMENTATION),
            settlementToken: RobinhoodDeploymentConfig.SETTLEMENT_TOKEN,
            feeVault: FEE_VAULT,
            feeVaultVersion: RobinhoodDeploymentConfig.FEE_VAULT_VERSION,
            riskController: RISK_CONTROLLER,
            riskControllerVersion: RobinhoodDeploymentConfig.RISK_CONTROLLER_VERSION,
            abiVersion: ABI_VERSION
        });
    }

    function _writeManifest(
        MarketVaultV3 implementation,
        IMarketRegistry.VersionRegistration memory registration,
        address deployer,
        address governanceTimelock,
        string memory sourceCommit
    ) private {
        string memory object = "marketV3";
        vm.serializeUint(object, "manifestVersion", 1);
        vm.serializeString(object, "environment", "robinhood-testnet");
        vm.serializeString(object, "status", "PENDING_GOVERNANCE_ACTIVATION");
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeUint(object, "deploymentScanBlock", block.number);
        vm.serializeString(object, "sourceCommit", sourceCommit);
        vm.serializeAddress(object, "deployer", deployer);
        vm.serializeAddress(object, "governanceTimelock", governanceTimelock);
        vm.serializeAddress(object, "governanceSafe", RobinhoodDeploymentConfig.GOVERNANCE_SAFE);
        vm.serializeAddress(object, "marketRegistry", address(REGISTRY));
        vm.serializeAddress(object, "factoryProxy", address(FACTORY));
        vm.serializeAddress(object, "marketVaultImplementation", address(implementation));
        vm.serializeBytes32(object, "marketVaultImplementationCodeHash", registration.marketImplementationCodeHash);
        vm.serializeBytes32(object, "marketCloneRuntimeCodeHash", registration.marketCloneRuntimeCodeHash);
        vm.serializeAddress(object, "sideTokenImplementation", registration.sideTokenImplementation);
        vm.serializeBytes32(object, "sideTokenImplementationCodeHash", registration.sideTokenImplementationCodeHash);
        vm.serializeBytes32(object, "sideTokenCloneRuntimeCodeHash", registration.sideTokenCloneRuntimeCodeHash);
        vm.serializeAddress(object, "settlementToken", registration.settlementToken);
        vm.serializeAddress(object, "feeVault", registration.feeVault);
        vm.serializeUint(object, "feeVaultVersion", registration.feeVaultVersion);
        vm.serializeAddress(object, "riskController", registration.riskController);
        vm.serializeUint(object, "riskControllerVersion", registration.riskControllerVersion);
        vm.serializeUint(object, "marketVersion", registration.versionId);
        vm.serializeUint(object, "abiVersion", registration.abiVersion);
        vm.serializeInt(object, "bWad", implementation.bWad());
        vm.serializeAddress(object, "registerVersionTarget", address(FACTORY));
        vm.serializeBytes(
            object, "registerVersionCalldata", abi.encodeCall(XBIDFactory.registerMarketVersion, (registration))
        );
        vm.serializeAddress(object, "setDefaultVersionTarget", address(FACTORY));
        string memory json = vm.serializeBytes(
            object, "setDefaultVersionCalldata", abi.encodeCall(XBIDFactory.setDefaultMarketVersion, (MARKET_VERSION))
        );

        string memory defaultPath = string.concat(vm.projectRoot(), "/deployments/robinhood-testnet/market-v3.json");
        vm.writeJson(json, vm.envOr("DEPLOYMENT_OUTPUT_PATH", defaultPath));
    }
}
