// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract MockMarketRegistry {
    mapping(address market => bool registered) public isRegisteredMarket;

    function setRegistered(address market, bool registered) external {
        isRegisteredMarket[market] = registered;
    }
}
