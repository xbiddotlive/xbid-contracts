// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IRiskController {
    enum RiskMode {
        Normal,
        RiskOff,
        FullPause
    }

    function effectiveMode(address market) external view returns (RiskMode);
}
