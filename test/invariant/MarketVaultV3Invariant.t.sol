// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarketVaultV2InvariantTest} from "./MarketVaultV2Invariant.t.sol";
import {MarketVaultV2} from "../../src/core/MarketVaultV2.sol";
import {MarketVaultV3} from "../../src/core/MarketVaultV3.sol";

/// @dev Execute the same full-domain state machine against the actual V3 clone.
contract MarketVaultV3InvariantTest is MarketVaultV2InvariantTest {
    function _implementation() internal override returns (MarketVaultV2) {
        return new MarketVaultV3();
    }

    function _marketVersion() internal pure override returns (uint32) {
        return 3;
    }
}
