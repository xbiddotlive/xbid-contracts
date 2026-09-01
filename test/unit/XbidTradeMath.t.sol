// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {XbidTradeMath} from "../../src/libraries/XbidTradeMath.sol";

contract XbidTradeMathHarness {
    function requiredReserveUnits(uint256 qAWei, uint256 qBWei) external pure returns (uint256) {
        return XbidTradeMath.requiredReserveUnits(qAWei, qBWei);
    }

    function tradingFeeUnits(uint256 grossUnits) external pure returns (uint256) {
        return XbidTradeMath.tradingFeeUnits(grossUnits);
    }

    function quoteBuy(uint256 qAWei, uint256 qBWei, uint256 reserveUnits, bool sideA, uint256 grossInputUnits)
        external
        pure
        returns (XbidTradeMath.BuyResult memory)
    {
        return XbidTradeMath.quoteBuy(qAWei, qBWei, reserveUnits, sideA, grossInputUnits);
    }

    function quoteSell(
        uint256 qAWei,
        uint256 qBWei,
        uint256 reserveUnits,
        bool sideA,
        uint256 tokenInputWei,
        bool sellAll
    ) external pure returns (XbidTradeMath.SellResult memory) {
        return XbidTradeMath.quoteSell(qAWei, qBWei, reserveUnits, sideA, tokenInputWei, sellAll);
    }

    function quoteFlip(
        uint256 qAWei,
        uint256 qBWei,
        uint256 reserveUnits,
        bool sourceSideA,
        uint256 sourceTokenInputWei
    ) external pure returns (XbidTradeMath.FlipResult memory) {
        return XbidTradeMath.quoteFlip(qAWei, qBWei, reserveUnits, sourceSideA, sourceTokenInputWei);
    }
}

