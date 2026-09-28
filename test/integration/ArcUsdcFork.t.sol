// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";

interface IArcUsdcProbe {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Opt-in compatibility probe. Fork calls never broadcast live transactions.
/// @dev Failure means the local EVM cannot stand in for Arc until diagnosed; mocks are not a substitute.
contract ArcUsdcForkTest is Test {
    IArcUsdcProbe constant USDC = IArcUsdcProbe(0x3600000000000000000000000000000000000000);
    address constant HOLDER = 0xA0b8f23f879457872109B5B20C9545B5281b28F6;

    function testForkNativeAndErc20BalanceAndTransfers() public {
        string memory rpc = vm.envOr("ARC_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 5042);
        assertEq(USDC.decimals(), 6);
        assertEq(USDC.balanceOf(HOLDER), HOLDER.balance / 1e12);
        vm.deal(HOLDER, 100e18);
        assertEq(USDC.balanceOf(HOLDER), 100e6, "fork must emulate native/ERC20 parity");
        vm.prank(HOLDER);
        assertTrue(USDC.approve(address(this), 10e6));
        assertTrue(USDC.transferFrom(HOLDER, address(this), 10e6));
        assertEq(USDC.balanceOf(address(this)), address(this).balance / 1e12);
        assertEq(USDC.balanceOf(HOLDER), 90e6);
        assertTrue(USDC.transfer(HOLDER, 10e6));
        assertEq(USDC.balanceOf(HOLDER), 100e6);
    }
}
