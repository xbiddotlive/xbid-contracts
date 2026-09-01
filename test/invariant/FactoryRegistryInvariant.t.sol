// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {InvariantTest} from "solady/test/utils/InvariantTest.sol";
import {FeeVault} from "../../src/core/FeeVault.sol";
import {MarketRegistry} from "../../src/core/MarketRegistry.sol";
import {MarketVault} from "../../src/core/MarketVault.sol";
import {RiskController} from "../../src/core/RiskController.sol";
import {SideToken} from "../../src/core/SideToken.sol";
import {XBIDFactory} from "../../src/core/XBIDFactory.sol";
import {IMarketRegistry} from "../../src/interfaces/IMarketRegistry.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

contract FactoryRegistryHandler {
    address public constant TEAM_A = address(0x7ea0);
    address public constant TEAM_B = address(0x7ea1);
    address public constant EMERGENCY = address(0xe911);
    uint256 public constant INITIAL_CREATOR_BALANCE = 1_000_000_000;
    uint256 public constant MAX_CONTESTS = 8;

    MockSettlementToken public immutable usdc;
    MarketRegistry public immutable registry;
    FeeVault public immutable feeVault;
    RiskController public immutable riskController;
    MarketVault public immutable marketImplementation;
    SideToken public immutable sideTokenImplementation;
    XBIDFactory public immutable factory;

    uint256 public successfulCreations;
    uint256 public duplicateCreationSuccesses;
    uint256 public unauthorizedRegistrySuccesses;

    bytes32[] public contestIds;
    bytes32[] public metadataHashes;
    bytes32[] public userSalts;
    address[] public markets;
    address[] public sideATokens;
    address[] public sideBTokens;

    constructor() {
        usdc = new MockSettlementToken();
        registry = new MarketRegistry(address(this), address(this));
        riskController = new RiskController(1, address(this), EMERGENCY);
        feeVault =
            new FeeVault(1, address(usdc), address(registry), address(this), EMERGENCY, TEAM_A, 7_000, 2_000, 1_000);
        marketImplementation = new MarketVault();
        sideTokenImplementation = new SideToken();
        XBIDFactory implementation = new XBIDFactory();
        factory = XBIDFactory(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(XBIDFactory.initialize, (address(this), address(usdc), address(registry), TEAM_A))
                )
            )
        );

        registry.setRegistrar(address(factory));
        factory.registerMarketVersion(_versionRegistration());
        factory.setDefaultMarketVersion(1);
        usdc.mint(address(this), INITIAL_CREATOR_BALANCE);
        usdc.approve(address(factory), type(uint256).max);
    }

    function create(uint256 seed) external {
        if (successfulCreations >= MAX_CONTESTS) return;
        if (riskController.globalMode() != IRiskController.RiskMode.Normal) return;
        bytes32 metadataHash = keccak256(abi.encode("metadata", seed, successfulCreations));
        bytes32 userSalt = keccak256(abi.encode("salt", seed, successfulCreations));
        XBIDFactory.CreateContestParams memory params = _createParams(metadataHash, userSalt);
        try factory.createContest(params) returns (bytes32 contestId, address market, address sideA, address sideB) {
            contestIds.push(contestId);
            metadataHashes.push(metadataHash);
            userSalts.push(userSalt);
            markets.push(market);
            sideATokens.push(sideA);
            sideBTokens.push(sideB);
            successfulCreations += 1;
        } catch {}
    }

    function tryDuplicate(uint256 seed) external {
        uint256 count = successfulCreations;
        if (count == 0) return;
        uint256 index = seed % count;
        try factory.createContest(_createParams(metadataHashes[index], userSalts[index])) {
            duplicateCreationSuccesses += 1;
        } catch {}
    }

    function tryUnauthorizedRegistryWrite(uint256 seed) external {
        IMarketRegistry.ContestRegistration memory fake = IMarketRegistry.ContestRegistration({
            chainId: block.chainid,
            contestId: keccak256(abi.encode("unauthorized", seed)),
            creator: address(this),
            marketVault: address(marketImplementation),
            sideAToken: address(sideTokenImplementation),
            sideBToken: address(uint160(seed | 1)),
            versionId: 1,
            metadataHash: keccak256(abi.encode(seed))
        });
        try registry.registerContest(fake) {
            unauthorizedRegistrySuccesses += 1;
        } catch {}
    }

    function rotateTreasury(bool useTeamB) external {
        address requested = useTeamB ? TEAM_B : TEAM_A;
        if (factory.teamTreasury() == requested) return;
        factory.setTeamTreasury(requested);
    }

    function setRiskMode(uint8 seed) external {
        IRiskController.RiskMode requested = IRiskController.RiskMode(seed % 3);
        if (riskController.globalMode() == requested) return;
        riskController.setGlobalMode(requested, keccak256("factory-registry-invariant"));
    }

    function contestIdAt(uint256 index) external view returns (bytes32) {
        return contestIds[index];
    }

    function metadataHashAt(uint256 index) external view returns (bytes32) {
        return metadataHashes[index];
    }

    function marketAt(uint256 index) external view returns (address) {
        return markets[index];
    }

    function sideAAt(uint256 index) external view returns (address) {
        return sideATokens[index];
    }

    function sideBAt(uint256 index) external view returns (address) {
        return sideBTokens[index];
    }

    function _versionRegistration() private view returns (IMarketRegistry.VersionRegistration memory) {
        return IMarketRegistry.VersionRegistration({
            versionId: 1,
            marketImplementation: address(marketImplementation),
            marketImplementationCodeHash: address(marketImplementation).codehash,
            marketCloneRuntimeCodeHash: registry.expectedCloneRuntimeCodeHash(address(marketImplementation)),
            sideTokenImplementation: address(sideTokenImplementation),
            sideTokenImplementationCodeHash: address(sideTokenImplementation).codehash,
            sideTokenCloneRuntimeCodeHash: registry.expectedCloneRuntimeCodeHash(address(sideTokenImplementation)),
            settlementToken: address(usdc),
            feeVault: address(feeVault),
            feeVaultVersion: 1,
            riskController: address(riskController),
            riskControllerVersion: 1,
            abiVersion: 1
        });
    }

    function _createParams(bytes32 metadataHash, bytes32 userSalt)
        private
        pure
        returns (XBIDFactory.CreateContestParams memory)
    {
        return XBIDFactory.CreateContestParams({
            userSalt: userSalt,
            metadataHash: metadataHash,
            metadataURI: "ipfs://invariant-metadata",
            sideAName: "Invariant Alpha",
            sideASymbol: "I-A",
            sideBName: "Invariant Beta",
            sideBSymbol: "I-B"
        });
    }
}

