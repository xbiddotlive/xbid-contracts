// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IProbeUsdc {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract ArcUsdcProbeSpender {
    function roundTrip(IProbeUsdc usdc, uint256 amount) external {
        uint256 beforeBalance = usdc.balanceOf(address(this));
        require(usdc.transferFrom(msg.sender, address(this), amount), "pull failed");
        require(usdc.balanceOf(address(this)) == beforeBalance + amount, "pull delta");
        require(usdc.transfer(msg.sender, amount), "push failed");
        require(usdc.balanceOf(address(this)) == beforeBalance, "push delta");
    }
}

/// @notice Runtime injected ONLY through eth_call state overrides; not a deployment script.
/// @dev Calls the actual Arc node's native USDC implementation, not a mocked local precompile.
contract ArcUsdcCompatibilityProbe {
    function probe() external returns (uint256 balanceBefore, uint256 balanceAfter) {
        require(block.chainid == 5042, "wrong chain");
        IProbeUsdc usdc = IProbeUsdc(0x3600000000000000000000000000000000000000);
        balanceBefore = usdc.balanceOf(address(this));
        require(balanceBefore >= 10e6, "state override funding missing");
        require(balanceBefore == address(this).balance / 1e12, "native parity");
        ArcUsdcProbeSpender spender = new ArcUsdcProbeSpender();
        require(usdc.approve(address(spender), 10e6), "approve failed");
        spender.roundTrip(usdc, 10e6);
        balanceAfter = usdc.balanceOf(address(this));
        require(balanceAfter == balanceBefore, "round trip delta");
        require(balanceAfter == address(this).balance / 1e12, "native parity after");
    }
}
