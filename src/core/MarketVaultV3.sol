// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarketVaultV2} from "./MarketVaultV2.sol";

/// @notice Immutable replacement for Market Version 2 using the numerically
///         stable b=150,000 buy inverse across the complete quantity domain.
/// @dev Existing V2 clones remain unchanged. Register this implementation as
///      a new append-only Market Version before making it the Factory default.
contract MarketVaultV3 is MarketVaultV2 {
    function _expectedMarketVersion() internal pure override returns (uint32) {
        return 3;
    }
}
