// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {MarketVault} from "../../src/core/MarketVault.sol";
import {MarketVaultV2} from "../../src/core/MarketVaultV2.sol";
import {MarketVaultV4} from "../../src/core/MarketVaultV4.sol";
import {MarketVaultV3} from "../../src/core/MarketVaultV3.sol";
import {MarketRegistry} from "../../src/core/MarketRegistry.sol";
import {XBIDFactory} from "../../src/core/XBIDFactory.sol";
import {SideToken} from "../../src/core/SideToken.sol";
import {FeeVault} from "../../src/core/FeeVault.sol";
import {RiskControllerV2} from "../../src/core/RiskControllerV2.sol";
import {IMarketRegistry} from "../../src/interfaces/IMarketRegistry.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

/// @notice Local release rehearsal: production contracts, mock asset and mock Safe caller.
/// @dev Not a mainnet fork or a verification of actual Safe signatures / token behavior.
contract ArcV4ReleaseGateTest is Test {
    address private constant GOVERNOR = address(0x600d);
    address private constant EMERGENCY = address(0xe911);
    address private constant TREASURY = address(0x7ea0);
    address private constant CREATOR = address(0xc0ffee);
    address private constant TRADER = address(0xa11ce);
    address private constant REFERRER = address(0xb0b);
    uint256 private constant DELAY = 10 minutes;
    uint256 private constant INITIAL = 100_000_000e6;
    TimelockController private timelock;
    MockSettlementToken private asset;
    MarketRegistry private registry;
    XBIDFactory private factory;
    FeeVault private fees;
    RiskControllerV2 private risk;
    MarketVaultV3 private market;
    SideToken private tokenA;
    SideToken private tokenB;
    address private implementationV4;

    function setUp() public {
        address[] memory governors = new address[](1);
        governors[0] = GOVERNOR;
        timelock = new TimelockController(DELAY, governors, governors, address(0));
        asset = new MockSettlementToken();
        registry = new MarketRegistry(address(timelock), address(timelock));
        risk = new RiskControllerV2(address(timelock), EMERGENCY);
        fees = new FeeVault(
            1, address(asset), address(registry), address(timelock), EMERGENCY, TREASURY, 5000, 4000, 1000
        );
        factory = XBIDFactory(
            address(
                new ERC1967Proxy(
                    address(new XBIDFactory()),
                    abi.encodeCall(
                        XBIDFactory.initialize, (address(timelock), address(asset), address(registry), TREASURY)
                    )
                )
            )
        );
        address sideImplementation = address(new SideToken());
        address[3] memory implementations =
            [address(new MarketVault()), address(new MarketVaultV2()), address(new MarketVaultV3())];
        implementationV4 = implementations[2];
        address[] memory targets = new address[](5);
        uint256[] memory values = new uint256[](5);
        bytes[] memory payloads = new bytes[](5);
        targets[0] = address(registry);
        payloads[0] = abi.encodeCall(MarketRegistry.setRegistrar, (address(factory)));
        for (uint32 i = 0; i < 3; i++) {
            targets[i + 1] = address(factory);
            payloads[i + 1] = abi.encodeCall(
                XBIDFactory.registerMarketVersion,
                (IMarketRegistry.VersionRegistration({
                        versionId: i + 1,
                        marketImplementation: implementations[i],
                        marketImplementationCodeHash: implementations[i].codehash,
                        marketCloneRuntimeCodeHash: registry.expectedCloneRuntimeCodeHash(implementations[i]),
                        sideTokenImplementation: sideImplementation,
                        sideTokenImplementationCodeHash: sideImplementation.codehash,
                        sideTokenCloneRuntimeCodeHash: registry.expectedCloneRuntimeCodeHash(sideImplementation),
                        settlementToken: address(asset),
                        feeVault: address(fees),
                        feeVaultVersion: 1,
                        riskController: address(risk),
                        riskControllerVersion: 2,
                        abiVersion: i == 0 ? 1 : 2
                    }))
            );
        }
        targets[4] = address(factory);
        payloads[4] = abi.encodeCall(XBIDFactory.setDefaultMarketVersion, (3));
        bytes32 salt = keccak256("local-v3-bootstrap");
        vm.prank(GOVERNOR);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY - 1);
        vm.expectRevert();
        vm.prank(GOVERNOR);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        assertEq(factory.defaultMarketVersion(), 0);
        vm.warp(block.timestamp + 1);
        vm.prank(GOVERNOR);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        asset.mint(CREATOR, 5e6);
        asset.mint(TRADER, INITIAL);
        vm.startPrank(CREATOR);
        asset.approve(address(factory), 5e6);
        (, address vault, address sideA, address sideB) = factory.createContest(
            XBIDFactory.CreateContestParams({
                userSalt: keccak256("release"),
                metadataHash: keccak256("reviewed-metadata"),
                metadataURI: "ipfs://local-release-fixture",
                sideAName: "Side A",
                sideASymbol: "A",
                sideBName: "Side B",
                sideBSymbol: "B"
            })
        );
        vm.stopPrank();
        // Rehearse an upgrade from a live V3 clone, not a fresh V4 bootstrap.
        address oldVault = vault;
        bytes32[3] memory oldVersions;
        for (uint32 i; i < 3; i++) {
            oldVersions[i] = keccak256(abi.encode(registry.getVersion(i + 1)));
        }
        implementationV4 = address(new MarketVaultV4());
        IMarketRegistry.MarketVersion memory old = registry.getVersion(3);
        IMarketRegistry.VersionRegistration memory next = IMarketRegistry.VersionRegistration({
            versionId: 4,
            marketImplementation: implementationV4,
            marketImplementationCodeHash: implementationV4.codehash,
            marketCloneRuntimeCodeHash: registry.expectedCloneRuntimeCodeHash(implementationV4),
            sideTokenImplementation: old.sideTokenImplementation,
            sideTokenImplementationCodeHash: old.sideTokenImplementationCodeHash,
            sideTokenCloneRuntimeCodeHash: old.sideTokenCloneRuntimeCodeHash,
            settlementToken: old.settlementToken,
            feeVault: old.feeVault,
            feeVaultVersion: old.feeVaultVersion,
            riskController: old.riskController,
            riskControllerVersion: old.riskControllerVersion,
            abiVersion: old.abiVersion
        });
        address[] memory upgradeTargets = new address[](2);
        upgradeTargets[0] = address(factory);
        upgradeTargets[1] = address(factory);
        uint256[] memory upgradeValues = new uint256[](2);
        bytes[] memory upgradeData = new bytes[](2);
        upgradeData[0] = abi.encodeCall(XBIDFactory.registerMarketVersion, (next));
        upgradeData[1] = abi.encodeCall(XBIDFactory.setDefaultMarketVersion, (4));
        bytes32 upgradeSalt = keccak256("v4-15000");
        vm.prank(GOVERNOR);
        timelock.scheduleBatch(upgradeTargets, upgradeValues, upgradeData, bytes32(0), upgradeSalt, DELAY);
        vm.warp(block.timestamp + DELAY - 1);
        vm.expectRevert();
        vm.prank(GOVERNOR);
        timelock.executeBatch(upgradeTargets, upgradeValues, upgradeData, bytes32(0), upgradeSalt);
        assertEq(factory.defaultMarketVersion(), 3);
        vm.warp(block.timestamp + 1);
        vm.prank(GOVERNOR);
        timelock.executeBatch(upgradeTargets, upgradeValues, upgradeData, bytes32(0), upgradeSalt);
        for (uint32 i; i < 3; i++) {
            assertEq(keccak256(abi.encode(registry.getVersion(i + 1))), oldVersions[i]);
        }
        assertEq(MarketVaultV3(oldVault).CROWN_ACTIVATION_RESERVE_UNITS(), 70_000e6);
        assertEq(MarketVaultV3(oldVault).marketVersion(), 3);
        asset.mint(CREATOR, 5e6);
        vm.startPrank(CREATOR);
        asset.approve(address(factory), 5e6);
        (, vault, sideA, sideB) = factory.createContest(
            XBIDFactory.CreateContestParams({
                userSalt: keccak256("v4-release"),
                metadataHash: keccak256("v4-metadata"),
                metadataURI: "ipfs://v4-test",
                sideAName: "V4 A",
                sideASymbol: "V4A",
                sideBName: "V4 B",
                sideBSymbol: "V4B"
            })
        );
        vm.stopPrank();
        // V4 keeps the same trading ABI; calls below execute actual V4 clone code.
        market = MarketVaultV3(vault);
        assertEq(market.CROWN_ACTIVATION_RESERVE_UNITS(), 15_000e6);
        assertEq(market.CROWN_HOLD_SECONDS(), 60);
        assertEq(market.bWad(), 150_000e18);
        tokenA = SideToken(sideA);
        tokenB = SideToken(sideB);
        vm.startPrank(TRADER);
        asset.approve(vault, type(uint256).max);
        tokenA.approve(vault, type(uint256).max);
        tokenB.approve(vault, type(uint256).max);
        vm.stopPrank();
    }

    function testUpgradeLocksV4BindingsAndExactCreationAllowance() external {
        assertEq(factory.defaultMarketVersion(), 4);
        assertEq(registry.versionCount(), 4);
        assertEq(market.marketVersion(), 4);
        assertEq(address(market).codehash, registry.expectedCloneRuntimeCodeHash(implementationV4));
        assertEq(registry.getVersion(4).marketImplementationCodeHash, implementationV4.codehash);
        assertEq(registry.getContest(block.chainid, market.contestId()).marketVault, address(market));
        assertEq(asset.allowance(CREATOR, address(factory)), 0);
        assertEq(asset.balanceOf(address(factory)), 0);
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), GOVERNOR));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), EMERGENCY));
    }

    function testFuzzV4CycleAndClaimsConserveFunds(uint96 seed, bool sideA) external {
        MarketVaultV2.Side source = sideA ? MarketVaultV2.Side.A : MarketVaultV2.Side.B;
        MarketVaultV2.Side destination = sideA ? MarketVaultV2.Side.B : MarketVaultV2.Side.A;
        uint256 gross = 1_000e6 + uint256(seed) % 20_000_000e6;
        uint256 expected = market.previewBuy(source, gross).tokenOutputWei;
        vm.prank(TRADER);
        uint256 bought = market.buy(source, gross, expected, block.timestamp, REFERRER);
        assertEq(bought, expected);
        _assertAccounting();
        expected = market.previewFlip(source, bought).destinationTokenOutputWei;
        vm.prank(TRADER);
        uint256 flipped = market.flip(source, bought, expected, block.timestamp);
        assertEq(flipped, expected);
        _assertAccounting();
        expected = market.previewSell(destination, flipped).netOutputUnits;
        vm.prank(TRADER);
        assertEq(market.sellAll(destination, flipped, expected, block.timestamp), expected);
        uint256 feeTotal = fees.totalLiabilityUnits();
        assertLe(asset.balanceOf(TRADER) + feeTotal, INITIAL);
        _assertAccounting();
        uint256 creatorDue = fees.claimable(CREATOR);
        fees.claimFeesFor(CREATOR); // arbitrary caller must not receive beneficiary funds
        fees.claimFeesFor(REFERRER);
        vm.prank(TREASURY);
        fees.claimProtocolFees();
        assertEq(asset.balanceOf(CREATOR), creatorDue);
        assertEq(asset.balanceOf(address(this)), 0);
        assertEq(fees.totalLiabilityUnits(), 0);
        _assertAccounting();
    }

    function testRiskOffAllowsExitButNotBuyFlipOrEmergencyRecovery() external {
        _buy();
        vm.prank(EMERGENCY);
        risk.setGlobalMode(IRiskController.RiskMode.RiskOff, keccak256("local drill"));
        vm.expectRevert();
        vm.prank(TRADER);
        market.buy(MarketVaultV2.Side.B, 1e6, 0, block.timestamp, address(0));
        uint256 flipInput = tokenA.balanceOf(TRADER);
        vm.expectRevert();
        vm.prank(TRADER);
        market.flip(MarketVaultV2.Side.A, flipInput, 0, block.timestamp);
        vm.expectRevert();
        vm.prank(EMERGENCY);
        risk.setGlobalMode(IRiskController.RiskMode.Normal, bytes32(0));
        vm.prank(EMERGENCY);
        fees.pauseClaims(bytes32(0));
        uint256 owned = tokenA.balanceOf(TRADER);
        vm.prank(TRADER);
        market.sellAll(MarketVaultV2.Side.A, owned, 0, block.timestamp);
        vm.expectRevert(FeeVault.ClaimsArePaused.selector);
        fees.claimFeesFor(CREATOR);
        _govern(address(fees), abi.encodeCall(FeeVault.resumeClaims, (bytes32(0))));
        fees.claimFeesFor(CREATOR);
        _govern(
            address(risk), abi.encodeCall(RiskControllerV2.setGlobalMode, (IRiskController.RiskMode.Normal, bytes32(0)))
        );
        _buy();
        _assertAccounting();
    }

    function testFullPauseBlocksSellAndGovernanceRestoresIt() external {
        _buy();
        uint256 owned = tokenA.balanceOf(TRADER);
        vm.prank(EMERGENCY);
        risk.setMarketMode(address(market), IRiskController.RiskMode.FullPause, bytes32(0));
        vm.expectRevert();
        vm.prank(TRADER);
        market.sellAll(MarketVaultV2.Side.A, owned, 0, block.timestamp);
        _govern(
            address(risk),
            abi.encodeCall(
                RiskControllerV2.setMarketMode, (address(market), IRiskController.RiskMode.Normal, bytes32(0))
            )
        );
        vm.prank(TRADER);
        market.sellAll(MarketVaultV2.Side.A, owned, 0, block.timestamp);
        _assertAccounting();
    }

    function testSlippageDeadlineAndBalanceChangesRollback() external {
        uint256 quote = market.previewBuy(MarketVaultV2.Side.A, 1_000e6).tokenOutputWei;
        vm.expectRevert();
        vm.prank(TRADER);
        market.buy(MarketVaultV2.Side.A, 1_000e6, quote + 1, block.timestamp, REFERRER);
        vm.expectRevert();
        vm.prank(TRADER);
        market.buy(MarketVaultV2.Side.A, 1_000e6, 0, block.timestamp - 1, REFERRER);
        assertEq(asset.balanceOf(TRADER), INITIAL);
        assertEq(market.referrerOf(TRADER), address(0));
        _buy();
        uint256 owned = tokenA.balanceOf(TRADER);
        vm.prank(TRADER);
        tokenA.transfer(CREATOR, 1);
        vm.expectRevert();
        vm.prank(TRADER);
        market.sellAll(MarketVaultV2.Side.A, owned, 0, block.timestamp);
        _assertAccounting();
    }

    function testFeeOnTransferAndCallbackRollbackWithoutLosingFunds() external {
        asset.setTransferFeeBps(100);
        vm.expectRevert();
        vm.prank(TRADER);
        market.buy(MarketVaultV2.Side.A, 1_000e6, 0, block.timestamp, REFERRER);
        assertEq(asset.balanceOf(TRADER), INITIAL);
        asset.setTransferFeeBps(0);
        asset.setTransferCallback(
            address(market),
            abi.encodeCall(MarketVaultV2.buy, (MarketVaultV2.Side.B, 1e6, 0, block.timestamp, address(0)))
        );
        vm.expectRevert();
        vm.prank(TRADER);
        market.buy(MarketVaultV2.Side.A, 1_000e6, 0, block.timestamp, REFERRER);
        assertEq(asset.balanceOf(TRADER), INITIAL);
        _assertAccounting();
    }

    function testEmergencyRecoversTradingAfterFiveMinutesButCannotResumeFeeClaims() external {
        _buy();
        assertEq(fees.protocolClaimable(), 5e6);
        assertEq(fees.claimable(CREATOR), 4e6);
        assertEq(fees.claimable(REFERRER), 1e6);
        vm.startPrank(EMERGENCY);
        risk.setGlobalMode(IRiskController.RiskMode.FullPause, bytes32(0));
        fees.pauseClaims(bytes32(0));
        bytes32 id = risk.queueRecovery(address(0), IRiskController.RiskMode.Normal, bytes32(0));
        vm.stopPrank();
        vm.warp(block.timestamp + 299);
        vm.expectRevert();
        vm.prank(EMERGENCY);
        risk.executeRecovery(address(0), id);
        vm.expectRevert();
        vm.prank(TRADER);
        market.buy(MarketVaultV2.Side.A, 1e6, 0, block.timestamp, REFERRER);
        vm.warp(block.timestamp + 1);
        vm.prank(EMERGENCY);
        risk.executeRecovery(address(0), id);
        _buy();
        vm.expectRevert(FeeVault.Unauthorized.selector);
        vm.prank(EMERGENCY);
        fees.resumeClaims(bytes32(0));
        vm.expectRevert(FeeVault.Unauthorized.selector);
        vm.prank(EMERGENCY);
        fees.setFeeSplit(10000, 0, 0);
        vm.expectRevert(FeeVault.ClaimsArePaused.selector);
        fees.claimFeesFor(CREATOR);
        _assertAccounting();
    }

    function _buy() private {
        vm.prank(TRADER);
        market.buy(MarketVaultV2.Side.A, 1_000e6, 0, block.timestamp, REFERRER);
    }

    function _govern(address target, bytes memory payload) private {
        bytes32 salt = keccak256(abi.encode(target, payload, block.timestamp));
        vm.prank(GOVERNOR);
        timelock.schedule(target, 0, payload, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(GOVERNOR);
        timelock.execute(target, 0, payload, bytes32(0), salt);
    }

    function _assertAccounting() private {
        assertGe(market.reserveUnits(), market.requiredReserveUnits());
        assertEq(asset.balanceOf(address(market)), market.reserveUnits());
        assertEq(tokenA.totalSupply(), market.qAWei());
        assertEq(tokenB.totalSupply(), market.qBWei());
        assertEq(fees.totalLiabilityUnits(), fees.protocolClaimable() + fees.totalAccountClaimable());
        assertEq(asset.balanceOf(address(fees)), fees.totalLiabilityUnits());
        assertEq(
            asset.balanceOf(TRADER) + asset.balanceOf(address(market)) + asset.balanceOf(address(fees))
                + asset.balanceOf(TREASURY) + asset.balanceOf(CREATOR) + asset.balanceOf(REFERRER),
            INITIAL + 10e6
        );
    }
}
