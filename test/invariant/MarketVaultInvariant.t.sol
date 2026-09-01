// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InvariantTest} from "solady/test/utils/InvariantTest.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {MarketVault} from "../../src/core/MarketVault.sol";
import {SideToken} from "../../src/core/SideToken.sol";
import {XbidTradeMath} from "../../src/libraries/XbidTradeMath.sol";
import {MockFeeVault} from "../mocks/MockFeeVault.sol";
import {MockRiskController} from "../mocks/MockRiskController.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

contract MarketVaultHandler {
    MarketVault public immutable market;
    SideToken public immutable tokenA;
    SideToken public immutable tokenB;
    MockSettlementToken public immutable usdc;

    constructor(MarketVault market_, SideToken tokenA_, SideToken tokenB_, MockSettlementToken usdc_) {
        market = market_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        usdc = usdc_;
        usdc_.approve(address(market_), type(uint256).max);
        tokenA_.approve(address(market_), type(uint256).max);
        tokenB_.approve(address(market_), type(uint256).max);
    }

    function buyA(uint256 seed) external {
        _buy(MarketVault.Side.A, seed);
    }

    function buyB(uint256 seed) external {
        _buy(MarketVault.Side.B, seed);
    }

    function sellA(uint256 seed) external {
        _sell(MarketVault.Side.A, tokenA.balanceOf(address(this)), seed);
    }

    function sellB(uint256 seed) external {
        _sell(MarketVault.Side.B, tokenB.balanceOf(address(this)), seed);
    }

    function flipA(uint256 seed) external {
        _flip(MarketVault.Side.A, tokenA.balanceOf(address(this)), seed);
    }

    function flipB(uint256 seed) external {
        _flip(MarketVault.Side.B, tokenB.balanceOf(address(this)), seed);
    }

    function sellAllA() external {
        _sellAll(MarketVault.Side.A, tokenA.balanceOf(address(this)));
    }

    function sellAllB() external {
        _sellAll(MarketVault.Side.B, tokenB.balanceOf(address(this)));
    }

    function _buy(MarketVault.Side side, uint256 seed) private {
        uint256 availableUnits = usdc.balanceOf(address(this));
        if (availableUnits < 1_000_000) return;
        uint256 maximumGross = availableUnits < 100_000_000_000 ? availableUnits : 100_000_000_000;
        uint256 gross = 1_000_000 + seed % (maximumGross - 1_000_000 + 1);
        try market.buy(side, gross, 0, block.timestamp, address(0)) {} catch {}
    }

    function _sell(MarketVault.Side side, uint256 balance, uint256 seed) private {
        if (balance == 0) return;
        uint256 input = 1 + seed % balance;
        try market.sell(side, input, 0, block.timestamp) {} catch {}
    }

    function _flip(MarketVault.Side side, uint256 balance, uint256 seed) private {
        if (balance == 0) return;
        uint256 input = 1 + seed % balance;
        try market.flip(side, input, 0, block.timestamp) {} catch {}
    }

    function _sellAll(MarketVault.Side side, uint256 balance) private {
        if (balance == 0) return;
        try market.sellAll(side, balance, 0, block.timestamp) {} catch {}
    }
}

contract MarketVaultInvariantTest is InvariantTest {
    bytes32 private constant CONTEST_ID = keccak256("xbid-market-vault-invariant");
    uint256 private constant INITIAL_USDC_UNITS = 1_000_000_000_000_000;

    MarketVault private market;
    SideToken private tokenA;
    SideToken private tokenB;
    MockSettlementToken private usdc;
    MockFeeVault private feeVault;
    MarketVaultHandler private handler;

    function setUp() public {
        MarketVault marketImplementation = new MarketVault();
        SideToken tokenImplementation = new SideToken();
        usdc = new MockSettlementToken();
        MockRiskController riskController = new MockRiskController();
        feeVault = new MockFeeVault();

        market = MarketVault(LibClone.clone(address(marketImplementation)));
        tokenA = SideToken(LibClone.clone(address(tokenImplementation)));
        tokenB = SideToken(LibClone.clone(address(tokenImplementation)));
        tokenA.initialize(CONTEST_ID, 0, address(market), "XBID A", "XA");
        tokenB.initialize(CONTEST_ID, 1, address(market), "XBID B", "XB");
        market.initialize(
            CONTEST_ID,
            1,
            address(this),
            address(usdc),
            address(tokenA),
            address(tokenB),
            address(riskController),
            address(feeVault)
        );

        handler = new MarketVaultHandler(market, tokenA, tokenB, usdc);
        usdc.mint(address(handler), INITIAL_USDC_UNITS);
        _addTargetContract(address(handler));
    }

    function invariantReserveCoversCurveCostAndActualBalance() external view {
        require(market.reserveUnits() >= market.requiredReserveUnits(), "reserve below curve cost");
        require(usdc.balanceOf(address(market)) >= market.reserveUnits(), "actual balance below reserve");
    }

    function invariantQuantitiesEqualTokenSupplies() external view {
        require(tokenA.totalSupply() == market.qAWei(), "A supply mismatch");
        require(tokenB.totalSupply() == market.qBWei(), "B supply mismatch");
        require(tokenA.balanceOf(address(market)) == 0, "A stranded in vault");
        require(tokenB.balanceOf(address(market)) == 0, "B stranded in vault");
    }

    function invariantSettlementIsConservedAndFeesAreFullyCredited() external view {
        uint256 accountedUnits =
            usdc.balanceOf(address(handler)) + usdc.balanceOf(address(market)) + usdc.balanceOf(address(feeVault));
        require(accountedUnits == INITIAL_USDC_UNITS, "settlement not conserved");
        require(usdc.balanceOf(address(feeVault)) == feeVault.totalCredited(), "fee credit mismatch");
    }

    function invariantPreviewStateRemainsSolvent() external view {
        XbidTradeMath.validateReserve(market.qAWei(), market.qBWei(), market.reserveUnits());
    }
}
