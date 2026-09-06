// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {XbidCrownMathV2} from "../../src/libraries/XbidCrownMathV2.sol";
import {XbidLmsrMath} from "../../src/libraries/XbidLmsrMath.sol";
import {XbidLmsrMathV2} from "../../src/libraries/XbidLmsrMathV2.sol";
import {XbidTradeMathV2} from "../../src/libraries/XbidTradeMathV2.sol";

contract MarketV2MathHarness {
    function bV1() external pure returns (int256) {
        return XbidLmsrMath.bWad();
    }

    function bV2() external pure returns (int256) {
        return XbidLmsrMathV2.bWad();
    }

    function pricesV1(uint256 qAWei, uint256 qBWei) external pure returns (uint256, uint256, uint256) {
        return XbidLmsrMath.pricesWad(qAWei, qBWei);
    }

    function pricesV2(uint256 qAWei, uint256 qBWei) external pure returns (uint256, uint256, uint256) {
        return XbidLmsrMathV2.pricesWad(qAWei, qBWei);
    }

    function requiredReserveV2(uint256 qAWei, uint256 qBWei) external pure returns (uint256) {
        return XbidTradeMathV2.requiredReserveUnits(qAWei, qBWei);
    }

    function quoteBuyV2(uint256 qAWei, uint256 qBWei, uint256 reserveUnits, bool sideA, uint256 grossInputUnits)
        external
        pure
        returns (XbidTradeMathV2.BuyResult memory)
    {
        return XbidTradeMathV2.quoteBuy(qAWei, qBWei, reserveUnits, sideA, grossInputUnits);
    }

    function quoteFlipV2(
        uint256 qAWei,
        uint256 qBWei,
        uint256 reserveUnits,
        bool sourceSideA,
        uint256 sourceTokenInputWei
    ) external pure returns (XbidTradeMathV2.FlipResult memory) {
        return XbidTradeMathV2.quoteFlip(qAWei, qBWei, reserveUnits, sourceSideA, sourceTokenInputWei);
    }

    function challengerAtLeast48(uint256 challengerQuantityWei, uint256 crownQuantityWei) external pure returns (bool) {
        return XbidCrownMathV2.challengerAtLeast48(challengerQuantityWei, crownQuantityWei);
    }

    function challengerAtLeast52(uint256 challengerQuantityWei, uint256 crownQuantityWei) external pure returns (bool) {
        return XbidCrownMathV2.challengerAtLeast52(challengerQuantityWei, crownQuantityWei);
    }

    function crownAtLeast55(uint256 crownQuantityWei, uint256 challengerQuantityWei) external pure returns (bool) {
        return XbidCrownMathV2.crownAtLeast55(crownQuantityWei, challengerQuantityWei);
    }

    function challengerStrictlyBelow45(uint256 challengerQuantityWei, uint256 crownQuantityWei)
        external
        pure
        returns (bool)
    {
        return XbidCrownMathV2.challengerStrictlyBelow45(challengerQuantityWei, crownQuantityWei);
    }
}

