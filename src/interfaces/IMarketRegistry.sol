// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IMarketRegistry {
    function isRegisteredMarket(address market) external view returns (bool);
}
