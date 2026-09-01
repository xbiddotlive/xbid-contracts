// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IRiskController {
    enum RiskMode {
        Normal,
        RiskOff,
        FullPause
    }

    function globalMode() external view returns (RiskMode);

    function marketMode(address market) external view returns (RiskMode);

    function effectiveMode(address market) external view returns (RiskMode);
}
