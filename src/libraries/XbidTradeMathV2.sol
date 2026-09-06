// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {XbidLmsrMathV2} from "./XbidLmsrMathV2.sol";

/// @notice Integer settlement and reserve accounting for XBID Market Version 2.
/// @dev Settlement amounts use 6-decimal base units; Side quantities use WAD.
///      Fees are excluded from Curve Reserve and transferred to FeeVault.
library XbidTradeMathV2 {
    error InsufficientReserve(uint256 actualUnits, uint256 requiredUnits);
    error BuyGrossBelowMinimum(uint256 grossInputUnits);
    error SellGrossBelowMinimum(uint256 grossOutputUnits);
    error FlipGrossBelowMinimum(uint256 grossOutputUnits);
    error InvalidTokenInput(uint256 tokenInputWei, uint256 availableQuantityWei);
    error ZeroTokenOutput();
    error ZeroNetOutput();
    error CurveInputExceedsCapacity(uint256 curveInputWad, uint256 maximumWad);
    error BuySolutionExceedsBudget(uint256 costAfterWad, uint256 targetCostWad);

    int256 internal constant WAD_SIGNED = 1e18;
    int256 internal constant LN_98_WAD = 4_584_967_478_670_571_920;
    uint256 internal constant SETTLEMENT_TO_WAD = 1e12;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant TRADING_FEE_BPS = 100;
    uint256 internal constant MINIMUM_BUY_GROSS_UNITS = 1_000_000;
    uint256 internal constant MINIMUM_SELL_GROSS_UNITS = 1_000_000;
    uint256 internal constant MINIMUM_FLIP_GROSS_UNITS = 50_000_000;

    struct BuyResult {
        uint256 feeUnits;
        uint256 curveInputUnits;
        uint256 tokenOutputWei;
        uint256 qAAfterWei;
        uint256 qBAfterWei;
        uint256 reserveAfterUnits;
    }

    struct SellResult {
        uint256 grossOutputUnits;
        uint256 feeUnits;
        uint256 netOutputUnits;
        uint256 qAAfterWei;
        uint256 qBAfterWei;
        uint256 reserveAfterUnits;
    }

    struct FlipResult {
        uint256 sourceGrossOutputUnits;
        uint256 feeUnits;
        uint256 destinationCurveInputUnits;
        uint256 destinationTokenOutputWei;
        uint256 qAAfterWei;
        uint256 qBAfterWei;
        uint256 reserveAfterUnits;
    }

    function requiredReserveUnits(uint256 qAWei, uint256 qBWei) internal pure returns (uint256) {
        return FixedPointMathLib.divUp(XbidLmsrMathV2.costWad(qAWei, qBWei), SETTLEMENT_TO_WAD);
    }

    function validateReserve(uint256 qAWei, uint256 qBWei, uint256 reserveUnits) internal pure {
        uint256 requiredUnits = requiredReserveUnits(qAWei, qBWei);
        if (reserveUnits < requiredUnits) revert InsufficientReserve(reserveUnits, requiredUnits);
    }

    function tradingFeeUnits(uint256 grossUnits) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(grossUnits, TRADING_FEE_BPS, BPS_DENOMINATOR);
    }

    function quoteBuy(uint256 qAWei, uint256 qBWei, uint256 reserveUnits, bool sideA, uint256 grossInputUnits)
        internal
        pure
        returns (BuyResult memory result)
    {
        validateReserve(qAWei, qBWei, reserveUnits);
        if (grossInputUnits < MINIMUM_BUY_GROSS_UNITS) revert BuyGrossBelowMinimum(grossInputUnits);

        result.feeUnits = tradingFeeUnits(grossInputUnits);
        result.curveInputUnits = grossInputUnits - result.feeUnits;

        uint256 currentQuantityWei = sideA ? qAWei : qBWei;
        uint256 otherQuantityWei = sideA ? qBWei : qAWei;
        uint256 nextQuantityWei = _solveBuyQuantity(currentQuantityWei, otherQuantityWei, result.curveInputUnits);
        result.tokenOutputWei = nextQuantityWei - currentQuantityWei;
        if (result.tokenOutputWei == 0) revert ZeroTokenOutput();

        result.qAAfterWei = sideA ? nextQuantityWei : qAWei;
        result.qBAfterWei = sideA ? qBWei : nextQuantityWei;
        result.reserveAfterUnits = reserveUnits + result.curveInputUnits;
        validateReserve(result.qAAfterWei, result.qBAfterWei, result.reserveAfterUnits);
    }

    function quoteSell(
        uint256 qAWei,
        uint256 qBWei,
        uint256 reserveUnits,
        bool sideA,
        uint256 tokenInputWei,
        bool sellAll
    ) internal pure returns (SellResult memory result) {
        validateReserve(qAWei, qBWei, reserveUnits);

        uint256 currentQuantityWei = sideA ? qAWei : qBWei;
        if (tokenInputWei == 0 || tokenInputWei > currentQuantityWei) {
            revert InvalidTokenInput(tokenInputWei, currentQuantityWei);
        }

        result.qAAfterWei = sideA ? currentQuantityWei - tokenInputWei : qAWei;
        result.qBAfterWei = sideA ? qBWei : currentQuantityWei - tokenInputWei;
        uint256 releasedCostWad =
            XbidLmsrMathV2.costWad(qAWei, qBWei) - XbidLmsrMathV2.costWad(result.qAAfterWei, result.qBAfterWei);
        result.grossOutputUnits = releasedCostWad / SETTLEMENT_TO_WAD;

        if (!sellAll && result.grossOutputUnits < MINIMUM_SELL_GROSS_UNITS) {
            revert SellGrossBelowMinimum(result.grossOutputUnits);
        }
        result.feeUnits = tradingFeeUnits(result.grossOutputUnits);
        result.netOutputUnits = result.grossOutputUnits - result.feeUnits;
        if (result.netOutputUnits == 0) revert ZeroNetOutput();

        result.reserveAfterUnits = reserveUnits - result.grossOutputUnits;
        validateReserve(result.qAAfterWei, result.qBAfterWei, result.reserveAfterUnits);
    }

    function quoteFlip(
        uint256 qAWei,
        uint256 qBWei,
        uint256 reserveUnits,
        bool sourceSideA,
        uint256 sourceTokenInputWei
    ) internal pure returns (FlipResult memory result) {
        validateReserve(qAWei, qBWei, reserveUnits);

        uint256 sourceQuantityWei = sourceSideA ? qAWei : qBWei;
        if (sourceTokenInputWei == 0 || sourceTokenInputWei > sourceQuantityWei) {
            revert InvalidTokenInput(sourceTokenInputWei, sourceQuantityWei);
        }

        uint256 qAAfterBurnWei = sourceSideA ? sourceQuantityWei - sourceTokenInputWei : qAWei;
        uint256 qBAfterBurnWei = sourceSideA ? qBWei : sourceQuantityWei - sourceTokenInputWei;
        uint256 releasedCostWad =
            XbidLmsrMathV2.costWad(qAWei, qBWei) - XbidLmsrMathV2.costWad(qAAfterBurnWei, qBAfterBurnWei);
        result.sourceGrossOutputUnits = releasedCostWad / SETTLEMENT_TO_WAD;
        if (result.sourceGrossOutputUnits < MINIMUM_FLIP_GROSS_UNITS) {
            revert FlipGrossBelowMinimum(result.sourceGrossOutputUnits);
        }

        result.feeUnits = tradingFeeUnits(result.sourceGrossOutputUnits);
        result.destinationCurveInputUnits = result.sourceGrossOutputUnits - result.feeUnits;

        uint256 destinationQuantityWei = sourceSideA ? qBAfterBurnWei : qAAfterBurnWei;
        uint256 remainingSourceQuantityWei = sourceSideA ? qAAfterBurnWei : qBAfterBurnWei;
        uint256 nextDestinationQuantityWei =
            _solveBuyQuantity(destinationQuantityWei, remainingSourceQuantityWei, result.destinationCurveInputUnits);
        result.destinationTokenOutputWei = nextDestinationQuantityWei - destinationQuantityWei;
        if (result.destinationTokenOutputWei == 0) revert ZeroTokenOutput();

        result.qAAfterWei = sourceSideA ? qAAfterBurnWei : nextDestinationQuantityWei;
        result.qBAfterWei = sourceSideA ? nextDestinationQuantityWei : qBAfterBurnWei;
        result.reserveAfterUnits = reserveUnits - result.feeUnits;
        validateReserve(result.qAAfterWei, result.qBAfterWei, result.reserveAfterUnits);
    }

    function _solveBuyQuantity(uint256 currentQuantityWei, uint256 otherQuantityWei, uint256 curveInputUnits)
        private
        pure
        returns (uint256 nextQuantityWei)
    {
        uint256 currentCostWad = XbidLmsrMathV2.costWad(currentQuantityWei, otherQuantityWei);
        uint256 maximumCostWad = XbidLmsrMathV2.costWad(XbidLmsrMathV2.maximumSideQuantityWad(), otherQuantityWei);
        uint256 curveInputWad = curveInputUnits * SETTLEMENT_TO_WAD;
        uint256 maximumCurveInputWad = maximumCostWad - currentCostWad;
        if (curveInputWad > maximumCurveInputWad) {
            revert CurveInputExceedsCapacity(curveInputWad, maximumCurveInputWad);
        }

        nextQuantityWei = _nextQuantityFromInput(currentQuantityWei, otherQuantityWei, curveInputWad);
        uint256 costAfterWad = XbidLmsrMathV2.costWad(nextQuantityWei, otherQuantityWei);
        uint256 targetCostWad = currentCostWad + curveInputWad;
        if (costAfterWad > targetCostWad) {
            // Retry one Settlement base unit below the paid Curve Input. This
            // absorbs fixed-point inverse error as positive Reserve buffer.
            nextQuantityWei =
                _nextQuantityFromInput(currentQuantityWei, otherQuantityWei, curveInputWad - SETTLEMENT_TO_WAD);
            costAfterWad = XbidLmsrMathV2.costWad(nextQuantityWei, otherQuantityWei);
        }
        if (costAfterWad > targetCostWad) revert BuySolutionExceedsBudget(costAfterWad, targetCostWad);
    }

    function _nextQuantityFromInput(uint256 currentQuantityWei, uint256 otherQuantityWei, uint256 curveInputWad)
        private
        pure
        returns (uint256 nextQuantityWei)
    {
        int256 bWadSigned = XbidLmsrMathV2.bWad();
        int256 currentLogPartitionWad = XbidLmsrMathV2.logPartitionWad(currentQuantityWei, otherQuantityWei);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 inputRatioWad = FixedPointMathLib.sDivWad(int256(curveInputWad), bWadSigned);
        int256 targetLogPartitionWad = currentLogPartitionWad + inputRatioWad;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 otherRatioWad = FixedPointMathLib.sDivWad(int256(otherQuantityWei), bWadSigned);

        // Solve entirely in a log-partition-relative domain:
        //   exp(nextQ / b - targetLogZ)
        //     = 1 - exp(otherQ / b - targetLogZ) - exp(ln(98) - targetLogZ)
        // Every exp input is non-positive, so this remains valid across the
        // full V2 quantity domain (q / b <= 200) without constructing an
        // overflowing absolute partition or weight.
        int256 normalizedCurrentWeightWad = WAD_SIGNED - FixedPointMathLib.expWad(otherRatioWad - targetLogPartitionWad)
            - FixedPointMathLib.expWad(LN_98_WAD - targetLogPartitionWad);
        int256 nextRatioWad = targetLogPartitionWad + FixedPointMathLib.lnWad(normalizedCurrentWeightWad);
        int256 nextQuantitySigned = FixedPointMathLib.sMulWad(bWadSigned, nextRatioWad);

        // Capacity validation bounds the result to [currentQuantity, MAX_Q].
        // forge-lint: disable-next-line(unsafe-typecast)
        nextQuantityWei = uint256(nextQuantitySigned);
    }
}