contract XbidTradeMathTest {
    uint256 private constant TOKEN_TOLERANCE_WEI = 100_000_000_000;
    uint256 private constant MAX_Q = 30_000_000e18;
    XbidTradeMathHarness private immutable MATH = new XbidTradeMathHarness();

    function testFeeAlwaysRoundsUp() external view {
        require(MATH.tradingFeeUnits(100_000_000) == 1_000_000, "exact fee");
        require(MATH.tradingFeeUnits(1_000_001) == 10_001, "ceil fee");
    }

    function testBuyMatchesCanonicalAndRemainsSolvent() external view {
        XbidTradeMath.BuyResult memory result = MATH.quoteBuy(0, 0, 0, true, 100_000_000);

        require(result.feeUnits == 1_000_000, "buy fee");
        require(result.curveInputUnits == 99_000_000, "curve input");
        _assertApprox(result.tokenOutputWei, 9_724_569_143_406_335_335_127, TOKEN_TOLERANCE_WEI);
        require(result.reserveAfterUnits == 99_000_000, "buy reserve");
        _assertSolvent(result.qAAfterWei, result.qBAfterWei, result.reserveAfterUnits);
    }

    function testMinimumBuyMatchesCanonicalRoundingVector() external view {
        XbidTradeMath.BuyResult memory result = MATH.quoteBuy(0, 0, 0, true, 1_000_000);

        require(result.feeUnits == 10_000, "minimum buy fee");
        require(result.curveInputUnits == 990_000, "minimum curve input");
        _assertApprox(result.tokenOutputWei, 98_982_035_869_143_025_105, TOKEN_TOLERANCE_WEI);
        require(result.reserveAfterUnits == 990_000, "minimum reserve");
        _assertSolvent(result.qAAfterWei, result.qBAfterWei, result.reserveAfterUnits);
    }

    function testSellUsesFloorGrossAndCeilFee() external view {
        XbidTradeMath.BuyResult memory buy = MATH.quoteBuy(0, 0, 0, true, 10_000_000_000);
        XbidTradeMath.SellResult memory sell =
            MATH.quoteSell(buy.qAAfterWei, buy.qBAfterWei, buy.reserveAfterUnits, true, buy.tokenOutputWei, true);

        require(sell.qAAfterWei == 0, "sell all supply");
        require(sell.feeUnits == (sell.grossOutputUnits + 99) / 100, "sell ceil fee");
        require(sell.netOutputUnits == sell.grossOutputUnits - sell.feeUnits, "sell net");
        _assertSolvent(sell.qAAfterWei, sell.qBAfterWei, sell.reserveAfterUnits);
    }

    function testFlipChargesOnceAndReserveFallsOnlyByFee() external view {
        XbidTradeMath.BuyResult memory buy = MATH.quoteBuy(0, 0, 0, true, 10_000_000_000);
        XbidTradeMath.FlipResult memory flip =
            MATH.quoteFlip(buy.qAAfterWei, buy.qBAfterWei, buy.reserveAfterUnits, true, buy.tokenOutputWei / 2);

        require(flip.destinationCurveInputUnits == flip.sourceGrossOutputUnits - flip.feeUnits, "flip curve input");
        require(flip.reserveAfterUnits == buy.reserveAfterUnits - flip.feeUnits, "flip reserve delta");
        require(flip.feeUnits == (flip.sourceGrossOutputUnits + 99) / 100, "single flip fee");
        require(flip.sourceGrossOutputUnits == 6_743_483_237, "canonical flip gross");
        _assertApprox(flip.destinationTokenOutputWei, 340_770_002_566_008_393_724_007, TOKEN_TOLERANCE_WEI);
        _assertSolvent(flip.qAAfterWei, flip.qBAfterWei, flip.reserveAfterUnits);
    }

    function testRoundTripCannotDrainReserve() external view {
        XbidTradeMath.BuyResult memory buy = MATH.quoteBuy(0, 0, 0, false, 1_000_000);
        XbidTradeMath.SellResult memory sell =
            MATH.quoteSell(buy.qAAfterWei, buy.qBAfterWei, buy.reserveAfterUnits, false, buy.tokenOutputWei, true);

        require(sell.reserveAfterUnits <= 1, "unexpected round-trip dust");
        _assertSolvent(sell.qAAfterWei, sell.qBAfterWei, sell.reserveAfterUnits);
    }

    function testExtremeSkewBuyUsesRelativeInverseSafely() external view {
        uint256 reserveUnits = MATH.requiredReserveUnits(0, MAX_Q);
        XbidTradeMath.BuyResult memory buy = MATH.quoteBuy(0, MAX_Q, reserveUnits, true, 1_000_000);

        require(buy.qAAfterWei > 26_000_000e18, "low-price side did not advance");
        require(buy.qAAfterWei <= MAX_Q, "extreme buy above maximum");
        _assertSolvent(buy.qAAfterWei, buy.qBAfterWei, buy.reserveAfterUnits);
    }

    function testMaximumSkewCanSellAllAndFlip() external view {
        uint256 reserveUnits = MATH.requiredReserveUnits(MAX_Q, 0);
        XbidTradeMath.SellResult memory sell = MATH.quoteSell(MAX_Q, 0, reserveUnits, true, MAX_Q, true);
        require(sell.qAAfterWei == 0, "maximum sell all supply");
        _assertSolvent(sell.qAAfterWei, sell.qBAfterWei, sell.reserveAfterUnits);

        XbidTradeMath.FlipResult memory flip = MATH.quoteFlip(MAX_Q, 0, reserveUnits, true, MAX_Q);
        require(flip.qAAfterWei == 0, "maximum flip source supply");
        require(flip.qBAfterWei <= MAX_Q, "maximum flip destination supply");
        _assertSolvent(flip.qAAfterWei, flip.qBAfterWei, flip.reserveAfterUnits);
    }

    function testRejectsInsolventInputState() external view {
        try MATH.quoteBuy(419_828_990_066_228_440_540_674, 0, 9_899_999_999, true, 1_000_000) returns (
            XbidTradeMath.BuyResult memory
        ) {
            revert("accepted insolvent state");
        } catch {}
    }

    function testFuzzBuyReserveInvariant(uint256 grossSeed, bool sideA) external view {
        uint256 grossInputUnits = 1_000_000 + (grossSeed % 1_000_000_000_000);
        XbidTradeMath.BuyResult memory buy = MATH.quoteBuy(0, 0, 0, sideA, grossInputUnits);
        require(buy.reserveAfterUnits == buy.curveInputUnits, "buy reserve identity");
        _assertSolvent(buy.qAAfterWei, buy.qBAfterWei, buy.reserveAfterUnits);
    }

    function testFuzzBuyThenSellAllReserveInvariant(uint256 grossSeed, bool sideA) external view {
        uint256 grossInputUnits = 1_000_000 + (grossSeed % 1_000_000_000_000);
        XbidTradeMath.BuyResult memory buy = MATH.quoteBuy(0, 0, 0, sideA, grossInputUnits);
        XbidTradeMath.SellResult memory sell =
            MATH.quoteSell(buy.qAAfterWei, buy.qBAfterWei, buy.reserveAfterUnits, sideA, buy.tokenOutputWei, true);
        _assertSolvent(sell.qAAfterWei, sell.qBAfterWei, sell.reserveAfterUnits);
    }

    function testFuzzMixedSequence(uint256 firstSeed, uint256 secondSeed) external view {
        uint256 firstGross = 100_000_000 + (firstSeed % 100_000_000_000);
        uint256 secondGross = 100_000_000 + (secondSeed % 100_000_000_000);
        XbidTradeMath.BuyResult memory buyA = MATH.quoteBuy(0, 0, 0, true, firstGross);
        XbidTradeMath.BuyResult memory buyB =
            MATH.quoteBuy(buyA.qAAfterWei, buyA.qBAfterWei, buyA.reserveAfterUnits, false, secondGross);

        XbidTradeMath.FlipResult memory flip =
            MATH.quoteFlip(buyB.qAAfterWei, buyB.qBAfterWei, buyB.reserveAfterUnits, false, buyB.tokenOutputWei);
        require(flip.reserveAfterUnits == buyB.reserveAfterUnits - flip.feeUnits, "mixed flip reserve");
        _assertSolvent(flip.qAAfterWei, flip.qBAfterWei, flip.reserveAfterUnits);
    }

    function _assertSolvent(uint256 qAWei, uint256 qBWei, uint256 reserveUnits) private view {
        require(reserveUnits >= MATH.requiredReserveUnits(qAWei, qBWei), "reserve below ceil cost");
    }

    function _assertApprox(uint256 actual, uint256 expected, uint256 tolerance) private pure {
        uint256 difference = actual >= expected ? actual - expected : expected - actual;
        require(difference <= tolerance, "outside canonical tolerance");
    }
}
