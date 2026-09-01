// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IMarketRegistry {
    struct VersionRegistration {
        uint32 versionId;
        address marketImplementation;
        bytes32 marketImplementationCodeHash;
        bytes32 marketCloneRuntimeCodeHash;
        address sideTokenImplementation;
        bytes32 sideTokenImplementationCodeHash;
        bytes32 sideTokenCloneRuntimeCodeHash;
        address settlementToken;
        address feeVault;
        uint32 feeVaultVersion;
        address riskController;
        uint32 riskControllerVersion;
        uint32 abiVersion;
    }

    struct MarketVersion {
        address marketImplementation;
        bytes32 marketImplementationCodeHash;
        bytes32 marketCloneRuntimeCodeHash;
        address sideTokenImplementation;
        bytes32 sideTokenImplementationCodeHash;
        bytes32 sideTokenCloneRuntimeCodeHash;
        address settlementToken;
        address feeVault;
        uint32 feeVaultVersion;
        address riskController;
        uint32 riskControllerVersion;
        uint32 abiVersion;
    }

    struct ContestRegistration {
        uint256 chainId;
        bytes32 contestId;
        address creator;
        address marketVault;
        address sideAToken;
        address sideBToken;
        uint32 versionId;
        bytes32 metadataHash;
    }

    struct ContestRecord {
        address creator;
        address marketVault;
        address sideAToken;
        address sideBToken;
        uint32 versionId;
        bytes32 metadataHash;
    }

    function registrar() external view returns (address);

    function registerVersion(VersionRegistration calldata registration) external;

    function registerContest(ContestRegistration calldata registration) external;

    function getVersion(uint32 versionId) external view returns (MarketVersion memory);

    function getContest(uint256 chainId, bytes32 contestId) external view returns (ContestRecord memory);

    function versionCount() external view returns (uint256);

    function versionIdAt(uint256 index) external view returns (uint32);

    function isRegisteredMarket(address market) external view returns (bool);
}
