// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketRegistry} from "../../src/interfaces/IMarketRegistry.sol";

contract MockMarketRegistry is IMarketRegistry {
    mapping(address market => bool registered) public isRegisteredMarket;

    function setRegistered(address market, bool registered) external {
        isRegisteredMarket[market] = registered;
    }
}
