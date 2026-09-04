// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {XbidCrownMathV2} from "../../src/libraries/XbidCrownMathV2.sol";
import {XbidLmsrMath} from "../../src/libraries/XbidLmsrMath.sol";
import {XbidLmsrMathV2} from "../../src/libraries/XbidLmsrMathV2.sol";

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
}
