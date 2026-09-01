// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PrbMathCandidate} from "../../src/libraries/benchmark/PrbMathCandidate.sol";
import {SoladyMathCandidate} from "../../src/libraries/benchmark/SoladyMathCandidate.sol";

contract PrbMathHarness {
    function expWad(int256 x) external pure returns (int256) {
        return PrbMathCandidate.expWad(x);
    }

    function lnWad(int256 x) external pure returns (int256) {
        return PrbMathCandidate.lnWad(x);
    }

    function logPartitionWad(int256 qAWad, int256 qBWad) external pure returns (int256) {
        return PrbMathCandidate.logPartitionWad(qAWad, qBWad);
    }

    function costWad(int256 qAWad, int256 qBWad) external pure returns (int256) {
        return PrbMathCandidate.costWad(qAWad, qBWad);
    }

    function pricesWad(int256 qAWad, int256 qBWad) external pure returns (int256, int256, int256) {
        return PrbMathCandidate.pricesWad(qAWad, qBWad);
    }
}

contract SoladyMathHarness {
    function expWad(int256 x) external pure returns (int256) {
        return SoladyMathCandidate.expWad(x);
    }

    function lnWad(int256 x) external pure returns (int256) {
        return SoladyMathCandidate.lnWad(x);
    }

    function logPartitionWad(int256 qAWad, int256 qBWad) external pure returns (int256) {
        return SoladyMathCandidate.logPartitionWad(qAWad, qBWad);
    }

    function costWad(int256 qAWad, int256 qBWad) external pure returns (int256) {
        return SoladyMathCandidate.costWad(qAWad, qBWad);
    }

    function pricesWad(int256 qAWad, int256 qBWad) external pure returns (int256, int256, int256) {
        return SoladyMathCandidate.pricesWad(qAWad, qBWad);
    }
}

