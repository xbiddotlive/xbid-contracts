// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {IMarketRegistry} from "../interfaces/IMarketRegistry.sol";
import {IRiskController} from "../interfaces/IRiskController.sol";
import {MarketVault} from "./MarketVault.sol";
import {SideToken} from "./SideToken.sol";

/// @notice Upgradeable entry point for creating future XBID contests.
/// @dev Factory upgrades can only affect future creation. Historical version and
///      contest records live in the non-upgradeable append-only MarketRegistry.
contract XBIDFactory is Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeTransferLib for address;

    struct CreateContestParams {
        bytes32 userSalt;
        bytes32 metadataHash;
        string metadataURI;
        string sideAName;
        string sideASymbol;
        string sideBName;
        string sideBSymbol;
    }

    /// @custom:storage-location erc7201:xbid.storage.XBIDFactory
    struct FactoryStorage {
        address governanceTimelock;
        address settlementToken;
        IMarketRegistry marketRegistry;
        address teamTreasury;
        uint32 defaultMarketVersion;
    }

    error ZeroAddress();
    error InvalidContract(address account);
    error Unauthorized();
    error InvalidSettlementDecimals(uint8 decimals);
    error InvalidVersion(uint32 versionId);
    error InvalidVersionSettlement(address actual, address expected);
    error FactoryIsNotRegistrar(address actualRegistrar);
    error CreationIsPaused(IRiskController.RiskMode mode);
    error InvalidMetadataHash();
    error InvalidMetadataURI();
    error InvalidTokenName();
    error InvalidTokenSymbol();
    error DuplicateSides();
    error UnexpectedBalanceDelta(address token, address account, uint256 expected, uint256 actual);
    error InvalidCloneCodeHash(address clone, bytes32 actual, bytes32 expected);

    event MarketVersionConfigured(
        uint32 indexed versionId,
        address indexed marketImplementation,
        address indexed sideTokenImplementation,
        address feeVault,
        address riskController,
        uint32 abiVersion
    );
    event DefaultMarketVersionUpdated(uint32 indexed oldVersionId, uint32 indexed newVersionId);
    event TeamTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ContestCreationFeePaid(
        bytes32 indexed contestId, address indexed creator, address indexed teamTreasury, uint256 feeUnits
    );
    event ContestCreated(
        bytes32 indexed contestId,
        address indexed creator,
        address indexed marketVault,
        address sideAToken,
        address sideBToken,
        uint32 marketVersion,
        bytes32 metadataHash,
        string metadataURI
    );

    uint256 public constant CONTEST_CREATION_FEE_UNITS = 5_000_000;
    uint256 public constant MAX_METADATA_URI_BYTES = 512;
    uint256 public constant MAX_TOKEN_NAME_BYTES = 64;
    uint256 public constant MAX_TOKEN_SYMBOL_BYTES = 16;

    // keccak256(abi.encode(uint256(keccak256("xbid.storage.XBIDFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FACTORY_STORAGE_LOCATION =
        0x2cdc82a277d9c9278933e3b9cae03f832da8b0dbfd0f5b103169073c57d12f00;

    constructor() {
        _disableInitializers();
    }

    modifier onlyGovernance() {
        if (msg.sender != _getFactoryStorage().governanceTimelock) revert Unauthorized();
        _;
    }

    function initialize(
        address governanceTimelock_,
        address settlementToken_,
        address marketRegistry_,
        address teamTreasury_
    ) external initializer {
        if (
            governanceTimelock_ == address(0) || settlementToken_ == address(0) || marketRegistry_ == address(0)
                || teamTreasury_ == address(0)
        ) revert ZeroAddress();
        _requireContract(settlementToken_);
        _requireContract(marketRegistry_);
        uint8 settlementDecimals = _decimals(settlementToken_);
        if (settlementDecimals != 6) revert InvalidSettlementDecimals(settlementDecimals);

        FactoryStorage storage store = _getFactoryStorage();
        store.governanceTimelock = governanceTimelock_;
        store.settlementToken = settlementToken_;
        store.marketRegistry = IMarketRegistry(marketRegistry_);
        store.teamTreasury = teamTreasury_;
    }

    /// @notice Appends a new immutable market version to the Registry.
    function registerMarketVersion(IMarketRegistry.VersionRegistration calldata registration) external onlyGovernance {
        FactoryStorage storage store = _getFactoryStorage();
        if (registration.settlementToken != store.settlementToken) {
            revert InvalidVersionSettlement(registration.settlementToken, store.settlementToken);
        }
        address actualRegistrar = store.marketRegistry.registrar();
        if (actualRegistrar != address(this)) revert FactoryIsNotRegistrar(actualRegistrar);
        store.marketRegistry.registerVersion(registration);
        emit MarketVersionConfigured(
            registration.versionId,
            registration.marketImplementation,
            registration.sideTokenImplementation,
            registration.feeVault,
            registration.riskController,
            registration.abiVersion
        );
    }

    function setDefaultMarketVersion(uint32 versionId) external onlyGovernance {
        FactoryStorage storage store = _getFactoryStorage();
        if (versionId == 0) revert InvalidVersion(versionId);
        IMarketRegistry.MarketVersion memory version = store.marketRegistry.getVersion(versionId);
        if (version.settlementToken != store.settlementToken) {
            revert InvalidVersionSettlement(version.settlementToken, store.settlementToken);
        }
        uint32 oldVersionId = store.defaultMarketVersion;
        if (versionId == oldVersionId) revert InvalidVersion(versionId);
        store.defaultMarketVersion = versionId;
        emit DefaultMarketVersionUpdated(oldVersionId, versionId);
    }

    function setTeamTreasury(address newTeamTreasury) external onlyGovernance {
        if (newTeamTreasury == address(0) || newTeamTreasury == address(this)) revert ZeroAddress();
        FactoryStorage storage store = _getFactoryStorage();
        address oldTeamTreasury = store.teamTreasury;
        if (newTeamTreasury == oldTeamTreasury) revert ZeroAddress();
        store.teamTreasury = newTeamTreasury;
        emit TeamTreasuryUpdated(oldTeamTreasury, newTeamTreasury);
    }

    function createContest(CreateContestParams calldata params)
        external
        nonReentrant
        returns (bytes32 contestId, address marketVault, address sideAToken, address sideBToken)
    {
        _validateCreateParams(params);
        FactoryStorage storage store = _getFactoryStorage();
        uint32 versionId = store.defaultMarketVersion;
        if (versionId == 0) revert InvalidVersion(versionId);

        IMarketRegistry.MarketVersion memory version = store.marketRegistry.getVersion(versionId);
        IRiskController.RiskMode mode = IRiskController(version.riskController).globalMode();
        if (mode != IRiskController.RiskMode.Normal) revert CreationIsPaused(mode);
        address actualRegistrar = store.marketRegistry.registrar();
        if (actualRegistrar != address(this)) revert FactoryIsNotRegistrar(actualRegistrar);

        contestId = computeContestId(msg.sender, params.userSalt, params.metadataHash);
        _collectCreationFee(store.settlementToken, store.teamTreasury, contestId);
        (marketVault, sideAToken, sideBToken) = _deployAndInitializeContest(contestId, versionId, params, version);

        IMarketRegistry.ContestRegistration memory registration = IMarketRegistry.ContestRegistration({
            chainId: block.chainid,
            contestId: contestId,
            creator: msg.sender,
            marketVault: marketVault,
            sideAToken: sideAToken,
            sideBToken: sideBToken,
            versionId: versionId,
            metadataHash: params.metadataHash
        });
        store.marketRegistry.registerContest(registration);
        _emitContestCreated(registration, params.metadataURI);
    }

    function _deployAndInitializeContest(
        bytes32 contestId,
        uint32 versionId,
        CreateContestParams calldata params,
        IMarketRegistry.MarketVersion memory version
    ) private returns (address marketVault, address sideAToken, address sideBToken) {
        (address predictedMarket, address predictedSideA, address predictedSideB) =
            _predictContestAddresses(contestId, version);

        marketVault = LibClone.cloneDeterministic(version.marketImplementation, _cloneSalt(contestId, 0));
        sideAToken = LibClone.cloneDeterministic(version.sideTokenImplementation, _cloneSalt(contestId, 1));
        sideBToken = LibClone.cloneDeterministic(version.sideTokenImplementation, _cloneSalt(contestId, 2));
        if (marketVault != predictedMarket || sideAToken != predictedSideA || sideBToken != predictedSideB) {
            revert InvalidContract(address(this));
        }
        _requireCloneCodeHash(marketVault, version.marketCloneRuntimeCodeHash);
        _requireCloneCodeHash(sideAToken, version.sideTokenCloneRuntimeCodeHash);
        _requireCloneCodeHash(sideBToken, version.sideTokenCloneRuntimeCodeHash);

        SideToken(sideAToken).initialize(contestId, 0, marketVault, params.sideAName, params.sideASymbol);
        SideToken(sideBToken).initialize(contestId, 1, marketVault, params.sideBName, params.sideBSymbol);
        MarketVault(marketVault)
            .initialize(
                contestId,
                versionId,
                msg.sender,
                version.settlementToken,
                sideAToken,
                sideBToken,
                version.riskController,
                version.feeVault
            );
    }

    function _emitContestCreated(IMarketRegistry.ContestRegistration memory registration, string calldata metadataURI)
        private
    {
        emit ContestCreated(
            registration.contestId,
            registration.creator,
            registration.marketVault,
            registration.sideAToken,
            registration.sideBToken,
            registration.versionId,
            registration.metadataHash,
            metadataURI
        );
    }

    function computeContestId(address creator, bytes32 userSalt, bytes32 metadataHash) public view returns (bytes32) {
        if (creator == address(0)) revert ZeroAddress();
        if (metadataHash == bytes32(0)) revert InvalidMetadataHash();
        return keccak256(abi.encode(block.chainid, creator, userSalt, metadataHash));
    }

    function predictContestAddresses(bytes32 contestId, uint32 versionId)
        external
        view
        returns (address marketVault, address sideAToken, address sideBToken)
    {
        if (contestId == bytes32(0)) revert InvalidMetadataHash();
        IMarketRegistry.MarketVersion memory version = _getFactoryStorage().marketRegistry.getVersion(versionId);
        return _predictContestAddresses(contestId, version);
    }

    function governanceTimelock() external view returns (address) {
        return _getFactoryStorage().governanceTimelock;
    }

    function settlementToken() external view returns (address) {
        return _getFactoryStorage().settlementToken;
    }

    function marketRegistry() external view returns (address) {
        return address(_getFactoryStorage().marketRegistry);
    }

    function teamTreasury() external view returns (address) {
        return _getFactoryStorage().teamTreasury;
    }

    function defaultMarketVersion() external view returns (uint32) {
        return _getFactoryStorage().defaultMarketVersion;
    }

    function expectedCloneRuntimeCodeHash(address implementation) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"3d3d3d3d363d3d37363d73", implementation, hex"5af43d3d93803e602a57fd5bf3"));
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyGovernance {
        _requireContract(newImplementation);
    }

    function _predictContestAddresses(bytes32 contestId, IMarketRegistry.MarketVersion memory version)
        private
        view
        returns (address marketVault, address sideAToken, address sideBToken)
    {
        marketVault = LibClone.predictDeterministicAddress(
            version.marketImplementation, _cloneSalt(contestId, 0), address(this)
        );
        sideAToken = LibClone.predictDeterministicAddress(
            version.sideTokenImplementation, _cloneSalt(contestId, 1), address(this)
        );
        sideBToken = LibClone.predictDeterministicAddress(
            version.sideTokenImplementation, _cloneSalt(contestId, 2), address(this)
        );
    }

    function _collectCreationFee(address token, address treasury, bytes32 contestId) private {
        uint256 senderBefore = SafeTransferLib.balanceOf(token, msg.sender);
        uint256 treasuryBefore = SafeTransferLib.balanceOf(token, treasury);
        uint256 factoryBefore = SafeTransferLib.balanceOf(token, address(this));

        token.safeTransferFrom(msg.sender, treasury, CONTEST_CREATION_FEE_UNITS);

        uint256 senderAfter = SafeTransferLib.balanceOf(token, msg.sender);
        uint256 treasuryAfter = SafeTransferLib.balanceOf(token, treasury);
        uint256 factoryAfter = SafeTransferLib.balanceOf(token, address(this));
        if (msg.sender == treasury) {
            if (treasuryAfter != treasuryBefore) {
                revert UnexpectedBalanceDelta(token, treasury, treasuryBefore, treasuryAfter);
            }
            if (factoryAfter != factoryBefore) {
                revert UnexpectedBalanceDelta(token, address(this), factoryBefore, factoryAfter);
            }
            emit ContestCreationFeePaid(contestId, msg.sender, treasury, CONTEST_CREATION_FEE_UNITS);
            return;
        }
        uint256 expectedSenderAfter =
            senderBefore >= CONTEST_CREATION_FEE_UNITS ? senderBefore - CONTEST_CREATION_FEE_UNITS : 0;
        if (senderBefore < CONTEST_CREATION_FEE_UNITS || senderAfter != expectedSenderAfter) {
            revert UnexpectedBalanceDelta(token, msg.sender, expectedSenderAfter, senderAfter);
        }
        if (treasuryAfter != treasuryBefore + CONTEST_CREATION_FEE_UNITS) {
            revert UnexpectedBalanceDelta(token, treasury, treasuryBefore + CONTEST_CREATION_FEE_UNITS, treasuryAfter);
        }
        if (factoryAfter != factoryBefore) {
            revert UnexpectedBalanceDelta(token, address(this), factoryBefore, factoryAfter);
        }
        emit ContestCreationFeePaid(contestId, msg.sender, treasury, CONTEST_CREATION_FEE_UNITS);
    }

    function _validateCreateParams(CreateContestParams calldata params) private pure {
        if (params.metadataHash == bytes32(0)) revert InvalidMetadataHash();
        uint256 uriLength = bytes(params.metadataURI).length;
        if (uriLength == 0 || uriLength > MAX_METADATA_URI_BYTES) revert InvalidMetadataURI();
        uint256 sideANameLength = bytes(params.sideAName).length;
        uint256 sideBNameLength = bytes(params.sideBName).length;
        if (
            sideANameLength == 0 || sideANameLength > MAX_TOKEN_NAME_BYTES || sideBNameLength == 0
                || sideBNameLength > MAX_TOKEN_NAME_BYTES
        ) revert InvalidTokenName();
        uint256 sideASymbolLength = bytes(params.sideASymbol).length;
        uint256 sideBSymbolLength = bytes(params.sideBSymbol).length;
        if (
            sideASymbolLength == 0 || sideASymbolLength > MAX_TOKEN_SYMBOL_BYTES || sideBSymbolLength == 0
                || sideBSymbolLength > MAX_TOKEN_SYMBOL_BYTES
        ) revert InvalidTokenSymbol();
        if (
            keccak256(bytes(params.sideAName)) == keccak256(bytes(params.sideBName))
                || keccak256(bytes(params.sideASymbol)) == keccak256(bytes(params.sideBSymbol))
        ) revert DuplicateSides();
    }

    function _cloneSalt(bytes32 contestId, uint8 component) private pure returns (bytes32) {
        return keccak256(abi.encode(contestId, component));
    }

    function _requireCloneCodeHash(address clone, bytes32 expected) private view {
        bytes32 actual = clone.codehash;
        if (actual != expected) revert InvalidCloneCodeHash(clone, actual, expected);
    }

    function _requireContract(address account) private view {
        if (account.code.length == 0) revert InvalidContract(account);
    }

    function _decimals(address token) private view returns (uint8 decimals_) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!success || data.length < 32) revert InvalidContract(token);
        decimals_ = abi.decode(data, (uint8));
    }

    function _getFactoryStorage() private pure returns (FactoryStorage storage store) {
        bytes32 location = FACTORY_STORAGE_LOCATION;
        assembly ("memory-safe") {
            store.slot := location
        }
    }
}
