// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IRiskController} from "../../src/interfaces/IRiskController.sol";

contract MockRiskController is IRiskController {
    mapping(address market => RiskMode mode) public modeOf;

    function globalMode() external pure returns (RiskMode) {
        return RiskMode.Normal;
    }

    function marketMode(address market) external view returns (RiskMode) {
        return modeOf[market];
    }

    function setMode(address market, RiskMode mode) external {
        modeOf[market] = mode;
    }

    function effectiveMode(address market) external view returns (RiskMode) {
        return modeOf[market];
    }
}
