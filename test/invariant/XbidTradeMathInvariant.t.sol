// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InvariantTest} from "solady/test/utils/InvariantTest.sol";
import {XbidLmsrMath} from "../../src/libraries/XbidLmsrMath.sol";
import {XbidTradeMath} from "../../src/libraries/XbidTradeMath.sol";

contract XbidTradeInvariantQuoteHarness {
    function buy(uint256 qAWei, uint256 qBWei, uint256 reserveUnits, bool sideA, uint256 grossInputUnits)
        external
        pure
        returns (XbidTradeMath.BuyResult memory)
    {
        return XbidTradeMath.quoteBuy(qAWei, qBWei, reserveUnits, sideA, grossInputUnits);
    }

    function sell(uint256 qAWei, uint256 qBWei, uint256 reserveUnits, bool sideA, uint256 tokenInputWei)
        external
        pure
        returns (XbidTradeMath.SellResult memory)
    {
        return XbidTradeMath.quoteSell(qAWei, qBWei, reserveUnits, sideA, tokenInputWei, true);
    }

    function flip(uint256 qAWei, uint256 qBWei, uint256 reserveUnits, bool sourceSideA, uint256 tokenInputWei)
        external
        pure
        returns (XbidTradeMath.FlipResult memory)
    {
        return XbidTradeMath.quoteFlip(qAWei, qBWei, reserveUnits, sourceSideA, tokenInputWei);
    }
}

contract XbidTradeMathHandler {
    uint256 public qAWei;
    uint256 public qBWei;
    uint256 public reserveUnits;
    uint256 public accruedFeeUnits;

    XbidTradeInvariantQuoteHarness private immutable MATH = new XbidTradeInvariantQuoteHarness();

    function buyA(uint256 seed) external {
        _buy(true, seed);
    }

    function buyB(uint256 seed) external {
        _buy(false, seed);
    }

    function sellA(uint256 seed) external {
        _sell(true, seed);
    }

    function sellB(uint256 seed) external {
        _sell(false, seed);
    }

    function flipA(uint256 seed) external {
        _flip(true, seed);
    }

    function flipB(uint256 seed) external {
        _flip(false, seed);
    }

    function _buy(bool sideA, uint256 seed) private {
        uint256 grossInputUnits = 1_000_000 + (seed % 100_000_000_000);
        try MATH.buy(qAWei, qBWei, reserveUnits, sideA, grossInputUnits) returns (
            XbidTradeMath.BuyResult memory result
        ) {
            qAWei = result.qAAfterWei;
            qBWei = result.qBAfterWei;
            reserveUnits = result.reserveAfterUnits;
            accruedFeeUnits += result.feeUnits;
        } catch {}
    }

    function _sell(bool sideA, uint256 seed) private {
        uint256 availableQuantityWei = sideA ? qAWei : qBWei;
        if (availableQuantityWei == 0) return;
        uint256 tokenInputWei = 1 + (seed % availableQuantityWei);
        try MATH.sell(qAWei, qBWei, reserveUnits, sideA, tokenInputWei) returns (
            XbidTradeMath.SellResult memory result
        ) {
            qAWei = result.qAAfterWei;
            qBWei = result.qBAfterWei;
            reserveUnits = result.reserveAfterUnits;
            accruedFeeUnits += result.feeUnits;
        } catch {}
    }

    function _flip(bool sourceSideA, uint256 seed) private {
        uint256 availableQuantityWei = sourceSideA ? qAWei : qBWei;
        if (availableQuantityWei == 0) return;
        uint256 tokenInputWei = 1 + (seed % availableQuantityWei);
        try MATH.flip(qAWei, qBWei, reserveUnits, sourceSideA, tokenInputWei) returns (
            XbidTradeMath.FlipResult memory result
        ) {
            qAWei = result.qAAfterWei;
            qBWei = result.qBAfterWei;
            reserveUnits = result.reserveAfterUnits;
            accruedFeeUnits += result.feeUnits;
        } catch {}
    }
}

contract XbidTradeMathInvariantTest is InvariantTest {
    XbidTradeMathHandler private handler;

    function setUp() public {
        handler = new XbidTradeMathHandler();
        _addTargetContract(address(handler));
    }

    function invariantReserveCoversCeilCost() external view {
        uint256 requiredUnits = XbidTradeMath.requiredReserveUnits(handler.qAWei(), handler.qBWei());
        require(handler.reserveUnits() >= requiredUnits, "reserve below ceil cost");
    }

    function invariantQuantitiesRemainInsideVersionBoundary() external view {
        uint256 maximumQuantityWei = XbidLmsrMath.maximumSideQuantityWad();
        require(handler.qAWei() <= maximumQuantityWei, "qA above version maximum");
        require(handler.qBWei() <= maximumQuantityWei, "qB above version maximum");
    }
}