contract MarketV2MathTest is Test {
    MarketV2MathHarness private immutable MATH = new MarketV2MathHarness();

    function testVersionTwoUsesB150kAndMovesFasterThanVersionOne() external {
        assertEq(MATH.bV1(), 270_000e18);
        assertEq(MATH.bV2(), 150_000e18);

        (uint256 initialA, uint256 initialB, uint256 initialNeutral) = MATH.pricesV2(0, 0);
        assertEq(initialA, 0.01e18);
        assertEq(initialB, 0.01e18);
        assertApproxEqAbs(initialNeutral, 0.98e18, 8);

        (uint256 v1PriceA,,) = MATH.pricesV1(100_000e18, 0);
        (uint256 v2PriceA,,) = MATH.pricesV2(100_000e18, 0);
        assertGt(v2PriceA, v1PriceA);
    }

    function testVersionTwoCrownBoundariesAreExactAtIntegerWei() external {
        uint256 base = 100_000e18;

        assertFalse(MATH.challengerAtLeast48(base, base + 12_006_406_151_030_463_873_567));
        assertTrue(MATH.challengerAtLeast48(base, base + 12_006_406_151_030_463_873_566));

        assertFalse(MATH.challengerAtLeast52(base + 12_006_406_151_030_463_873_566, base));
        assertTrue(MATH.challengerAtLeast52(base + 12_006_406_151_030_463_873_567, base));

        assertFalse(MATH.crownAtLeast55(base + 30_100_604_319_322_674_190_717, base));
        assertTrue(MATH.crownAtLeast55(base + 30_100_604_319_322_674_190_718, base));

        assertFalse(MATH.challengerStrictlyBelow45(base, base + 30_100_604_319_322_674_190_717));
        assertTrue(MATH.challengerStrictlyBelow45(base, base + 30_100_604_319_322_674_190_718));
    }

    function testVersionTwoLargeBuyCrossesFormerExponentBoundary() external {
        XbidTradeMathV2.BuyResult memory buy = MATH.quoteBuyV2(0, 0, 0, true, 21_000_000e6);
        assertApproxEqAbs(buy.tokenOutputWei, 21_480_775_527_898_213_705_205_397, 1e12);
        assertGt(buy.tokenOutputWei, 20_000_000e18);
        assertLt(buy.qAAfterWei, 30_000_000e18);
        assertGe(buy.reserveAfterUnits, MATH.requiredReserveV2(buy.qAAfterWei, buy.qBAfterWei));
    }

    function testVersionTwoSequentialLargeBuyRemainsExecutable() external {
        XbidTradeMathV2.BuyResult memory first = MATH.quoteBuyV2(0, 0, 0, true, 19_000_000e6);
        XbidTradeMathV2.BuyResult memory second =
            MATH.quoteBuyV2(first.qAAfterWei, first.qBAfterWei, first.reserveAfterUnits, true, 1_000_000e6);
        assertGt(second.tokenOutputWei, 0);
        assertGt(second.qAAfterWei, first.qAAfterWei);
        assertGe(second.reserveAfterUnits, MATH.requiredReserveV2(second.qAAfterWei, second.qBAfterWei));
    }

    function testVersionTwoMinimumBuyAtMaximumOpposingSkewStaysInDomain() external {
        uint256 maximum = 30_000_000e18;
        uint256 reserve = MATH.requiredReserveV2(0, maximum);
        XbidTradeMathV2.BuyResult memory buy = MATH.quoteBuyV2(0, maximum, reserve, true, 1e6);
        assertApproxEqAbs(buy.tokenOutputWei, 28_210_734_358_660_488_113_512_272, 1e12);
        assertGt(buy.qAAfterWei, 26_000_000e18);
        assertLe(buy.qAAfterWei, maximum);
        assertGe(buy.reserveAfterUnits, MATH.requiredReserveV2(buy.qAAfterWei, buy.qBAfterWei));
    }

    function testVersionTwoRejectsOnlyActualCurveCapacityOverflow() external {
        uint256 curveInputWad = 29_700_000e18;
        uint256 maximumInputWad = XbidLmsrMathV2.costWad(30_000_000e18, 0);
        vm.expectRevert(
            abi.encodeWithSelector(XbidTradeMathV2.CurveInputExceedsCapacity.selector, curveInputWad, maximumInputWad)
        );
        MATH.quoteBuyV2(0, 0, 0, true, 30_000_000e6);
    }

    function testVersionTwoMaximumPositionCanFlipAcrossFormerExponentBoundary() external {
        uint256 maximum = 30_000_000e18;
        uint256 reserve = MATH.requiredReserveV2(maximum, 0);
        XbidTradeMathV2.FlipResult memory flip = MATH.quoteFlipV2(maximum, 0, reserve, true, maximum);
        assertEq(flip.qAAfterWei, 0);
        assertGt(flip.qBAfterWei, 20_000_000e18);
        assertLe(flip.qBAfterWei, maximum);
        assertGe(flip.reserveAfterUnits, MATH.requiredReserveV2(flip.qAAfterWei, flip.qBAfterWei));
    }

    function testFuzzVersionTwoEmptyMarketBuyCoversFullExecutableCapacity(uint256 seed, bool sideA) external {
        // 29.6m gross produces 29.304m Curve input, immediately below the
        // declared 29.309m empty-market single-side capacity.
        uint256 gross = 1e6 + seed % (29_600_000e6 - 1e6 + 1);
        XbidTradeMathV2.BuyResult memory buy = MATH.quoteBuyV2(0, 0, 0, sideA, gross);
        assertGt(buy.tokenOutputWei, 0);
        assertLe(buy.qAAfterWei, 30_000_000e18);
        assertLe(buy.qBAfterWei, 30_000_000e18);
        assertGe(buy.reserveAfterUnits, MATH.requiredReserveV2(buy.qAAfterWei, buy.qBAfterWei));
    }

    function testFuzzVersionTwoArbitraryStateBuyRemainsInDomain(
        uint256 qASeed,
        uint256 qBSeed,
        uint256 grossSeed,
        bool sideA
    ) external {
        uint256 maximum = 30_000_000e18;
        uint256 qAWei = qASeed % (maximum + 1);
        uint256 qBWei = qBSeed % (maximum + 1);
        uint256 currentCostWad = XbidLmsrMathV2.costWad(qAWei, qBWei);
        uint256 maximumCostWad = XbidLmsrMathV2.costWad(sideA ? maximum : qAWei, sideA ? qBWei : maximum);
        uint256 conservativeMaximumGrossUnits = (maximumCostWad - currentCostWad) / 1e12;
        if (conservativeMaximumGrossUnits < 1e6) return;
        uint256 gross = 1e6 + grossSeed % (conservativeMaximumGrossUnits - 1e6 + 1);
        uint256 reserve = MATH.requiredReserveV2(qAWei, qBWei);
        XbidTradeMathV2.BuyResult memory buy = MATH.quoteBuyV2(qAWei, qBWei, reserve, sideA, gross);
        assertGt(buy.tokenOutputWei, 0);
        assertLe(buy.qAAfterWei, maximum);
        assertLe(buy.qBAfterWei, maximum);
        assertGe(buy.reserveAfterUnits, MATH.requiredReserveV2(buy.qAAfterWei, buy.qBAfterWei));
    }
}
