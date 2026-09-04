// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Precomputed Market Version 2 Crown dominance boundaries.
/// @dev Thresholds are generated off-chain from b=150,000. Runtime Crown
///      transitions use only signed quantity differences and comparisons.
library XbidCrownMathV2 {
    int256 internal constant CHALLENGE_OPEN_48_WEI = -12_006_406_151_030_463_873_566;
    int256 internal constant TAKEOVER_52_WEI = 12_006_406_151_030_463_873_567;
    int256 internal constant DEFENSE_55_WEI = 30_100_604_319_322_674_190_718;
    int256 internal constant RESET_STRICTLY_BELOW_45_WEI = -30_100_604_319_322_674_190_718;

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
        // Market Version 2 caps each side at 30,000,000e18, well below int256.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(leftQuantityWei) - int256(rightQuantityWei);
    }
}
