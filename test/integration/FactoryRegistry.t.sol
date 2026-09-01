// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "solady/test/utils/forge-std/Test.sol";
import {FeeVault} from "../../src/core/FeeVault.sol";
import {MarketRegistry} from "../../src/core/MarketRegistry.sol";
import {MarketVault} from "../../src/core/MarketVault.sol";
import {RiskController} from "../../src/core/RiskController.sol";
import {SideToken} from "../../src/core/SideToken.sol";
import {XBIDFactory} from "../../src/core/XBIDFactory.sol";
import {IMarketRegistry} from "../../src/interfaces/IMarketRegistry.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

contract XBIDFactoryV2 is XBIDFactory {
    function implementationRevision() external pure returns (uint256) {
        return 2;
    }
}

contract FactoryRegistryTest is Test {
    address private constant GOVERNANCE = address(0x600d);
    address private constant EMERGENCY = address(0xe911);
    address private constant TEAM_TREASURY = address(0x7ea0);
    address private constant NEW_TEAM_TREASURY = address(0x7ea1);
    address private constant CREATOR = address(0xc0ffee);
    address private constant TRADER = address(0xa11ce);
    bytes32 private constant METADATA_HASH = keccak256("ipfs metadata");
    bytes32 private constant USER_SALT = keccak256("creator retry salt");

    MockSettlementToken private usdc;
    MarketRegistry private registry;
    FeeVault private feeVault;
    RiskController private riskController;
    MarketVault private marketImplementation;
    SideToken private sideTokenImplementation;
    XBIDFactory private factoryImplementation;
    XBIDFactory private factory;

    function setUp() public {
        usdc = new MockSettlementToken();
        registry = new MarketRegistry(GOVERNANCE, GOVERNANCE);
        riskController = new RiskController(1, GOVERNANCE, EMERGENCY);
        feeVault = new FeeVault(
            1, address(usdc), address(registry), GOVERNANCE, EMERGENCY, TEAM_TREASURY, 7_000, 2_000, 1_000
        );
        marketImplementation = new MarketVault();
        sideTokenImplementation = new SideToken();
        factoryImplementation = new XBIDFactory();

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(factoryImplementation),
            abi.encodeCall(XBIDFactory.initialize, (GOVERNANCE, address(usdc), address(registry), TEAM_TREASURY))
        );
        factory = XBIDFactory(address(proxy));

        vm.prank(GOVERNANCE);
        registry.setRegistrar(address(factory));
        IMarketRegistry.VersionRegistration memory versionOne = _versionRegistration(1);
        vm.prank(GOVERNANCE);
        factory.registerMarketVersion(versionOne);
        vm.prank(GOVERNANCE);
        factory.setDefaultMarketVersion(1);

        usdc.mint(CREATOR, 100_000_000);
        vm.prank(CREATOR);
        usdc.approve(address(factory), type(uint256).max);
    }

    function testFactoryAndRegistryLockInitialConfiguration() external {
        assertEq(factory.governanceTimelock(), GOVERNANCE);
        assertEq(factory.settlementToken(), address(usdc));
        assertEq(factory.marketRegistry(), address(registry));
        assertEq(factory.teamTreasury(), TEAM_TREASURY);
        assertEq(factory.defaultMarketVersion(), 1);
        assertEq(registry.governanceTimelock(), GOVERNANCE);
        assertEq(registry.registrar(), address(factory));
        assertEq(registry.versionCount(), 1);
        assertEq(registry.versionIdAt(0), 1);

        IMarketRegistry.MarketVersion memory version = registry.getVersion(1);
        assertEq(version.marketImplementation, address(marketImplementation));
        assertEq(version.marketImplementationCodeHash, address(marketImplementation).codehash);
        assertEq(version.sideTokenImplementation, address(sideTokenImplementation));
        assertEq(version.sideTokenImplementationCodeHash, address(sideTokenImplementation).codehash);
        assertEq(version.settlementToken, address(usdc));
        assertEq(version.feeVault, address(feeVault));
        assertEq(version.riskController, address(riskController));
        assertEq(version.abiVersion, 1);
    }

    function testCreateContestIsAtomicDeterministicAndDirectlyPaysTreasury() external {
        XBIDFactory.CreateContestParams memory params = _createParams(METADATA_HASH, USER_SALT);
        bytes32 expectedContestId = factory.computeContestId(CREATOR, USER_SALT, METADATA_HASH);
        (address expectedMarket, address expectedSideA, address expectedSideB) =
            factory.predictContestAddresses(expectedContestId, 1);
        uint256 creatorBefore = usdc.balanceOf(CREATOR);

        vm.prank(CREATOR);
        (bytes32 contestId, address marketAddress, address sideAAddress, address sideBAddress) =
            factory.createContest(params);

        assertEq(contestId, expectedContestId);
        assertEq(marketAddress, expectedMarket);
        assertEq(sideAAddress, expectedSideA);
        assertEq(sideBAddress, expectedSideB);
        assertEq(usdc.balanceOf(CREATOR), creatorBefore - 5_000_000);
        assertEq(usdc.balanceOf(TEAM_TREASURY), 5_000_000);
        assertEq(usdc.balanceOf(address(factory)), 0);
        assertEq(usdc.balanceOf(address(registry)), 0);

        MarketVault market = MarketVault(marketAddress);
        SideToken sideA = SideToken(sideAAddress);
        SideToken sideB = SideToken(sideBAddress);
        assertEq(market.contestId(), contestId);
        assertEq(market.marketVersion(), 1);
        assertEq(market.creator(), CREATOR);
        assertEq(market.sideAToken(), sideAAddress);
        assertEq(market.sideBToken(), sideBAddress);
        assertEq(sideA.marketVault(), marketAddress);
        assertEq(sideB.marketVault(), marketAddress);
        assertEq(sideA.side(), 0);
        assertEq(sideB.side(), 1);
        assertEq(sideA.name(), "Team Alpha");
        assertEq(sideB.symbol(), "BETA");
        assertTrue(registry.isRegisteredMarket(marketAddress));
        assertTrue(registry.isRegisteredSideToken(sideAAddress));
        assertTrue(registry.isRegisteredSideToken(sideBAddress));

        IMarketRegistry.ContestRecord memory record = registry.getContest(block.chainid, contestId);
        assertEq(record.creator, CREATOR);
        assertEq(record.marketVault, marketAddress);
        assertEq(record.sideAToken, sideAAddress);
        assertEq(record.sideBToken, sideBAddress);
        assertEq(record.versionId, 1);
        assertEq(record.metadataHash, METADATA_HASH);
    }

    function testRegisteredMarketCanTradeAndCreditFeeVault() external {
        vm.prank(CREATOR);
        (, address marketAddress,,) = factory.createContest(_createParams(METADATA_HASH, USER_SALT));
        MarketVault market = MarketVault(marketAddress);
        usdc.mint(TRADER, 10_000_000_000);
        vm.startPrank(TRADER);
        usdc.approve(marketAddress, type(uint256).max);
        market.buy(MarketVault.Side.A, 1_000_000_000, 0, block.timestamp, address(0));
        vm.stopPrank();

        assertTrue(market.reserveUnits() > 0);
        assertTrue(feeVault.totalLiabilityUnits() > 0);
        assertEq(usdc.balanceOf(address(feeVault)), feeVault.totalLiabilityUnits());
    }

    function testDuplicateCreationRollsBackFeeAndCannotOverwriteContest() external {
        XBIDFactory.CreateContestParams memory params = _createParams(METADATA_HASH, USER_SALT);
        vm.prank(CREATOR);
        (bytes32 contestId, address originalMarket,,) = factory.createContest(params);
        uint256 creatorBefore = usdc.balanceOf(CREATOR);
        uint256 treasuryBefore = usdc.balanceOf(TEAM_TREASURY);

        vm.expectRevert();
        vm.prank(CREATOR);
        factory.createContest(params);

        assertEq(usdc.balanceOf(CREATOR), creatorBefore);
        assertEq(usdc.balanceOf(TEAM_TREASURY), treasuryBefore);
        assertEq(registry.getContest(block.chainid, contestId).marketVault, originalMarket);
    }

    function testRiskOffAndFullPauseBlockCreationWithoutTakingFee() external {
        uint256 creatorBefore = usdc.balanceOf(CREATOR);
        vm.prank(EMERGENCY);
        riskController.setGlobalMode(IRiskController.RiskMode.RiskOff, keccak256("incident"));

        vm.expectRevert(abi.encodeWithSelector(XBIDFactory.CreationIsPaused.selector, IRiskController.RiskMode.RiskOff));
        vm.prank(CREATOR);
        factory.createContest(_createParams(METADATA_HASH, USER_SALT));
        assertEq(usdc.balanceOf(CREATOR), creatorBefore);
        assertEq(usdc.balanceOf(TEAM_TREASURY), 0);

        vm.prank(EMERGENCY);
        riskController.setGlobalMode(IRiskController.RiskMode.FullPause, keccak256("severe incident"));
        vm.expectRevert(
            abi.encodeWithSelector(XBIDFactory.CreationIsPaused.selector, IRiskController.RiskMode.FullPause)
        );
        vm.prank(CREATOR);
        factory.createContest(_createParams(METADATA_HASH, USER_SALT));
    }

    function testFeeOnTransferTokenCannotUnderpayTreasuryAndEverythingRollsBack() external {
        usdc.setTransferFeeBps(100);
        uint256 creatorBefore = usdc.balanceOf(CREATOR);

        vm.expectRevert();
        vm.prank(CREATOR);
        factory.createContest(_createParams(METADATA_HASH, USER_SALT));

        assertEq(usdc.balanceOf(CREATOR), creatorBefore);
        assertEq(usdc.balanceOf(TEAM_TREASURY), 0);
        assertEq(
            registry.getContest(block.chainid, factory.computeContestId(CREATOR, USER_SALT, METADATA_HASH)).marketVault,
            address(0)
        );
    }

    function testCreationFeeTransferCannotReenterFactory() external {
        XBIDFactory.CreateContestParams memory params = _createParams(METADATA_HASH, USER_SALT);
        usdc.setTransferCallback(address(factory), abi.encodeCall(XBIDFactory.createContest, (params)));
        uint256 creatorBefore = usdc.balanceOf(CREATOR);

        vm.expectRevert();
        vm.prank(CREATOR);
        factory.createContest(params);

        assertEq(usdc.balanceOf(CREATOR), creatorBefore);
        assertEq(usdc.balanceOf(TEAM_TREASURY), 0);
        assertEq(registry.versionCount(), 1);
    }

    function testTeamTreasuryRotationOnlyAffectsFutureCreation() external {
        vm.prank(GOVERNANCE);
        factory.setTeamTreasury(NEW_TEAM_TREASURY);
        vm.prank(CREATOR);
        factory.createContest(_createParams(METADATA_HASH, USER_SALT));

        assertEq(usdc.balanceOf(TEAM_TREASURY), 0);
        assertEq(usdc.balanceOf(NEW_TEAM_TREASURY), 5_000_000);
    }

    function testTreasuryCanCreateWithoutAnArtificialBalanceDelta() external {
        vm.prank(GOVERNANCE);
        factory.setTeamTreasury(CREATOR);
        uint256 creatorBefore = usdc.balanceOf(CREATOR);
        vm.prank(CREATOR);
        (bytes32 contestId, address marketAddress,,) = factory.createContest(_createParams(METADATA_HASH, USER_SALT));

        assertEq(usdc.balanceOf(CREATOR), creatorBefore);
        assertEq(usdc.balanceOf(address(factory)), 0);
        assertEq(registry.getContest(block.chainid, contestId).marketVault, marketAddress);
    }

    function testAppendOnlyVersionSurvivesRegistrarRotation() external {
        IMarketRegistry.MarketVersion memory versionOneBefore = registry.getVersion(1);
        IMarketRegistry.VersionRegistration memory versionTwo = _versionRegistration(2);
        vm.prank(GOVERNANCE);
        factory.registerMarketVersion(versionTwo);
        assertEq(registry.versionCount(), 2);
        assertEq(registry.versionIdAt(1), 2);

        vm.prank(GOVERNANCE);
        registry.setRegistrar(GOVERNANCE);
        IMarketRegistry.VersionRegistration memory duplicateVersionOne = _versionRegistration(1);
        vm.expectRevert(abi.encodeWithSelector(MarketRegistry.InvalidVersionId.selector, 1, 3));
        vm.prank(GOVERNANCE);
        registry.registerVersion(duplicateVersionOne);

        IMarketRegistry.MarketVersion memory versionOneAfter = registry.getVersion(1);
        assertEq(versionOneAfter.marketImplementation, versionOneBefore.marketImplementation);
        assertEq(versionOneAfter.marketImplementationCodeHash, versionOneBefore.marketImplementationCodeHash);
        assertEq(versionOneAfter.abiVersion, versionOneBefore.abiVersion);
    }

    function testRegistryRejectsUnauthorizedAndInvalidVersionMetadata() external {
        IMarketRegistry.VersionRegistration memory versionTwo = _versionRegistration(2);
        vm.expectRevert(MarketRegistry.Unauthorized.selector);
        registry.registerVersion(versionTwo);

        IMarketRegistry.VersionRegistration memory registration = _versionRegistration(2);
        registration.marketCloneRuntimeCodeHash = bytes32(uint256(1));
        vm.prank(GOVERNANCE);
        registry.setRegistrar(GOVERNANCE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketRegistry.InvalidCloneRuntimeCodeHash.selector,
                address(marketImplementation),
                bytes32(uint256(1)),
                registry.expectedCloneRuntimeCodeHash(address(marketImplementation))
            )
        );
        vm.prank(GOVERNANCE);
        registry.registerVersion(registration);
    }

    function testRegistryRejectsUnboundOrNonCloneContest() external {
        IMarketRegistry.ContestRegistration memory registration = IMarketRegistry.ContestRegistration({
            chainId: block.chainid,
            contestId: keccak256("fake"),
            creator: CREATOR,
            marketVault: address(marketImplementation),
            sideAToken: address(sideTokenImplementation),
            sideBToken: address(0x1234),
            versionId: 1,
            metadataHash: METADATA_HASH
        });
        vm.prank(GOVERNANCE);
        registry.setRegistrar(GOVERNANCE);
        vm.expectRevert();
        vm.prank(GOVERNANCE);
        registry.registerContest(registration);
        assertFalse(registry.isRegisteredMarket(address(marketImplementation)));
    }

    function testRegistryRejectsVersionDependenciesFromAnotherGovernanceDomain() external {
        RiskController foreignController = new RiskController(1, address(0xf012), address(0xe012));
        IMarketRegistry.VersionRegistration memory registration = _versionRegistration(2);
        registration.riskController = address(foreignController);
        vm.prank(GOVERNANCE);
        registry.setRegistrar(GOVERNANCE);
        vm.expectRevert(
            abi.encodeWithSelector(MarketRegistry.InvalidVersionDependency.selector, address(foreignController))
        );
        vm.prank(GOVERNANCE);
        registry.registerVersion(registration);
    }

    function testFactoryImplementationAndProxyCannotBeInitializedTwice() external {
        vm.expectRevert();
        factoryImplementation.initialize(GOVERNANCE, address(usdc), address(registry), TEAM_TREASURY);
        vm.expectRevert();
        factory.initialize(GOVERNANCE, address(usdc), address(registry), TEAM_TREASURY);
    }

    function testOnlyGovernanceCanConfigureOrUpgradeFactory() external {
        vm.expectRevert(XBIDFactory.Unauthorized.selector);
        factory.setTeamTreasury(NEW_TEAM_TREASURY);
        vm.expectRevert(XBIDFactory.Unauthorized.selector);
        factory.setDefaultMarketVersion(1);

        XBIDFactoryV2 newImplementation = new XBIDFactoryV2();
        vm.expectRevert(XBIDFactory.Unauthorized.selector);
        factory.upgradeToAndCall(address(newImplementation), "");

        vm.prank(GOVERNANCE);
        factory.upgradeToAndCall(address(newImplementation), "");
        assertEq(XBIDFactoryV2(address(factory)).implementationRevision(), 2);
        assertEq(factory.defaultMarketVersion(), 1);
        assertEq(factory.marketRegistry(), address(registry));
    }

    function testFactoryUpgradeCannotMutateHistoricalContest() external {
        vm.prank(CREATOR);
        (bytes32 contestId, address marketAddress,,) = factory.createContest(_createParams(METADATA_HASH, USER_SALT));
        IMarketRegistry.ContestRecord memory beforeRecord = registry.getContest(block.chainid, contestId);
        XBIDFactoryV2 newImplementation = new XBIDFactoryV2();
        vm.prank(GOVERNANCE);
        factory.upgradeToAndCall(address(newImplementation), "");

        IMarketRegistry.ContestRecord memory afterRecord = registry.getContest(block.chainid, contestId);
        assertEq(afterRecord.marketVault, beforeRecord.marketVault);
        assertEq(afterRecord.marketVault, marketAddress);
        assertEq(afterRecord.creator, beforeRecord.creator);
        assertEq(afterRecord.metadataHash, beforeRecord.metadataHash);
        assertEq(MarketVault(marketAddress).creator(), CREATOR);
    }

    function testInvalidMetadataAndTokenLabelsFailBeforeFee() external {
        XBIDFactory.CreateContestParams memory params = _createParams(bytes32(0), USER_SALT);
        vm.expectRevert(XBIDFactory.InvalidMetadataHash.selector);
        vm.prank(CREATOR);
        factory.createContest(params);

        params = _createParams(METADATA_HASH, USER_SALT);
        params.sideBName = params.sideAName;
        vm.expectRevert(XBIDFactory.DuplicateSides.selector);
        vm.prank(CREATOR);
        factory.createContest(params);
        assertEq(usdc.balanceOf(TEAM_TREASURY), 0);
    }

    function testFuzzContestIdAndAddressesAreCreatorScoped(bytes32 userSalt, bytes32 metadataHash, address creator)
        external
    {
        vm.assume(creator != address(0));
        vm.assume(metadataHash != bytes32(0));
        bytes32 contestId = factory.computeContestId(creator, userSalt, metadataHash);
        address otherCreator = creator == address(1) ? address(2) : address(1);
        bytes32 otherContestId = factory.computeContestId(otherCreator, userSalt, metadataHash);
        assertTrue(contestId != otherContestId);
        (address marketAddress, address sideAAddress, address sideBAddress) =
            factory.predictContestAddresses(contestId, 1);
        assertTrue(marketAddress != sideAAddress);
        assertTrue(marketAddress != sideBAddress);
        assertTrue(sideAAddress != sideBAddress);
    }

    function _versionRegistration(uint32 versionId)
        private
        view
        returns (IMarketRegistry.VersionRegistration memory registration)
    {
        bytes32 marketCloneHash = registry.expectedCloneRuntimeCodeHash(address(marketImplementation));
        bytes32 sideCloneHash = registry.expectedCloneRuntimeCodeHash(address(sideTokenImplementation));
        registration = IMarketRegistry.VersionRegistration({
            versionId: versionId,
            marketImplementation: address(marketImplementation),
            marketImplementationCodeHash: address(marketImplementation).codehash,
            marketCloneRuntimeCodeHash: marketCloneHash,
            sideTokenImplementation: address(sideTokenImplementation),
            sideTokenImplementationCodeHash: address(sideTokenImplementation).codehash,
            sideTokenCloneRuntimeCodeHash: sideCloneHash,
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
        returns (XBIDFactory.CreateContestParams memory params)
    {
        params = XBIDFactory.CreateContestParams({
            userSalt: userSalt,
            metadataHash: metadataHash,
            metadataURI: "ipfs://bafy-xbid-metadata",
            sideAName: "Team Alpha",
            sideASymbol: "ALPHA",
            sideBName: "Team Beta",
            sideBSymbol: "BETA"
        });
    }
}
