// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

/// @notice Fixed-parameter LMSR math for XBID Market Version 2.
/// @dev Quantities and outputs use signed/unsigned WAD (1e18). Settlement-token
///      rounding is implemented by XbidTradeMathV2 under the locked OPEN-011 rules.
library XbidLmsrMathV2 {
    error QuantityOutOfRange(uint256 qAWei, uint256 qBWei);
    error NegativeCost(int256 costWad);

    int256 internal constant B_WAD = 150_000e18;
    int256 internal constant LN_98_WAD = 4_584_967_478_670_571_920;
    // Solady evaluates logPartitionWad(0, 0) one WAD-wei below the rounded
    // decimal.js ln(100) reference. Using the implementation's own origin
    // keeps C(0,0) exactly zero and prevents tiny positive q from producing
    // an artificial negative cost.
    int256 internal constant INITIAL_LOG_PARTITION_WAD = 4_605_170_185_988_091_367;

    uint256 internal constant MAX_SIDE_QUANTITY_WAD = 30_000_000e18;

    function bWad() internal pure returns (int256) {
        return B_WAD;
    }

    function maximumSideQuantityWad() internal pure returns (uint256) {
        return MAX_SIDE_QUANTITY_WAD;
    }

    function logPartitionWad(uint256 qAWei, uint256 qBWei) internal pure returns (int256) {
        _validateQuantities(qAWei, qBWei);
        return _logPartitionWad(qAWei, qBWei);
    }

    function costWad(uint256 qAWei, uint256 qBWei) internal pure returns (uint256) {
        _validateQuantities(qAWei, qBWei);
        if (qAWei == 0 && qBWei == 0) return 0;

        int256 result = FixedPointMathLib.sMulWad(B_WAD, _logPartitionWad(qAWei, qBWei) - INITIAL_LOG_PARTITION_WAD);
        if (result < 0) revert NegativeCost(result);
        // Safe after the explicit non-negative check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(result);
    }

    function pricesWad(uint256 qAWei, uint256 qBWei)
        internal
        pure
        returns (uint256 priceA, uint256 priceB, uint256 neutral)
    {
        _validateQuantities(qAWei, qBWei);

        // Quantities were capped far below int256.max by _validateQuantities.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 x = FixedPointMathLib.sDivWad(int256(qAWei), B_WAD);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 y = FixedPointMathLib.sDivWad(int256(qBWei), B_WAD);
        int256 logZ = _logPartitionWad(qAWei, qBWei);

        // expWad returns a non-negative signed WAD value for these inputs.
        // forge-lint: disable-next-line(unsafe-typecast)
        priceA = uint256(FixedPointMathLib.expWad(x - logZ));
        // forge-lint: disable-next-line(unsafe-typecast)
        priceB = uint256(FixedPointMathLib.expWad(y - logZ));
        // forge-lint: disable-next-line(unsafe-typecast)
        neutral = uint256(FixedPointMathLib.expWad(LN_98_WAD - logZ));
    }

    function _logPartitionWad(uint256 qAWei, uint256 qBWei) private pure returns (int256) {
        // Private callers validate both quantities before reaching this point.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 x = FixedPointMathLib.sDivWad(int256(qAWei), B_WAD);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 y = FixedPointMathLib.sDivWad(int256(qBWei), B_WAD);
        int256 maximum = x > y ? x : y;
        if (LN_98_WAD > maximum) maximum = LN_98_WAD;

        // Every exp input is <= 0. Values below Solady's negative threshold
        // become zero only after their true value is below half a WAD-wei.
        int256 normalized = FixedPointMathLib.expWad(x - maximum) + FixedPointMathLib.expWad(y - maximum)
            + FixedPointMathLib.expWad(LN_98_WAD - maximum);

        return maximum + FixedPointMathLib.lnWad(normalized);
    }

    function _validateQuantities(uint256 qAWei, uint256 qBWei) private pure {
        if (qAWei > MAX_SIDE_QUANTITY_WAD || qBWei > MAX_SIDE_QUANTITY_WAD) {
            revert QuantityOutOfRange(qAWei, qBWei);
        }
    }
}
