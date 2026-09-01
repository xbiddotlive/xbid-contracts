// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

/// @notice OPEN-002 benchmark adapter. It is not the production LMSR implementation.
library SoladyMathCandidate {
    int256 internal constant B_WAD = 270_000e18;
    int256 internal constant LN_98_WAD = 4_584_967_478_670_571_920;
    int256 internal constant LN_100_WAD = 4_605_170_185_988_091_368;

    function expWad(int256 x) internal pure returns (int256) {
        return FixedPointMathLib.expWad(x);
    }

    function lnWad(int256 x) internal pure returns (int256) {
        return FixedPointMathLib.lnWad(x);
    }

    function logPartitionWad(int256 qAWad, int256 qBWad) internal pure returns (int256) {
        int256 x = FixedPointMathLib.sDivWad(qAWad, B_WAD);
        int256 y = FixedPointMathLib.sDivWad(qBWad, B_WAD);
        int256 maximum = x > y ? x : y;
        if (LN_98_WAD > maximum) maximum = LN_98_WAD;

        int256 normalized = expWad(x - maximum) + expWad(y - maximum) + expWad(LN_98_WAD - maximum);
        return maximum + lnWad(normalized);
    }

    function costWad(int256 qAWad, int256 qBWad) internal pure returns (int256) {
        if (qAWad == 0 && qBWad == 0) return 0;
        return FixedPointMathLib.sMulWad(B_WAD, logPartitionWad(qAWad, qBWad) - LN_100_WAD);
    }

    function pricesWad(int256 qAWad, int256 qBWad)
        internal
        pure
        returns (int256 priceA, int256 priceB, int256 neutral)
    {
        int256 x = FixedPointMathLib.sDivWad(qAWad, B_WAD);
        int256 y = FixedPointMathLib.sDivWad(qBWad, B_WAD);
        int256 logZ = logPartitionWad(qAWad, qBWad);
        priceA = expWad(x - logZ);
        priceB = expWad(y - logZ);
        neutral = expWad(LN_98_WAD - logZ);
    }
}
