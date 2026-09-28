// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {MarketVaultV2InvariantTest} from "./MarketVaultV2Invariant.t.sol";
import {MarketVaultV2} from "../../src/core/MarketVaultV2.sol";
import {MarketVaultV4} from "../../src/core/MarketVaultV4.sol";

/// @dev Same full-domain state machine, calling V4 through the unchanged V2 ABI.
contract MarketVaultV4InvariantTest is MarketVaultV2InvariantTest {
    function _implementation() internal override returns (MarketVaultV2) {
        return MarketVaultV2(address(new MarketVaultV4()));
    }

    function _marketVersion() internal pure override returns (uint32) {
        return 4;
    }
}