contract FactoryRegistryInvariantTest is InvariantTest {
    FactoryRegistryHandler private handler;
    MockSettlementToken private usdc;
    MarketRegistry private registry;
    XBIDFactory private factory;

    address private marketImplementation;
    bytes32 private marketImplementationCodeHash;
    address private sideTokenImplementation;
    bytes32 private sideTokenImplementationCodeHash;
    address private feeVault;
    address private riskController;

    function setUp() public {
        handler = new FactoryRegistryHandler();
        usdc = handler.usdc();
        registry = handler.registry();
        factory = handler.factory();
        IMarketRegistry.MarketVersion memory version = registry.getVersion(1);
        marketImplementation = version.marketImplementation;
        marketImplementationCodeHash = version.marketImplementationCodeHash;
        sideTokenImplementation = version.sideTokenImplementation;
        sideTokenImplementationCodeHash = version.sideTokenImplementationCodeHash;
        feeVault = version.feeVault;
        riskController = version.riskController;
        _addTargetContract(address(handler));
    }

    function invariantVersionOneNeverChangesOrDisappears() external view {
        require(registry.versionCount() == 1, "version count changed");
        require(registry.versionIdAt(0) == 1, "version id changed");
        IMarketRegistry.MarketVersion memory version = registry.getVersion(1);
        require(version.marketImplementation == marketImplementation, "market implementation changed");
        require(version.marketImplementationCodeHash == marketImplementationCodeHash, "market hash changed");
        require(version.sideTokenImplementation == sideTokenImplementation, "token implementation changed");
        require(version.sideTokenImplementationCodeHash == sideTokenImplementationCodeHash, "token hash changed");
        require(version.feeVault == feeVault, "fee vault changed");
        require(version.riskController == riskController, "risk controller changed");
        require(version.abiVersion == 1, "abi version changed");
    }

    function invariantEveryHistoricalContestKeepsItsBindings() external view {
        uint256 count = handler.successfulCreations();
        require(count <= handler.MAX_CONTESTS(), "contest bound exceeded");
        for (uint256 i; i < count; ++i) {
            bytes32 contestId = handler.contestIdAt(i);
            address marketAddress = handler.marketAt(i);
            address sideAAddress = handler.sideAAt(i);
            address sideBAddress = handler.sideBAt(i);
            IMarketRegistry.ContestRecord memory record = registry.getContest(block.chainid, contestId);
            require(record.creator == address(handler), "creator changed");
            require(record.marketVault == marketAddress, "market changed");
            require(record.sideAToken == sideAAddress, "side A changed");
            require(record.sideBToken == sideBAddress, "side B changed");
            require(record.versionId == 1, "contest version changed");
            require(record.metadataHash == handler.metadataHashAt(i), "metadata changed");
            require(registry.isRegisteredMarket(marketAddress), "market unregistered");
            require(MarketVault(marketAddress).contestId() == contestId, "market contest changed");
            require(MarketVault(marketAddress).sideAToken() == sideAAddress, "market side A changed");
            require(MarketVault(marketAddress).sideBToken() == sideBAddress, "market side B changed");
            require(SideToken(sideAAddress).marketVault() == marketAddress, "side A binding changed");
            require(SideToken(sideBAddress).marketVault() == marketAddress, "side B binding changed");
        }
    }

    function invariantCreationFeesOnlyReachConfiguredTreasuries() external view {
        uint256 paid = handler.successfulCreations() * factory.CONTEST_CREATION_FEE_UNITS();
        require(
            usdc.balanceOf(handler.TEAM_A()) + usdc.balanceOf(handler.TEAM_B()) == paid,
            "creation fee accounting mismatch"
        );
        require(usdc.balanceOf(address(handler)) + paid == handler.INITIAL_CREATOR_BALANCE(), "creator debit mismatch");
        require(usdc.balanceOf(address(factory)) == 0, "factory retained settlement token");
        require(usdc.balanceOf(address(registry)) == 0, "registry retained settlement token");
    }

    function invariantForbiddenWritesNeverSucceed() external view {
        require(handler.duplicateCreationSuccesses() == 0, "duplicate contest succeeded");
        require(handler.unauthorizedRegistrySuccesses() == 0, "unauthorized registry write succeeded");
        require(factory.defaultMarketVersion() == 1, "default version changed");
        require(registry.registrar() == address(factory), "registrar changed");
    }
}
