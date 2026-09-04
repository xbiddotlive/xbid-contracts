// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "solady/test/utils/forge-std/Script.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FeeVault} from "../src/core/FeeVault.sol";
import {MarketRegistry} from "../src/core/MarketRegistry.sol";
import {RiskController} from "../src/core/RiskController.sol";
import {XBIDFactory} from "../src/core/XBIDFactory.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";

interface IUUPSProxiable {
    function proxiableUUID() external view returns (bytes32);
}

/// @notice Read-only post-deployment validator for a generated deployment manifest.
contract ValidateRobinhoodTestnet is Script {
    struct Manifest {
        address deployer;
        address governance;
        address emergency;
        address teamTreasury;
        address protocolTreasury;
        address registry;
        bytes32 registryCodeHash;
        address riskController;
        bytes32 riskControllerCodeHash;
        address feeVault;
        bytes32 feeVaultCodeHash;
        address marketImplementation;
        bytes32 marketImplementationCodeHash;
        address sideTokenImplementation;
        bytes32 sideTokenImplementationCodeHash;
        address factoryImplementation;
        bytes32 factoryImplementationCodeHash;
        address factory;
        bytes32 factoryCodeHash;
    }

    error ValidationFailed(string check);

    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external view {
        string memory defaultPath = string.concat(vm.projectRoot(), "/deployments/robinhood-testnet/latest.json");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_MANIFEST_PATH", defaultPath));

        _require(vm.parseJsonUint(json, ".manifestVersion") == 1, "manifest version");
        _require(vm.parseJsonUint(json, ".chainId") == block.chainid, "manifest chain id");
        _require(block.chainid == RobinhoodDeploymentConfig.CHAIN_ID, "runtime chain id");
        _validateManifestConstants(json);

        Manifest memory manifest = _parseManifest(json);
        RobinhoodDeploymentConfig.validateLockedPreflight(
            manifest.deployer, manifest.governance, manifest.emergency, manifest.teamTreasury, manifest.protocolTreasury
        );
        _validateContracts(manifest);
        _validateVersion(manifest);
        _validateFactory(manifest);
        _validateFeeAndRisk(manifest);
        _validateActivationAndBalances(manifest);
        _validateActivationPayloads(json, manifest);
    }

    function _validateManifestConstants(string memory json) private view {
        uint256 sourceCommitLength = bytes(vm.parseJsonString(json, ".sourceCommit")).length;
        _require(sourceCommitLength == 40 || sourceCommitLength == 64, "source commit");
        _require(
            vm.parseJsonAddress(json, ".settlementToken") == RobinhoodDeploymentConfig.SETTLEMENT_TOKEN,
            "manifest settlement"
        );
        _require(
            vm.parseJsonBytes32(json, ".settlementTokenRuntimeHash")
                == RobinhoodDeploymentConfig.SETTLEMENT_TOKEN_RUNTIME_HASH,
            "manifest settlement hash"
        );
        _require(vm.parseJsonUint(json, ".marketVersion") == RobinhoodDeploymentConfig.MARKET_VERSION, "market version");
        _require(
            vm.parseJsonUint(json, ".feeVaultVersion") == RobinhoodDeploymentConfig.FEE_VAULT_VERSION,
            "manifest fee version"
        );
        _require(
            vm.parseJsonUint(json, ".riskControllerVersion") == RobinhoodDeploymentConfig.RISK_CONTROLLER_VERSION,
            "manifest risk version"
        );
        _require(vm.parseJsonUint(json, ".abiVersion") == RobinhoodDeploymentConfig.ABI_VERSION, "manifest ABI version");
        _require(vm.parseJsonUint(json, ".creationFeeUnits") == 5_000_000, "manifest creation fee");
    }

    function _parseManifest(string memory json) private view returns (Manifest memory manifest) {
        manifest.deployer = vm.parseJsonAddress(json, ".deployer");
        manifest.governance = vm.parseJsonAddress(json, ".governanceTimelock");
        manifest.emergency = vm.parseJsonAddress(json, ".emergencyRole");
        manifest.teamTreasury = vm.parseJsonAddress(json, ".teamTreasury");
        manifest.protocolTreasury = vm.parseJsonAddress(json, ".protocolTreasury");
        manifest.registry = vm.parseJsonAddress(json, ".marketRegistry");
        manifest.registryCodeHash = vm.parseJsonBytes32(json, ".marketRegistryCodeHash");
        manifest.riskController = vm.parseJsonAddress(json, ".riskController");
        manifest.riskControllerCodeHash = vm.parseJsonBytes32(json, ".riskControllerCodeHash");
        manifest.feeVault = vm.parseJsonAddress(json, ".feeVault");
        manifest.feeVaultCodeHash = vm.parseJsonBytes32(json, ".feeVaultCodeHash");
        manifest.marketImplementation = vm.parseJsonAddress(json, ".marketVaultImplementation");
        manifest.marketImplementationCodeHash = vm.parseJsonBytes32(json, ".marketVaultImplementationCodeHash");
        manifest.sideTokenImplementation = vm.parseJsonAddress(json, ".sideTokenImplementation");
        manifest.sideTokenImplementationCodeHash = vm.parseJsonBytes32(json, ".sideTokenImplementationCodeHash");
        manifest.factoryImplementation = vm.parseJsonAddress(json, ".factoryImplementation");
        manifest.factoryImplementationCodeHash = vm.parseJsonBytes32(json, ".factoryImplementationCodeHash");
        manifest.factory = vm.parseJsonAddress(json, ".factoryProxy");
        manifest.factoryCodeHash = vm.parseJsonBytes32(json, ".factoryProxyCodeHash");
    }

    function _validateContracts(Manifest memory manifest) private view {
        _requireContract("marketRegistry", manifest.registry);
        _requireContract("riskController", manifest.riskController);
        _requireContract("feeVault", manifest.feeVault);
        _requireContract("marketVaultImplementation", manifest.marketImplementation);
        _requireContract("sideTokenImplementation", manifest.sideTokenImplementation);
        _requireContract("factoryImplementation", manifest.factoryImplementation);
        _requireContract("factoryProxy", manifest.factory);
        _require(manifest.registry.codehash == manifest.registryCodeHash, "registry code hash");
        _require(manifest.riskController.codehash == manifest.riskControllerCodeHash, "risk code hash");
        _require(manifest.feeVault.codehash == manifest.feeVaultCodeHash, "fee vault code hash");
        _require(manifest.factory.codehash == manifest.factoryCodeHash, "factory proxy code hash");
    }

    function _validateVersion(Manifest memory manifest) private view {
        MarketRegistry registry = MarketRegistry(manifest.registry);
        _require(registry.governanceTimelock() == manifest.governance, "registry governance");
        uint256 expectedVersionCount = vm.envOr("EXPECTED_REGISTRY_VERSION_COUNT", uint256(2));
        if (!vm.envOr("REQUIRE_ACTIVATED", true)) expectedVersionCount = 1;
        _require(expectedVersionCount != 0 && expectedVersionCount <= type(uint32).max, "expected version count");
        _require(registry.versionCount() == expectedVersionCount, "registry version count");
        for (uint256 index; index < expectedVersionCount; ++index) {
            _require(registry.versionIdAt(index) == index + 1, "registry version id");
        }

        IMarketRegistry.MarketVersion memory version = registry.getVersion(1);
        _require(version.marketImplementation == manifest.marketImplementation, "market implementation");
        _require(version.marketImplementationCodeHash == manifest.marketImplementation.codehash, "market code hash");
        _require(
            version.marketImplementationCodeHash == manifest.marketImplementationCodeHash, "manifest market code hash"
        );
        _require(version.sideTokenImplementation == manifest.sideTokenImplementation, "side token implementation");
        _require(
            version.sideTokenImplementationCodeHash == manifest.sideTokenImplementation.codehash, "side token code hash"
        );
        _require(
            version.sideTokenImplementationCodeHash == manifest.sideTokenImplementationCodeHash,
            "manifest side token code hash"
        );
        _require(
            version.marketCloneRuntimeCodeHash == registry.expectedCloneRuntimeCodeHash(manifest.marketImplementation),
            "market clone hash"
        );
        _require(
            version.sideTokenCloneRuntimeCodeHash
                == registry.expectedCloneRuntimeCodeHash(manifest.sideTokenImplementation),
            "side token clone hash"
        );
        _require(version.settlementToken == RobinhoodDeploymentConfig.SETTLEMENT_TOKEN, "version settlement");
        _require(version.feeVault == manifest.feeVault, "version fee vault");
        _require(version.feeVaultVersion == RobinhoodDeploymentConfig.FEE_VAULT_VERSION, "fee vault version");
        _require(version.riskController == manifest.riskController, "version risk controller");
        _require(
            version.riskControllerVersion == RobinhoodDeploymentConfig.RISK_CONTROLLER_VERSION,
            "risk controller version"
        );
        _require(version.abiVersion == RobinhoodDeploymentConfig.ABI_VERSION, "ABI version");
    }

    function _validateFactory(Manifest memory manifest) private view {
        XBIDFactory factory = XBIDFactory(manifest.factory);
        _require(factory.governanceTimelock() == manifest.governance, "factory governance");
        _require(factory.settlementToken() == RobinhoodDeploymentConfig.SETTLEMENT_TOKEN, "factory settlement");
        _require(factory.marketRegistry() == manifest.registry, "factory registry");
        _require(factory.teamTreasury() == manifest.teamTreasury, "factory team treasury");
        _require(factory.CONTEST_CREATION_FEE_UNITS() == 5_000_000, "creation fee");

        address proxyImplementation = address(uint160(uint256(vm.load(manifest.factory, ERC1967_IMPLEMENTATION_SLOT))));
        _require(proxyImplementation == manifest.factoryImplementation, "proxy implementation slot");
        _require(
            manifest.factoryImplementation.codehash == manifest.factoryImplementationCodeHash,
            "factory implementation code hash"
        );
        _require(
            IUUPSProxiable(manifest.factoryImplementation).proxiableUUID() == ERC1967_IMPLEMENTATION_SLOT, "UUPS UUID"
        );
    }

    function _validateFeeAndRisk(Manifest memory manifest) private view {
        FeeVault feeVault = FeeVault(manifest.feeVault);
        _require(feeVault.settlementToken() == RobinhoodDeploymentConfig.SETTLEMENT_TOKEN, "fee vault settlement");
        _require(feeVault.marketRegistry() == manifest.registry, "fee vault registry");
        _require(feeVault.governanceTimelock() == manifest.governance, "fee vault governance");
        _require(feeVault.emergencyRole() == manifest.emergency, "fee vault emergency");
        _require(feeVault.protocolTreasury() == manifest.protocolTreasury, "protocol treasury");
        _require(feeVault.feeVaultVersion() == RobinhoodDeploymentConfig.FEE_VAULT_VERSION, "fee vault version");
        _require(feeVault.protocolBps() == RobinhoodDeploymentConfig.PROTOCOL_BPS, "protocol BPS");
        _require(feeVault.creatorBps() == RobinhoodDeploymentConfig.CREATOR_BPS, "creator BPS");
        _require(feeVault.referrerBps() == RobinhoodDeploymentConfig.REFERRER_BPS, "referrer BPS");

        RiskController riskController = RiskController(manifest.riskController);
        _require(riskController.governanceTimelock() == manifest.governance, "risk governance");
        _require(riskController.emergencyRole() == manifest.emergency, "risk emergency");
        _require(
            riskController.riskControllerVersion() == RobinhoodDeploymentConfig.RISK_CONTROLLER_VERSION, "risk version"
        );
    }

    function _validateActivationAndBalances(Manifest memory manifest) private view {
        MarketRegistry registry = MarketRegistry(manifest.registry);
        XBIDFactory factory = XBIDFactory(manifest.factory);
        if (vm.envOr("REQUIRE_ACTIVATED", true)) {
            _require(registry.registrar() == manifest.factory, "activated registrar");
            uint256 expectedDefaultVersion = vm.envOr("EXPECTED_DEFAULT_MARKET_VERSION", uint256(2));
            _require(
                expectedDefaultVersion != 0 && expectedDefaultVersion <= type(uint32).max, "expected default version"
            );
            _require(factory.defaultMarketVersion() == expectedDefaultVersion, "activated default version");
        } else {
            _require(registry.registrar() == manifest.deployer, "pending registrar");
            _require(factory.defaultMarketVersion() == 0, "pending default version");
        }
        _require(
            SafeTransferLib.balanceOf(RobinhoodDeploymentConfig.SETTLEMENT_TOKEN, manifest.factory) == 0,
            "factory settlement balance"
        );
        _require(
            SafeTransferLib.balanceOf(RobinhoodDeploymentConfig.SETTLEMENT_TOKEN, manifest.registry) == 0,
            "registry settlement balance"
        );
    }

    function _validateActivationPayloads(string memory json, Manifest memory manifest) private view {
        _require(
            vm.parseJsonAddress(json, ".activationSetRegistrarTarget") == manifest.registry,
            "registrar activation target"
        );
        _require(
            keccak256(vm.parseJsonBytes(json, ".activationSetRegistrarCalldata"))
                == keccak256(abi.encodeCall(MarketRegistry.setRegistrar, (manifest.factory))),
            "registrar activation calldata"
        );
        _require(
            vm.parseJsonAddress(json, ".activationSetDefaultVersionTarget") == manifest.factory,
            "default version activation target"
        );
        _require(
            keccak256(vm.parseJsonBytes(json, ".activationSetDefaultVersionCalldata"))
                == keccak256(
                    abi.encodeCall(XBIDFactory.setDefaultMarketVersion, (RobinhoodDeploymentConfig.MARKET_VERSION))
                ),
            "default version activation calldata"
        );
    }

    function _requireContract(string memory field, address account) private view {
        if (account.code.length == 0) revert ValidationFailed(field);
    }

    function _require(bool condition, string memory check) private pure {
        if (!condition) revert ValidationFailed(check);
    }
}