contract FixedPointMathCandidatesTest {
    struct Scenario {
        int256 qAWad;
        int256 qBWad;
        int256 expectedLogZ;
        int256 expectedCost;
        int256 expectedPriceA;
        int256 expectedPriceB;
        int256 expectedNeutral;
    }

    int256 private constant PRIMITIVE_TOLERANCE_WAD = 64;
    int256 private constant LOG_PARTITION_TOLERANCE_WAD = 64;
    int256 private constant COST_TOLERANCE_WAD = 20_000_000;
    int256 private constant PRICE_TOLERANCE_WAD = 128;

    PrbMathHarness private immutable PRB = new PrbMathHarness();
    SoladyMathHarness private immutable SOLADY = new SoladyMathHarness();

    function testExpMatchesCanonicalVectors() external view {
        int256[5] memory inputs = [int256(-40e18), -20e18, -5e18, -1e18, int256(0)];
        int256[5] memory expected = [int256(4), 2_061_153_622, 6_737_946_999_085_467, 367_879_441_171_442_322, 1e18];

        for (uint256 i = 0; i < inputs.length; ++i) {
            _assertApprox(PRB.expWad(inputs[i]), expected[i], PRIMITIVE_TOLERANCE_WAD);
            _assertApprox(SOLADY.expWad(inputs[i]), expected[i], PRIMITIVE_TOLERANCE_WAD);
        }
    }

    function testLnMatchesCanonicalVectors() external view {
        int256[5] memory inputs = [int256(1), 1e16, 1e18, 98e18, 100e18];
        int256[5] memory expected = [
            int256(-41_446_531_673_892_822_312),
            -4_605_170_185_988_091_368,
            int256(0),
            4_584_967_478_670_571_920,
            4_605_170_185_988_091_368
        ];

        for (uint256 i = 0; i < inputs.length; ++i) {
            _assertApprox(PRB.lnWad(inputs[i]), expected[i], PRIMITIVE_TOLERANCE_WAD);
            _assertApprox(SOLADY.lnWad(inputs[i]), expected[i], PRIMITIVE_TOLERANCE_WAD);
        }
    }

    function testLmsrMatchesCanonicalVectors() external view {
        _assertScenario(
            Scenario(
                0,
                0,
                4_605_170_185_988_091_368,
                0,
                10_000_000_000_000_000,
                10_000_000_000_000_000,
                980_000_000_000_000_000
            )
        );
        _assertScenario(
            Scenario(
                9_724_569_143_406_335_335_127,
                0,
                4_605_536_852_654_758_035,
                99_000_000_000_000_000_000,
                10_362_933_458_133_143,
                9_996_334_005_473_403,
                979_640_732_536_393_454
            )
        );
        _assertScenario(
            Scenario(
                419_828_990_066_228_440_540_674,
                0,
                4_641_836_852_654_758_035,
                9_900_000_000_000_000_000_000,
                45_642_559_871_694_828,
                9_639_974_142_710_153,
                944_717_465_985_595_018
            )
        );
        _assertScenario(
            Scenario(
                419_828_990_066_228_440_540_674,
                289_266_855_331_671_009_612_044,
                4_660_170_185_988_091_368,
                14_850_000_000_000_000_000_000,
                44_813_403_432_005_167,
                27_631_151_573_580_640,
                927_555_444_994_414_192
            )
        );
        _assertScenario(
            Scenario(
                30_000_000e18,
                30_000_000e18,
                111_804_258_291_671_056_421,
                28_943_753_788_534_400_564_172_937,
                500_000_000_000_000_000,
                500_000_000_000_000_000,
                0
            )
        );
        _assertScenario(
            Scenario(30_000_000e18, 0, 111_111_111_111_111_111_111, 28_756_604_049_783_215_330_630_285, 1e18, 0, 0)
        );
    }

    function testNormalizedDomainDoesNotOverflowAtLargeSkew() external view {
        int256 qA = 30_000_000e18;
        int256 qB = 0;
        require(PRB.logPartitionWad(qA, qB) > 0, "PRB large-skew failure");
        require(SOLADY.logPartitionWad(qA, qB) > 0, "Solady large-skew failure");
    }

    function _assertScenario(Scenario memory scenario) private view {
        (int256 prbPriceA, int256 prbPriceB, int256 prbNeutral) = PRB.pricesWad(scenario.qAWad, scenario.qBWad);
        _assertLmsr(
            PRB.logPartitionWad(scenario.qAWad, scenario.qBWad),
            PRB.costWad(scenario.qAWad, scenario.qBWad),
            prbPriceA,
            prbPriceB,
            prbNeutral,
            scenario
        );

        (int256 soladyPriceA, int256 soladyPriceB, int256 soladyNeutral) =
            SOLADY.pricesWad(scenario.qAWad, scenario.qBWad);
        _assertLmsr(
            SOLADY.logPartitionWad(scenario.qAWad, scenario.qBWad),
            SOLADY.costWad(scenario.qAWad, scenario.qBWad),
            soladyPriceA,
            soladyPriceB,
            soladyNeutral,
            scenario
        );
    }

    function _assertLmsr(
        int256 actualLogZ,
        int256 actualCost,
        int256 actualPriceA,
        int256 actualPriceB,
        int256 actualNeutral,
        Scenario memory scenario
    ) private pure {
        _assertApprox(actualLogZ, scenario.expectedLogZ, LOG_PARTITION_TOLERANCE_WAD);
        _assertApprox(actualCost, scenario.expectedCost, COST_TOLERANCE_WAD);
        _assertApprox(actualPriceA, scenario.expectedPriceA, PRICE_TOLERANCE_WAD);
        _assertApprox(actualPriceB, scenario.expectedPriceB, PRICE_TOLERANCE_WAD);
        _assertApprox(actualNeutral, scenario.expectedNeutral, PRICE_TOLERANCE_WAD);
    }

    function _assertApprox(int256 actual, int256 expected, int256 tolerance) private pure {
        int256 difference = actual >= expected ? actual - expected : expected - actual;
        require(difference <= tolerance, "outside canonical tolerance");
    }
}
