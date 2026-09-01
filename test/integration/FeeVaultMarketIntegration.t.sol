// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {FeeVault} from "../../src/core/FeeVault.sol";
import {MarketVault} from "../../src/core/MarketVault.sol";
import {SideToken} from "../../src/core/SideToken.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {XbidTradeMath} from "../../src/libraries/XbidTradeMath.sol";
import {MockMarketRegistry} from "../mocks/MockMarketRegistry.sol";
import {MockRiskController} from "../mocks/MockRiskController.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

contract FeeVaultMarketIntegrationTest is Test {
    bytes32 private constant CONTEST_ID = keccak256("fee-vault-market-integration");
    address private constant GOVERNANCE = address(0x600d);
    address private constant EMERGENCY = address(0xe911);
    address private constant PROTOCOL_TREASURY = address(0x7007);
    address private constant CREATOR = address(0xc0ffee);
    address private constant TRADER = address(0xa11ce);
    address private constant REFERRER = address(0xb0b);
    uint256 private constant BUY_GROSS = 10_000_000_000;

    MarketVault private market;
    SideToken private tokenA;
    MockSettlementToken private usdc;
    MockRiskController private riskController;
    MockMarketRegistry private registry;
    FeeVault private feeVault;

    function setUp() public {
        MarketVault marketImplementation = new MarketVault();
        SideToken tokenImplementation = new SideToken();
        usdc = new MockSettlementToken();
        riskController = new MockRiskController();
        registry = new MockMarketRegistry();
        feeVault = new FeeVault(
            1, address(usdc), address(registry), GOVERNANCE, EMERGENCY, PROTOCOL_TREASURY, 7_000, 2_000, 1_000
        );

        market = MarketVault(LibClone.clone(address(marketImplementation)));
        tokenA = SideToken(LibClone.clone(address(tokenImplementation)));
        SideToken tokenB = SideToken(LibClone.clone(address(tokenImplementation)));
        tokenA.initialize(CONTEST_ID, 0, address(market), "XBID A", "XA");
        tokenB.initialize(CONTEST_ID, 1, address(market), "XBID B", "XB");
        market.initialize(
            CONTEST_ID,
            1,
            CREATOR,
            address(usdc),
            address(tokenA),
            address(tokenB),
            address(riskController),
            address(feeVault)
        );
        registry.setRegistered(address(market), true);

        usdc.mint(TRADER, 100_000_000_000_000);
        vm.prank(TRADER);
        usdc.approve(address(market), type(uint256).max);
    }

    function testMarketBuyCreditsProductionFeeVaultAtomically() external {
        XbidTradeMath.BuyResult memory quote = market.previewBuy(MarketVault.Side.A, BUY_GROSS);
        vm.prank(TRADER);
        market.buy(MarketVault.Side.A, BUY_GROSS, quote.tokenOutputWei, block.timestamp, REFERRER);

        assertEq(feeVault.protocolClaimable(), 70_000_000);
        assertEq(feeVault.claimable(CREATOR), 20_000_000);
        assertEq(feeVault.claimable(REFERRER), 10_000_000);
        assertEq(feeVault.totalLiabilityUnits(), quote.feeUnits);
        assertEq(usdc.balanceOf(address(feeVault)), quote.feeUnits);
        assertEq(usdc.balanceOf(address(market)), market.reserveUnits());
    }

    function testClaimPauseDoesNotBlockRiskOffSellFeeCredit() external {
        XbidTradeMath.BuyResult memory buyQuote = market.previewBuy(MarketVault.Side.A, BUY_GROSS);
        vm.prank(TRADER);
        market.buy(MarketVault.Side.A, BUY_GROSS, buyQuote.tokenOutputWei, block.timestamp, REFERRER);
        uint256 liabilityBefore = feeVault.totalLiabilityUnits();

        vm.prank(EMERGENCY);
        feeVault.pauseClaims(keccak256("claim transfer incident"));
        riskController.setMode(address(market), IRiskController.RiskMode.RiskOff);
        uint256 sellInput = buyQuote.tokenOutputWei / 2;
        XbidTradeMath.SellResult memory sellQuote = market.previewSell(MarketVault.Side.A, sellInput);

        vm.startPrank(TRADER);
        tokenA.approve(address(market), sellInput);
        market.sell(MarketVault.Side.A, sellInput, sellQuote.netOutputUnits, block.timestamp);
        vm.stopPrank();

        assertTrue(feeVault.claimPaused());
        assertEq(feeVault.totalLiabilityUnits(), liabilityBefore + sellQuote.feeUnits);
        assertEq(usdc.balanceOf(address(feeVault)), feeVault.totalLiabilityUnits());
        assertTrue(market.reserveUnits() >= market.requiredReserveUnits());
    }

    function testUpdatedSplitOnlyAppliesToLaterTrades() external {
        vm.prank(TRADER);
        market.buy(MarketVault.Side.A, BUY_GROSS, 0, block.timestamp, REFERRER);
        vm.prank(GOVERNANCE);
        feeVault.setFeeSplit(8_000, 1_000, 1_000);
        vm.prank(TRADER);
        market.buy(MarketVault.Side.B, BUY_GROSS, 0, block.timestamp, REFERRER);

        assertEq(feeVault.feeSplitVersion(), 2);
        assertEq(feeVault.protocolClaimable(), 150_000_000);
        assertEq(feeVault.claimable(CREATOR), 30_000_000);
        assertEq(feeVault.claimable(REFERRER), 20_000_000);
        assertEq(feeVault.totalLiabilityUnits(), 200_000_000);
    }

    function testFeeClaimsDoNotChangeMarketAccountingOrCrown() external {
        vm.prank(TRADER);
        market.buy(MarketVault.Side.A, BUY_GROSS, 0, block.timestamp, REFERRER);
        uint256 qABefore = market.qAWei();
        uint256 qBBefore = market.qBWei();
        uint256 reserveBefore = market.reserveUnits();
        MarketVault.CrownSide crownBefore = market.crownSide();

        feeVault.claimFeesFor(CREATOR);

        assertEq(market.qAWei(), qABefore);
        assertEq(market.qBWei(), qBBefore);
        assertEq(market.reserveUnits(), reserveBefore);
        assertEq(uint256(market.crownSide()), uint256(crownBefore));
        assertEq(usdc.balanceOf(CREATOR), 20_000_000);
    }
}
