// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeeVault} from "../../src/core/FeeVault.sol";

contract MockFeeSplitBatcher {
    function setTwo(FeeVault first, FeeVault second, uint16 protocolBps, uint16 creatorBps, uint16 referrerBps)
        external
    {
        first.setFeeSplit(protocolBps, creatorBps, referrerBps);
        second.setFeeSplit(protocolBps, creatorBps, referrerBps);
    }
}
