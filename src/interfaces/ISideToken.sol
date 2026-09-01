// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ISideToken {
    function contestId() external view returns (bytes32);
    function side() external view returns (uint8);
    function marketVault() external view returns (address);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function mintTo(address account, uint256 amount) external;
    function burnHeld(uint256 amount) external;
}
