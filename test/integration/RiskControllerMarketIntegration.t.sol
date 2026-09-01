// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {FeeVault} from "../../src/core/FeeVault.sol";
import {MarketVault} from "../../src/core/MarketVault.sol";
import {RiskController} from "../../src/core/RiskController.sol";
import {SideToken} from "../../src/core/SideToken.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {XbidTradeMath} from "../../src/libraries/XbidTradeMath.sol";
import {MockMarketRegistry} from "../mocks/MockMarketRegistry.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

contract RiskControllerMarketIntegrationTest is Test {
    bytes32 private constant CONTEST_A = keccak256("risk-controller-market-a");
    bytes32 private constant CONTEST_B = keccak256("risk-controller-market-b");
    address private constant GOVERNANCE = address(0x600d);
    address private constant EMERGENCY = address(0xe911);
    address private constant PROTOCOL_TREASURY = address(0x7007);
    address private constant CREATOR = address(0xc0ffee);
    address private constant TRADER = address(0xa11ce);
    uint256 private constant BUY_GROSS = 10_000_000_000;

    MarketVault private marketA;
    MarketVault private marketB;
    SideToken private tokenA;
    SideToken private tokenB;
    MockSettlementToken private usdc;
    MockMarketRegistry private registry;
    FeeVault private feeVault;
    RiskController private riskController;

    function setUp() public {
        MarketVault marketImplementation = new MarketVault();
        SideToken tokenImplementation = new SideToken();
        usdc = new MockSettlementToken();
        registry = new MockMarketRegistry();
        feeVault = new FeeVault(
            1, address(usdc), address(registry), GOVERNANCE, EMERGENCY, PROTOCOL_TREASURY, 7_000, 2_000, 1_000
        );
        riskController = new RiskController(1, GOVERNANCE, EMERGENCY);

        (marketA, tokenA) = _deployMarket(marketImplementation, tokenImplementation, CONTEST_A, "XA", "XAO");
        (marketB, tokenB) = _deployMarket(marketImplementation, tokenImplementation, CONTEST_B, "XB", "XBO");
        registry.setRegistered(address(marketA), true);
        registry.setRegistered(address(marketB), true);

        usdc.mint(TRADER, 1_000_000_000_000_000);
        vm.startPrank(TRADER);
        usdc.approve(address(marketA), type(uint256).max);
        usdc.approve(address(marketB), type(uint256).max);
        vm.stopPrank();
    }

    function testPerMarketRiskOffBlocksEntryButPreservesSellAndOtherMarket() external {
        uint256 boughtA = _buy(marketA);
        vm.prank(EMERGENCY);
        riskController.setMarketMode(address(marketA), IRiskController.RiskMode.RiskOff, keccak256("market-a-risk"));

        vm.expectRevert(abi.encodeWithSelector(MarketVault.ContestPaused.selector, IRiskController.RiskMode.RiskOff));
        vm.prank(TRADER);
        marketA.buy(MarketVault.Side.A, BUY_GROSS, 0, block.timestamp, address(0));

        _buy(marketB);
        uint256 liabilityBefore = feeVault.totalLiabilityUnits();
        _sell(marketA, tokenA, boughtA / 2);

        assertTrue(feeVault.totalLiabilityUnits() > liabilityBefore);
        assertEq(uint256(riskController.effectiveMode(address(marketB))), uint256(IRiskController.RiskMode.Normal));
    }

    function testPerMarketFullPauseCannotStopAnotherMarketSell() external {
        uint256 boughtA = _buy(marketA);
        uint256 boughtB = _buy(marketB);
        vm.prank(EMERGENCY);
        riskController.setMarketMode(
            address(marketA), IRiskController.RiskMode.FullPause, keccak256("market-a-full-pause")
        );

        vm.startPrank(TRADER);
        tokenA.approve(address(marketA), boughtA / 2);
        vm.expectRevert(abi.encodeWithSelector(MarketVault.ContestPaused.selector, IRiskController.RiskMode.FullPause));
        marketA.sell(MarketVault.Side.A, boughtA / 2, 0, block.timestamp);
        vm.stopPrank();

        _sell(marketB, tokenB, boughtB / 2);
        assertTrue(marketB.reserveUnits() >= marketB.requiredReserveUnits());
    }

    function testGlobalRiskOffBlocksBuysAndPreservesAllMarketSells() external {
        uint256 boughtA = _buy(marketA);
        uint256 boughtB = _buy(marketB);
        vm.prank(EMERGENCY);
        riskController.setGlobalMode(IRiskController.RiskMode.RiskOff, keccak256("shared dependency risk"));

        vm.expectRevert(abi.encodeWithSelector(MarketVault.ContestPaused.selector, IRiskController.RiskMode.RiskOff));
        vm.prank(TRADER);
        marketA.buy(MarketVault.Side.A, BUY_GROSS, 0, block.timestamp, address(0));
        vm.expectRevert(abi.encodeWithSelector(MarketVault.ContestPaused.selector, IRiskController.RiskMode.RiskOff));
        vm.prank(TRADER);
        marketB.buy(MarketVault.Side.A, BUY_GROSS, 0, block.timestamp, address(0));

        _sell(marketA, tokenA, boughtA / 2);
        _sell(marketB, tokenB, boughtB / 2);
    }

    function testGlobalFullPauseStopsTradesButNeverHealthyFeeClaims() external {
        uint256 boughtA = _buy(marketA);
        uint256 reserveBefore = marketA.reserveUnits();
        uint256 creatorClaimable = feeVault.claimable(CREATOR);
        vm.prank(EMERGENCY);
        riskController.setGlobalMode(IRiskController.RiskMode.FullPause, keccak256("settlement incident"));

        vm.expectRevert(abi.encodeWithSelector(MarketVault.ContestPaused.selector, IRiskController.RiskMode.FullPause));
        vm.prank(TRADER);
        marketA.buy(MarketVault.Side.B, BUY_GROSS, 0, block.timestamp, address(0));

        vm.startPrank(TRADER);
        tokenA.approve(address(marketA), boughtA / 2);
        vm.expectRevert(abi.encodeWithSelector(MarketVault.ContestPaused.selector, IRiskController.RiskMode.FullPause));
        marketA.sell(MarketVault.Side.A, boughtA / 2, 0, block.timestamp);
        vm.stopPrank();

        feeVault.claimFeesFor(CREATOR);
        assertEq(usdc.balanceOf(CREATOR), creatorClaimable);
        assertEq(marketA.reserveUnits(), reserveBefore);
    }

    function testGovernanceRecoveryRestoresTradingAfterEmergencyPause() external {
        vm.prank(EMERGENCY);
        riskController.setGlobalMode(IRiskController.RiskMode.FullPause, keccak256("emergency"));
        vm.prank(GOVERNANCE);
        riskController.setGlobalMode(IRiskController.RiskMode.Normal, keccak256("timelock recovery"));

        _buy(marketA);
        assertTrue(marketA.qAWei() > 0);
    }

    function testLocalRecoveryCannotOverrideStricterGlobalMode() external {
        vm.startPrank(GOVERNANCE);
        riskController.setGlobalMode(IRiskController.RiskMode.RiskOff, keccak256("global"));
        riskController.setMarketMode(address(marketA), IRiskController.RiskMode.FullPause, keccak256("local"));
        riskController.setMarketMode(address(marketA), IRiskController.RiskMode.Normal, keccak256("local recovery"));
        vm.stopPrank();

        assertEq(uint256(riskController.effectiveMode(address(marketA))), uint256(IRiskController.RiskMode.RiskOff));
        vm.expectRevert(abi.encodeWithSelector(MarketVault.ContestPaused.selector, IRiskController.RiskMode.RiskOff));
        vm.prank(TRADER);
        marketA.buy(MarketVault.Side.A, BUY_GROSS, 0, block.timestamp, address(0));
    }

    function _deployMarket(
        MarketVault marketImplementation,
        SideToken tokenImplementation,
        bytes32 contestId,
        string memory symbolA,
        string memory symbolB
    ) private returns (MarketVault market, SideToken firstSideToken) {
        market = MarketVault(LibClone.clone(address(marketImplementation)));
        firstSideToken = SideToken(LibClone.clone(address(tokenImplementation)));
        SideToken secondSideToken = SideToken(LibClone.clone(address(tokenImplementation)));
        firstSideToken.initialize(contestId, 0, address(market), symbolA, symbolA);
        secondSideToken.initialize(contestId, 1, address(market), symbolB, symbolB);
        market.initialize(
            contestId,
            1,
            CREATOR,
            address(usdc),
            address(firstSideToken),
            address(secondSideToken),
            address(riskController),
            address(feeVault)
        );
    }

    function _buy(MarketVault market) private returns (uint256 tokenOutputWei) {
        XbidTradeMath.BuyResult memory quote = market.previewBuy(MarketVault.Side.A, BUY_GROSS);
        vm.prank(TRADER);
        tokenOutputWei = market.buy(MarketVault.Side.A, BUY_GROSS, quote.tokenOutputWei, block.timestamp, address(0));
    }

    function _sell(MarketVault market, SideToken token, uint256 tokenInputWei) private {
        XbidTradeMath.SellResult memory quote = market.previewSell(MarketVault.Side.A, tokenInputWei);
        vm.startPrank(TRADER);
        token.approve(address(market), tokenInputWei);
        market.sell(MarketVault.Side.A, tokenInputWei, quote.netOutputUnits, block.timestamp);
        vm.stopPrank();
    }
}
