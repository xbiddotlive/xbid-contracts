// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "solady/src/tokens/ERC20.sol";

contract MockSettlementToken is ERC20 {
    uint256 public transferFeeBps;
    address public transferCallbackTarget;
    bytes public transferCallbackData;

    function name() public pure override returns (string memory) {
        return "Mock USD Coin";
    }

    function symbol() public pure override returns (string memory) {
        return "mUSDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setTransferFeeBps(uint256 feeBps) external {
        require(feeBps <= 10_000, "fee too high");
        transferFeeBps = feeBps;
    }

    function setTransferCallback(address target, bytes calldata data) external {
        transferCallbackTarget = target;
        transferCallbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount * transferFeeBps / 10_000;
        super.transfer(to, amount);
        if (fee != 0) super._transfer(to, address(0xdead), fee);
        _runTransferCallback();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount * transferFeeBps / 10_000;
        super.transferFrom(from, to, amount);
        if (fee != 0) super._transfer(to, address(0xdead), fee);
        _runTransferCallback();
        return true;
    }

    function _runTransferCallback() private {
        address target = transferCallbackTarget;
        if (target == address(0)) return;
        (bool success, bytes memory data) = target.call(transferCallbackData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
    }
}
