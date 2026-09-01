// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Precomputed Market Version 1 Crown dominance boundaries.
/// @dev Thresholds are generated off-chain from b=270,000. Runtime Crown
///      transitions use only signed quantity differences and comparisons.
library XbidCrownMath {
    int256 internal constant CHALLENGE_OPEN_48_WEI = -21_611_531_071_854_834_972_420;
    int256 internal constant TAKEOVER_52_WEI = 21_611_531_071_854_834_972_421;
    int256 internal constant DEFENSE_55_WEI = 54_181_087_774_780_813_543_293;
    int256 internal constant RESET_STRICTLY_BELOW_45_WEI = -54_181_087_774_780_813_543_293;

    function challengerAtLeast48(uint256 challengerQuantityWei, uint256 crownQuantityWei) internal pure returns (bool) {
        return _difference(challengerQuantityWei, crownQuantityWei) >= CHALLENGE_OPEN_48_WEI;
    }

    function challengerAtLeast52(uint256 challengerQuantityWei, uint256 crownQuantityWei) internal pure returns (bool) {
        return _difference(challengerQuantityWei, crownQuantityWei) >= TAKEOVER_52_WEI;
    }

    function crownAtLeast55(uint256 crownQuantityWei, uint256 challengerQuantityWei) internal pure returns (bool) {
        return _difference(crownQuantityWei, challengerQuantityWei) >= DEFENSE_55_WEI;
    }

    function challengerStrictlyBelow45(uint256 challengerQuantityWei, uint256 crownQuantityWei)
        internal
        pure
        returns (bool)
    {
        return _difference(challengerQuantityWei, crownQuantityWei) <= RESET_STRICTLY_BELOW_45_WEI;
    }

    function _difference(uint256 leftQuantityWei, uint256 rightQuantityWei) private pure returns (int256) {
        // Market Version 1 caps each side at 30,000,000e18, well below int256.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(leftQuantityWei) - int256(rightQuantityWei);
    }
}
