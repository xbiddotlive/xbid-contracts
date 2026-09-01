// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {MarketVault} from "../../src/core/MarketVault.sol";
import {SideToken} from "../../src/core/SideToken.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {XbidTradeMath} from "../../src/libraries/XbidTradeMath.sol";
import {MockFeeVault} from "../mocks/MockFeeVault.sol";
import {MockRiskController} from "../mocks/MockRiskController.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

contract MarketVaultTest is Test {
    bytes32 private constant CONTEST_ID = keccak256("xbid-contest-1");
    address private constant CREATOR = address(0xc0ffee);
    address private constant TRADER = address(0xa11ce);
    address private constant REFERRER = address(0xb0b);
    uint256 private constant BUY_GROSS = 10_000_000_000;

    MarketVault private marketImplementation;
    SideToken private tokenImplementation;
    MarketVault private market;
    SideToken private tokenA;
    SideToken private tokenB;
    MockSettlementToken private usdc;
    MockRiskController private riskController;
    MockFeeVault private feeVault;

    function setUp() public {
        marketImplementation = new MarketVault();
        tokenImplementation = new SideToken();
        usdc = new MockSettlementToken();
        riskController = new MockRiskController();
        feeVault = new MockFeeVault();

        market = MarketVault(LibClone.clone(address(marketImplementation)));
        tokenA = SideToken(LibClone.clone(address(tokenImplementation)));
        tokenB = SideToken(LibClone.clone(address(tokenImplementation)));
        tokenA.initialize(CONTEST_ID, 0, address(market), "XBID Contest A", "XBID-A");
        tokenB.initialize(CONTEST_ID, 1, address(market), "XBID Contest B", "XBID-B");
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

        usdc.mint(TRADER, 100_000_000_000_000);
        vm.prank(TRADER);
        usdc.approve(address(market), type(uint256).max);
    }

    function testCloneInitializationIsPermanentAndImplementationsAreLocked() external {
        assertEq(market.contestId(), CONTEST_ID);
        assertEq(market.marketVersion(), 1);
        assertEq(tokenA.marketVault(), address(market));
        assertEq(tokenB.marketVault(), address(market));
        assertEq(tokenA.decimals(), 18);

        vm.expectRevert();
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

        vm.expectRevert();
        marketImplementation.initialize(
            CONTEST_ID,
            1,
            CREATOR,
            address(usdc),
            address(tokenA),
            address(tokenB),
            address(riskController),
            address(feeVault)
        );
        vm.expectRevert();
        tokenImplementation.initialize(CONTEST_ID, 0, address(market), "x", "x");
    }

    function testBuyMatchesPreviewAndSeparatesReserveFromFee() external {
        XbidTradeMath.BuyResult memory quote = market.previewBuy(MarketVault.Side.A, BUY_GROSS);
        uint256 traderUsdcBefore = usdc.balanceOf(TRADER);

        vm.prank(TRADER);
        uint256 output = market.buy(MarketVault.Side.A, BUY_GROSS, quote.tokenOutputWei, block.timestamp, REFERRER);

        assertEq(output, quote.tokenOutputWei);
        assertEq(tokenA.balanceOf(TRADER), quote.tokenOutputWei);
        assertEq(tokenA.totalSupply(), market.qAWei());
        assertEq(tokenB.totalSupply(), market.qBWei());
        assertEq(usdc.balanceOf(TRADER), traderUsdcBefore - BUY_GROSS);
        assertEq(usdc.balanceOf(address(market)), quote.reserveAfterUnits);
        assertEq(usdc.balanceOf(address(feeVault)), quote.feeUnits);
        assertEq(feeVault.totalCredited(), quote.feeUnits);
        assertEq(market.referrerOf(TRADER), REFERRER);
        assertTrue(market.reserveUnits() >= market.requiredReserveUnits());
    }

    function testSellMatchesPreviewAndPaysExactNet() external {
        uint256 bought = _buyA(BUY_GROSS, REFERRER);
        uint256 input = bought / 2;
        XbidTradeMath.SellResult memory quote = market.previewSell(MarketVault.Side.A, input);
        uint256 traderUsdcBefore = usdc.balanceOf(TRADER);
        uint256 feeVaultBefore = usdc.balanceOf(address(feeVault));

        vm.startPrank(TRADER);
        tokenA.approve(address(market), input);
        uint256 net = market.sell(MarketVault.Side.A, input, quote.netOutputUnits, block.timestamp);
        vm.stopPrank();

        assertEq(net, quote.netOutputUnits);
        assertEq(usdc.balanceOf(TRADER), traderUsdcBefore + quote.netOutputUnits);
        assertEq(usdc.balanceOf(address(feeVault)), feeVaultBefore + quote.feeUnits);
        assertEq(tokenA.balanceOf(TRADER), bought - input);
        assertEq(tokenA.totalSupply(), market.qAWei());
        assertEq(usdc.balanceOf(address(market)), market.reserveUnits());
        assertTrue(market.reserveUnits() >= market.requiredReserveUnits());
    }

    function testSellAllRequiresExactExpectedBalance() external {
        uint256 bought = _buyA(BUY_GROSS, address(0));
        vm.prank(TRADER);
        tokenA.approve(address(market), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(MarketVault.BalanceChanged.selector, bought - 1, bought));
        vm.prank(TRADER);
        market.sellAll(MarketVault.Side.A, bought - 1, 0, block.timestamp);

        XbidTradeMath.SellResult memory quote = market.previewSellAll(MarketVault.Side.A, TRADER, bought);
        vm.prank(TRADER);
        uint256 net = market.sellAll(MarketVault.Side.A, bought, quote.netOutputUnits, block.timestamp);
        assertEq(net, quote.netOutputUnits);
        assertEq(tokenA.balanceOf(TRADER), 0);
        assertEq(market.qAWei(), 0);
        assertTrue(market.reserveUnits() <= 1);
    }

    function testFlipIsAtomicAndChargesExactlyOnce() external {
        uint256 bought = _buyA(BUY_GROSS, REFERRER);
        uint256 input = bought / 2;
        XbidTradeMath.FlipResult memory quote = market.previewFlip(MarketVault.Side.A, input);
        uint256 reserveBefore = market.reserveUnits();
        uint256 feeVaultBefore = usdc.balanceOf(address(feeVault));

        vm.startPrank(TRADER);
        tokenA.approve(address(market), input);
        uint256 output = market.flip(MarketVault.Side.A, input, quote.destinationTokenOutputWei, block.timestamp);
        vm.stopPrank();

        assertEq(output, quote.destinationTokenOutputWei);
        assertEq(tokenA.balanceOf(TRADER), bought - input);
        assertEq(tokenB.balanceOf(TRADER), output);
        assertEq(market.reserveUnits(), reserveBefore - quote.feeUnits);
        assertEq(usdc.balanceOf(address(feeVault)), feeVaultBefore + quote.feeUnits);
        assertEq(usdc.balanceOf(address(market)), market.reserveUnits());
    }

    function testDeadlineAndSlippageRevertBeforeStateChanges() external {
        XbidTradeMath.BuyResult memory quote = market.previewBuy(MarketVault.Side.A, BUY_GROSS);
        uint256 traderBefore = usdc.balanceOf(TRADER);

        vm.expectRevert(
            abi.encodeWithSelector(MarketVault.DeadlineExpired.selector, block.timestamp - 1, block.timestamp)
        );
        vm.prank(TRADER);
        market.buy(MarketVault.Side.A, BUY_GROSS, 0, block.timestamp - 1, address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                MarketVault.MinimumOutputNotMet.selector, quote.tokenOutputWei, quote.tokenOutputWei + 1
            )
        );
        vm.prank(TRADER);
        market.buy(MarketVault.Side.A, BUY_GROSS, quote.tokenOutputWei + 1, block.timestamp, address(0));

        assertEq(usdc.balanceOf(TRADER), traderBefore);
        assertEq(market.reserveUnits(), 0);
        assertEq(tokenA.totalSupply(), 0);
    }

    function testRiskOffKeepsSellAvailableAndFullPauseStopsIt() external {
        uint256 bought = _buyA(BUY_GROSS, address(0));
        vm.prank(TRADER);
        tokenA.approve(address(market), type(uint256).max);
        riskController.setMode(address(market), IRiskController.RiskMode.RiskOff);

        vm.expectRevert(abi.encodeWithSelector(MarketVault.ContestPaused.selector, IRiskController.RiskMode.RiskOff));
        market.previewBuy(MarketVault.Side.B, BUY_GROSS);
        vm.expectRevert(abi.encodeWithSelector(MarketVault.ContestPaused.selector, IRiskController.RiskMode.RiskOff));
        market.previewFlip(MarketVault.Side.A, bought / 2);

        XbidTradeMath.SellResult memory quote = market.previewSell(MarketVault.Side.A, bought / 2);
        vm.prank(TRADER);
        market.sell(MarketVault.Side.A, bought / 2, quote.netOutputUnits, block.timestamp);

        riskController.setMode(address(market), IRiskController.RiskMode.FullPause);
        vm.expectRevert(abi.encodeWithSelector(MarketVault.ContestPaused.selector, IRiskController.RiskMode.FullPause));
        market.previewSell(MarketVault.Side.A, 1);
    }

    function testReferralCannotBeSelfOrRebound() external {
        vm.expectRevert(abi.encodeWithSelector(MarketVault.InvalidReferrer.selector, TRADER));
        vm.prank(TRADER);
        market.buy(MarketVault.Side.A, BUY_GROSS, 0, block.timestamp, TRADER);

        _buyA(BUY_GROSS, REFERRER);
        vm.expectRevert(abi.encodeWithSelector(MarketVault.ReferrerAlreadyBound.selector, REFERRER, address(0xbeef)));
        vm.prank(TRADER);
        market.buy(MarketVault.Side.B, BUY_GROSS, 0, block.timestamp, address(0xbeef));
    }

    function testFeeVaultFailureRollsBackEntireBuy() external {
        feeVault.setRejectCredit(true);
        uint256 traderBefore = usdc.balanceOf(TRADER);

        vm.expectRevert(MockFeeVault.CreditRejected.selector);
        vm.prank(TRADER);
        market.buy(MarketVault.Side.A, BUY_GROSS, 0, block.timestamp, address(0));

        assertEq(usdc.balanceOf(TRADER), traderBefore);
        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(usdc.balanceOf(address(feeVault)), 0);
        assertEq(market.reserveUnits(), 0);
        assertEq(tokenA.totalSupply(), 0);
    }

    function testReentrancyFromFeeVaultRollsBackEntireBuy() external {
        bytes memory callData =
            abi.encodeCall(MarketVault.buy, (MarketVault.Side.B, 1_000_000, 0, block.timestamp, address(0)));
        feeVault.setReentry(true, callData);
        uint256 traderBefore = usdc.balanceOf(TRADER);

        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        vm.prank(TRADER);
        market.buy(MarketVault.Side.A, BUY_GROSS, 0, block.timestamp, address(0));

        assertEq(usdc.balanceOf(TRADER), traderBefore);
        assertEq(market.reserveUnits(), 0);
        assertEq(tokenA.totalSupply(), 0);
    }

    function testRejectsFeeOnTransferSettlementByExactBalanceDelta() external {
        usdc.setTransferFeeBps(100);
        uint256 expectedReceived = BUY_GROSS - BUY_GROSS / 100;
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketVault.UnexpectedBalanceDelta.selector, address(usdc), address(market), BUY_GROSS, expectedReceived
            )
        );
        vm.prank(TRADER);
        market.buy(MarketVault.Side.A, BUY_GROSS, 0, block.timestamp, address(0));

        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(market.reserveUnits(), 0);
    }

    function testDonationIsSurplusAndDoesNotIncreaseRecordedReserve() external {
        _buyA(BUY_GROSS, address(0));
        uint256 recordedReserve = market.reserveUnits();
        usdc.mint(address(market), 123_456_789);

        assertEq(market.reserveUnits(), recordedReserve);
        assertEq(usdc.balanceOf(address(market)), recordedReserve + 123_456_789);
        assertTrue(market.reserveUnits() >= market.requiredReserveUnits());
    }

    function testOnlyMarketCanMintOrBurnSideTokens() external {
        vm.expectRevert(SideToken.Unauthorized.selector);
        tokenA.mintTo(TRADER, 1);
        vm.expectRevert(SideToken.Unauthorized.selector);
        tokenA.burnHeld(1);
    }

    function testSideTokenSupportsCloneSpecificErc2612Permit() external {
        uint256 ownerKey = 0x123456;
        address owner = vm.addr(ownerKey);
        uint256 value = 987e18;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, address(market), value, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tokenA.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        tokenA.permit(owner, address(market), value, deadline, v, r, s);

        assertEq(tokenA.allowance(owner, address(market)), value);
        assertEq(tokenA.nonces(owner), 1);
        assertTrue(tokenA.DOMAIN_SEPARATOR() != tokenB.DOMAIN_SEPARATOR());
    }

    function testRejectsFeeOnTransferSettlementOnSellAndRollsBack() external {
        uint256 bought = _buyA(BUY_GROSS, address(0));
        uint256 input = bought / 2;
        XbidTradeMath.SellResult memory quote = market.previewSell(MarketVault.Side.A, input);
        uint256 expectedFeeReceived = quote.feeUnits - quote.feeUnits / 100;
        uint256 reserveBefore = market.reserveUnits();
        uint256 traderUsdcBefore = usdc.balanceOf(TRADER);
        uint256 supplyBefore = tokenA.totalSupply();
        usdc.setTransferFeeBps(100);

        vm.startPrank(TRADER);
        tokenA.approve(address(market), input);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketVault.UnexpectedBalanceDelta.selector,
                address(usdc),
                address(feeVault),
                quote.feeUnits,
                expectedFeeReceived
            )
        );
        market.sell(MarketVault.Side.A, input, 0, block.timestamp);
        vm.stopPrank();

        assertEq(market.reserveUnits(), reserveBefore);
        assertEq(usdc.balanceOf(TRADER), traderUsdcBefore);
        assertEq(tokenA.totalSupply(), supplyBefore);
        assertEq(tokenA.balanceOf(TRADER), bought);
    }

    function testFuzzBuyThenSellAllPreservesSolvency(uint96 grossSeed, bool sideA) external {
        uint256 gross = 1_000_000 + uint256(grossSeed) % 1_000_000_000_000;
        MarketVault.Side side = sideA ? MarketVault.Side.A : MarketVault.Side.B;
        XbidTradeMath.BuyResult memory buyQuote = market.previewBuy(side, gross);

        vm.startPrank(TRADER);
        market.buy(side, gross, buyQuote.tokenOutputWei, block.timestamp, address(0));
        SideToken token = sideA ? tokenA : tokenB;
        token.approve(address(market), buyQuote.tokenOutputWei);
        XbidTradeMath.SellResult memory sellQuote = market.previewSellAll(side, TRADER, buyQuote.tokenOutputWei);
        market.sellAll(side, buyQuote.tokenOutputWei, sellQuote.netOutputUnits, block.timestamp);
        vm.stopPrank();

        assertEq(token.totalSupply(), 0);
        assertTrue(market.reserveUnits() >= market.requiredReserveUnits());
        assertTrue(usdc.balanceOf(address(market)) >= market.reserveUnits());
    }

    function _buyA(uint256 gross, address referrer) private returns (uint256 output) {
        XbidTradeMath.BuyResult memory quote = market.previewBuy(MarketVault.Side.A, gross);
        vm.prank(TRADER);
        output = market.buy(MarketVault.Side.A, gross, quote.tokenOutputWei, block.timestamp, referrer);
    }
}
