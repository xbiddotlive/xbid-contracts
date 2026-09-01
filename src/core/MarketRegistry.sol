// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketRegistry} from "../interfaces/IMarketRegistry.sol";

interface IRegistryMarketVault {
    function contestId() external view returns (bytes32);
    function marketVersion() external view returns (uint32);
    function creator() external view returns (address);
    function settlementToken() external view returns (address);
    function sideAToken() external view returns (address);
    function sideBToken() external view returns (address);
    function riskController() external view returns (address);
    function feeVault() external view returns (address);
}

interface IRegistrySideToken {
    function contestId() external view returns (bytes32);
    function side() external view returns (uint8);
    function marketVault() external view returns (address);
}

interface IRegistryFeeVault {
    function settlementToken() external view returns (address);
    function marketRegistry() external view returns (address);
    function governanceTimelock() external view returns (address);
    function feeVaultVersion() external view returns (uint32);
}

interface IRegistryRiskController {
    function governanceTimelock() external view returns (address);
    function riskControllerVersion() external view returns (uint32);
}

/// @notice Non-upgradeable, append-only source of truth for XBID versions and contests.
contract MarketRegistry is IMarketRegistry {
    error ZeroAddress();
    error InvalidContract(address account);
    error Unauthorized();
    error InvalidVersionId(uint32 supplied, uint32 expected);
    error VersionNotFound(uint32 versionId);
    error InvalidCodeHash(address account, bytes32 actual, bytes32 expected);
    error InvalidCloneRuntimeCodeHash(address implementation, bytes32 supplied, bytes32 expected);
    error InvalidVersionDependency(address dependency);
    error InvalidChainId(uint256 supplied, uint256 expected);
    error InvalidContestId();
    error InvalidMetadataHash();
    error ContestAlreadyRegistered(uint256 chainId, bytes32 contestId);
    error AddressAlreadyRegistered(address account);
    error InvalidContestBinding(address account);
    error IndexOutOfBounds(uint256 index, uint256 length);

    event RegistrarUpdated(address indexed oldRegistrar, address indexed newRegistrar);
    event MarketVersionRegistered(
        uint32 indexed versionId,
        address indexed marketImplementation,
        address indexed sideTokenImplementation,
        bytes32 marketImplementationCodeHash,
        bytes32 marketCloneRuntimeCodeHash,
        bytes32 sideTokenImplementationCodeHash,
        bytes32 sideTokenCloneRuntimeCodeHash,
        address settlementToken,
        address feeVault,
        uint32 feeVaultVersion,
        address riskController,
        uint32 riskControllerVersion,
        uint32 abiVersion
    );
    event ContestRegistered(
        uint256 indexed chainId,
        bytes32 indexed contestId,
        address indexed marketVault,
        address creator,
        address sideAToken,
        address sideBToken,
        uint32 versionId,
        bytes32 metadataHash
    );

    address public immutable governanceTimelock;
    address public override registrar;

    uint32[] private _versionIds;
    mapping(uint32 versionId => MarketVersion version) private _versions;
    mapping(bytes32 contestKey => ContestRecord contest) private _contests;
    mapping(address market => bool registered) public override isRegisteredMarket;
    mapping(address token => bool registered) public isRegisteredSideToken;

    constructor(address governanceTimelock_, address registrar_) {
        if (governanceTimelock_ == address(0) || registrar_ == address(0)) revert ZeroAddress();
        if (governanceTimelock_ == address(this) || registrar_ == address(this)) revert ZeroAddress();
        governanceTimelock = governanceTimelock_;
        registrar = registrar_;
    }

    modifier onlyRegistrar() {
        if (msg.sender != registrar) revert Unauthorized();
        _;
    }

    function setRegistrar(address newRegistrar) external {
        if (msg.sender != governanceTimelock) revert Unauthorized();
        if (newRegistrar == address(0) || newRegistrar == address(this)) revert ZeroAddress();
        address oldRegistrar = registrar;
        registrar = newRegistrar;
        emit RegistrarUpdated(oldRegistrar, newRegistrar);
    }

    function registerVersion(VersionRegistration calldata registration) external override onlyRegistrar {
        uint32 expectedVersionId = uint32(_versionIds.length + 1);
        if (registration.versionId != expectedVersionId) {
            revert InvalidVersionId(registration.versionId, expectedVersionId);
        }
        _validateVersion(registration);

        _versions[registration.versionId] = MarketVersion({
            marketImplementation: registration.marketImplementation,
            marketImplementationCodeHash: registration.marketImplementationCodeHash,
            marketCloneRuntimeCodeHash: registration.marketCloneRuntimeCodeHash,
            sideTokenImplementation: registration.sideTokenImplementation,
            sideTokenImplementationCodeHash: registration.sideTokenImplementationCodeHash,
            sideTokenCloneRuntimeCodeHash: registration.sideTokenCloneRuntimeCodeHash,
            settlementToken: registration.settlementToken,
            feeVault: registration.feeVault,
            feeVaultVersion: registration.feeVaultVersion,
            riskController: registration.riskController,
            riskControllerVersion: registration.riskControllerVersion,
            abiVersion: registration.abiVersion
        });
        _versionIds.push(registration.versionId);

        emit MarketVersionRegistered(
            registration.versionId,
            registration.marketImplementation,
            registration.sideTokenImplementation,
            registration.marketImplementationCodeHash,
            registration.marketCloneRuntimeCodeHash,
            registration.sideTokenImplementationCodeHash,
            registration.sideTokenCloneRuntimeCodeHash,
            registration.settlementToken,
            registration.feeVault,
            registration.feeVaultVersion,
            registration.riskController,
            registration.riskControllerVersion,
            registration.abiVersion
        );
    }

    function registerContest(ContestRegistration calldata registration) external override onlyRegistrar {
        if (registration.chainId != block.chainid) revert InvalidChainId(registration.chainId, block.chainid);
        if (registration.contestId == bytes32(0)) revert InvalidContestId();
        if (registration.metadataHash == bytes32(0)) revert InvalidMetadataHash();
        if (
            registration.creator == address(0) || registration.marketVault == address(0)
                || registration.sideAToken == address(0) || registration.sideBToken == address(0)
        ) revert ZeroAddress();
        if (
            registration.marketVault == registration.sideAToken || registration.marketVault == registration.sideBToken
                || registration.sideAToken == registration.sideBToken
        ) revert InvalidContestBinding(registration.marketVault);

        bytes32 key = contestKey(registration.chainId, registration.contestId);
        if (_contests[key].marketVault != address(0)) {
            revert ContestAlreadyRegistered(registration.chainId, registration.contestId);
        }
        if (isRegisteredMarket[registration.marketVault]) revert AddressAlreadyRegistered(registration.marketVault);
        if (isRegisteredSideToken[registration.sideAToken]) revert AddressAlreadyRegistered(registration.sideAToken);
        if (isRegisteredSideToken[registration.sideBToken]) revert AddressAlreadyRegistered(registration.sideBToken);

        MarketVersion storage version = _versions[registration.versionId];
        if (version.marketImplementation == address(0)) revert VersionNotFound(registration.versionId);
        _requireCodeHash(registration.marketVault, version.marketCloneRuntimeCodeHash);
        _requireCodeHash(registration.sideAToken, version.sideTokenCloneRuntimeCodeHash);
        _requireCodeHash(registration.sideBToken, version.sideTokenCloneRuntimeCodeHash);
        _validateContestBindings(registration, version);

        _contests[key] = ContestRecord({
            creator: registration.creator,
            marketVault: registration.marketVault,
            sideAToken: registration.sideAToken,
            sideBToken: registration.sideBToken,
            versionId: registration.versionId,
            metadataHash: registration.metadataHash
        });
        isRegisteredMarket[registration.marketVault] = true;
        isRegisteredSideToken[registration.sideAToken] = true;
        isRegisteredSideToken[registration.sideBToken] = true;

        emit ContestRegistered(
            registration.chainId,
            registration.contestId,
            registration.marketVault,
            registration.creator,
            registration.sideAToken,
            registration.sideBToken,
            registration.versionId,
            registration.metadataHash
        );
    }

    function getVersion(uint32 versionId) external view override returns (MarketVersion memory version) {
        version = _versions[versionId];
        if (version.marketImplementation == address(0)) revert VersionNotFound(versionId);
    }

    function getContest(uint256 chainId, bytes32 contestId)
        external
        view
        override
        returns (ContestRecord memory contest)
    {
        contest = _contests[contestKey(chainId, contestId)];
    }

    function versionCount() external view override returns (uint256) {
        return _versionIds.length;
    }

    function versionIdAt(uint256 index) external view override returns (uint32) {
        uint256 length = _versionIds.length;
        if (index >= length) revert IndexOutOfBounds(index, length);
        return _versionIds[index];
    }

    function contestKey(uint256 chainId, bytes32 contestId) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, contestId));
    }

    function expectedCloneRuntimeCodeHash(address implementation) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"3d3d3d3d363d3d37363d73", implementation, hex"5af43d3d93803e602a57fd5bf3"));
    }

    function _validateVersion(VersionRegistration calldata registration) private view {
        _requireContract(registration.marketImplementation);
        _requireContract(registration.sideTokenImplementation);
        _requireContract(registration.settlementToken);
        _requireContract(registration.feeVault);
        _requireContract(registration.riskController);
        _requireCodeHash(registration.marketImplementation, registration.marketImplementationCodeHash);
        _requireCodeHash(registration.sideTokenImplementation, registration.sideTokenImplementationCodeHash);

        bytes32 expectedMarketCloneHash = expectedCloneRuntimeCodeHash(registration.marketImplementation);
        if (registration.marketCloneRuntimeCodeHash != expectedMarketCloneHash) {
            revert InvalidCloneRuntimeCodeHash(
                registration.marketImplementation, registration.marketCloneRuntimeCodeHash, expectedMarketCloneHash
            );
        }
        bytes32 expectedSideCloneHash = expectedCloneRuntimeCodeHash(registration.sideTokenImplementation);
        if (registration.sideTokenCloneRuntimeCodeHash != expectedSideCloneHash) {
            revert InvalidCloneRuntimeCodeHash(
                registration.sideTokenImplementation, registration.sideTokenCloneRuntimeCodeHash, expectedSideCloneHash
            );
        }
        if (
            registration.feeVaultVersion == 0 || registration.riskControllerVersion == 0 || registration.abiVersion == 0
        ) {
            revert InvalidVersionDependency(address(0));
        }
        if (
            IRegistryFeeVault(registration.feeVault).marketRegistry() != address(this)
                || IRegistryFeeVault(registration.feeVault).settlementToken() != registration.settlementToken
                || IRegistryFeeVault(registration.feeVault).governanceTimelock() != governanceTimelock
                || IRegistryFeeVault(registration.feeVault).feeVaultVersion() != registration.feeVaultVersion
        ) revert InvalidVersionDependency(registration.feeVault);
        if (
            IRegistryRiskController(registration.riskController).riskControllerVersion()
                    != registration.riskControllerVersion
                || IRegistryRiskController(registration.riskController).governanceTimelock() != governanceTimelock
        ) revert InvalidVersionDependency(registration.riskController);
    }

    function _validateContestBindings(ContestRegistration calldata registration, MarketVersion storage version)
        private
        view
    {
        IRegistryMarketVault market = IRegistryMarketVault(registration.marketVault);
        if (
            market.contestId() != registration.contestId || market.marketVersion() != registration.versionId
                || market.creator() != registration.creator || market.settlementToken() != version.settlementToken
                || market.sideAToken() != registration.sideAToken || market.sideBToken() != registration.sideBToken
                || market.riskController() != version.riskController || market.feeVault() != version.feeVault
        ) revert InvalidContestBinding(registration.marketVault);

        IRegistrySideToken sideA = IRegistrySideToken(registration.sideAToken);
        if (
            sideA.contestId() != registration.contestId || sideA.side() != 0
                || sideA.marketVault() != registration.marketVault
        ) revert InvalidContestBinding(registration.sideAToken);

        IRegistrySideToken sideB = IRegistrySideToken(registration.sideBToken);
        if (
            sideB.contestId() != registration.contestId || sideB.side() != 1
                || sideB.marketVault() != registration.marketVault
        ) revert InvalidContestBinding(registration.sideBToken);
    }

    function _requireContract(address account) private view {
        if (account == address(0)) revert ZeroAddress();
        if (account.code.length == 0) revert InvalidContract(account);
    }

    function _requireCodeHash(address account, bytes32 expected) private view {
        bytes32 actual = account.codehash;
        if (expected == bytes32(0) || actual != expected) revert InvalidCodeHash(account, actual, expected);
    }
}
