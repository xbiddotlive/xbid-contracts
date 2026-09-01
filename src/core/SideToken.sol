// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";

/// @notice Transferable position token for one side of one XBID Contest.
/// @dev Deployed as an EIP-1167 clone. Only its permanently bound MarketVault
///      may mint, or burn tokens already held by that MarketVault.
contract SideToken is ERC20, Initializable {
    error Unauthorized();
    error ZeroAddress();
    error InvalidContestId();
    error InvalidSide(uint8 side);

    bytes32 public contestId;
    uint8 public side;
    address public marketVault;

    string private _tokenName;
    string private _tokenSymbol;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        bytes32 contestId_,
        uint8 side_,
        address marketVault_,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        if (contestId_ == bytes32(0)) revert InvalidContestId();
        if (side_ > 1) revert InvalidSide(side_);
        if (marketVault_ == address(0)) revert ZeroAddress();

        contestId = contestId_;
        side = side_;
        marketVault = marketVault_;
        _tokenName = name_;
        _tokenSymbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function mintTo(address account, uint256 amount) external {
        if (msg.sender != marketVault) revert Unauthorized();
        if (account == address(0)) revert ZeroAddress();
        _mint(account, amount);
    }

    function burnHeld(uint256 amount) external {
        if (msg.sender != marketVault) revert Unauthorized();
        _burn(msg.sender, amount);
    }

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}
