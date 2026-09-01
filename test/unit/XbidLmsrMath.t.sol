// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {XbidLmsrMath} from "../../src/libraries/XbidLmsrMath.sol";

contract XbidLmsrMathHarness {
    function logPartitionWad(uint256 qAWei, uint256 qBWei) external pure returns (int256) {
        return XbidLmsrMath.logPartitionWad(qAWei, qBWei);
    }

    function costWad(uint256 qAWei, uint256 qBWei) external pure returns (uint256) {
        return XbidLmsrMath.costWad(qAWei, qBWei);
    }

    function pricesWad(uint256 qAWei, uint256 qBWei) external pure returns (uint256, uint256, uint256) {
        return XbidLmsrMath.pricesWad(qAWei, qBWei);
    }
}

contract XbidLmsrMathTest {
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_Q = 30_000_000e18;
    uint256 private constant PRICE_SUM_TOLERANCE = 8;
    uint256 private constant REFERENCE_COST_TOLERANCE = 20_000_000;

    XbidLmsrMathHarness private immutable MATH = new XbidLmsrMathHarness();

    function testInitialStateIsExact() external view {
        require(MATH.costWad(0, 0) == 0, "initial cost");
        _assertApproxSigned(MATH.logPartitionWad(0, 0), 4_605_170_185_988_091_368, 64);

        (uint256 priceA, uint256 priceB, uint256 neutral) = MATH.pricesWad(0, 0);
        require(priceA == 0.01e18, "initial A price");
        require(priceB == 0.01e18, "initial B price");
        _assertApprox(neutral, 0.98e18, 8);
        _assertApprox(priceA + priceB + neutral, WAD, PRICE_SUM_TOLERANCE);
    }

    function testCanonicalMixedState() external view {
        uint256 qA = 419_828_990_066_228_440_540_674;
        uint256 qB = 289_266_855_331_671_009_612_044;

        _assertApproxSigned(MATH.logPartitionWad(qA, qB), 4_660_170_185_988_091_368, 64);
        _assertApprox(MATH.costWad(qA, qB), 14_850_000_000_000_000_000_000, REFERENCE_COST_TOLERANCE);

        (uint256 priceA, uint256 priceB, uint256 neutral) = MATH.pricesWad(qA, qB);
        _assertApprox(priceA, 44_813_403_432_005_167, 128);
        _assertApprox(priceB, 27_631_151_573_580_640, 128);
        _assertApprox(neutral, 927_555_444_994_414_192, 128);
        _assertApprox(priceA + priceB + neutral, WAD, PRICE_SUM_TOLERANCE);
    }

    function testSubWadPlateauCannotProduceNegativeCost() external view {
        require(MATH.costWad(1, 0) == 0, "one-wei cost");
        require(MATH.costWad(425, 0) == 0, "sub-WAD plateau cost");
    }

    function testMaximumBalancedBoundary() external view {
        _assertApproxSigned(MATH.logPartitionWad(MAX_Q, MAX_Q), 111_804_258_291_671_056_421, 64);
        _assertApprox(MATH.costWad(MAX_Q, MAX_Q), 28_943_753_788_534_400_564_172_937, REFERENCE_COST_TOLERANCE);

        (uint256 priceA, uint256 priceB, uint256 neutral) = MATH.pricesWad(MAX_Q, MAX_Q);
        require(priceA == 0.5e18, "max A price");
        require(priceB == 0.5e18, "max B price");
        require(neutral == 0, "max neutral underflow");
    }

    function testMaximumSkewBoundary() external view {
        _assertApproxSigned(MATH.logPartitionWad(MAX_Q, 0), 111_111_111_111_111_111_111, 64);
        _assertApprox(MATH.costWad(MAX_Q, 0), 28_756_604_049_783_215_330_630_285, REFERENCE_COST_TOLERANCE);

        (uint256 priceA, uint256 priceB, uint256 neutral) = MATH.pricesWad(MAX_Q, 0);
        require(priceA == WAD, "max skew A price");
        require(priceB == 0, "max skew B underflow");
        require(neutral == 0, "max skew neutral underflow");
    }

    function testRejectsQuantityAboveBoundary() external view {
        try MATH.costWad(MAX_Q + 1, 0) returns (uint256) {
            revert("cost accepted q above max");
        } catch {}

        try MATH.pricesWad(0, MAX_Q + 1) returns (uint256, uint256, uint256) {
            revert("prices accepted q above max");
        } catch {}
    }

    function testFuzzSymmetry(uint256 qASeed, uint256 qBSeed) external view {
        uint256 qA = qASeed % (MAX_Q + 1);
        uint256 qB = qBSeed % (MAX_Q + 1);

        require(MATH.logPartitionWad(qA, qB) == MATH.logPartitionWad(qB, qA), "logZ symmetry");
        require(MATH.costWad(qA, qB) == MATH.costWad(qB, qA), "cost symmetry");

        (uint256 priceA, uint256 priceB, uint256 neutral) = MATH.pricesWad(qA, qB);
        (uint256 swappedA, uint256 swappedB, uint256 swappedNeutral) = MATH.pricesWad(qB, qA);
        require(priceA == swappedB, "A/B symmetry");
        require(priceB == swappedA, "B/A symmetry");
        require(neutral == swappedNeutral, "neutral symmetry");
    }

    function testFuzzCostIsMonotonic(uint256 qASeed, uint256 qBSeed, uint256 deltaSeed) external view {
        uint256 qA = qASeed % (MAX_Q + 1);
        uint256 qB = qBSeed % (MAX_Q + 1);
        uint256 delta = deltaSeed % (MAX_Q - qA + 1);

        require(MATH.costWad(qA + delta, qB) >= MATH.costWad(qA, qB), "cost not monotonic");
    }

    function testFuzzPricesStayNormalized(uint256 qASeed, uint256 qBSeed) external view {
        uint256 qA = qASeed % (MAX_Q + 1);
        uint256 qB = qBSeed % (MAX_Q + 1);
        (uint256 priceA, uint256 priceB, uint256 neutral) = MATH.pricesWad(qA, qB);

        require(priceA <= WAD && priceB <= WAD && neutral <= WAD, "price above one");
        _assertApprox(priceA + priceB + neutral, WAD, PRICE_SUM_TOLERANCE);
    }

    function _assertApprox(uint256 actual, uint256 expected, uint256 tolerance) private pure {
        uint256 difference = actual >= expected ? actual - expected : expected - actual;
        require(difference <= tolerance, "outside unsigned tolerance");
    }

    function _assertApproxSigned(int256 actual, int256 expected, int256 tolerance) private pure {
        int256 difference = actual >= expected ? actual - expected : expected - actual;
        require(difference <= tolerance, "outside signed tolerance");
    }
}
