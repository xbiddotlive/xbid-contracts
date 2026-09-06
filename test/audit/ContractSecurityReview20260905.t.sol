// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {MarketVaultV2} from "../../src/core/MarketVaultV2.sol";
import {MarketVaultV3} from "../../src/core/MarketVaultV3.sol";
import {SideToken} from "../../src/core/SideToken.sol";
import {XbidTradeMath} from "../../src/libraries/XbidTradeMath.sol";
import {XbidTradeMathV2} from "../../src/libraries/XbidTradeMathV2.sol";
import {XbidLmsrMathV2} from "../../src/libraries/XbidLmsrMathV2.sol";
import {MockFeeVault} from "../mocks/MockFeeVault.sol";
import {MockRiskController} from "../mocks/MockRiskController.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";
import {XBIDFactory} from "../../src/core/XBIDFactory.sol";
import {MarketRegistry} from "../../src/core/MarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Deliberately hostile LOCAL fixture demonstrating the existing governance trust boundary.
contract AuditOnlyHostileFactory is XBIDFactory {
    function pullHistoricalApproval(MockSettlementToken token, address owner, address recipient, uint256 amount)
        external
    {
        token.transferFrom(owner, recipient, amount);
    }
}

/// @notice Local-only audit evidence. KnownIssue tests reproduce defects rather than fix them.
contract ContractSecurityReview20260905Test is Test {
    MarketVaultV2 private market;
    SideToken private tokenA;
    SideToken private tokenB;
    MockSettlementToken private usdc;
    MockFeeVault private fees;
    address private constant VICTIM = address(0xa11ce);
    address private constant ATTACKER = address(0xbad);

    function setUp() public {
        market = MarketVaultV2(LibClone.clone(address(new MarketVaultV2())));
        SideToken implementation = new SideToken();
        tokenA = SideToken(LibClone.clone(address(implementation)));
        tokenB = SideToken(LibClone.clone(address(implementation)));
        usdc = new MockSettlementToken();
        fees = new MockFeeVault();
        bytes32 id = keccak256("local-security-review-20260905");
        tokenA.initialize(id, 0, address(market), "Review A", "RA");
        tokenB.initialize(id, 1, address(market), "Review B", "RB");
        market.initialize(
            id,
            2,
            address(this),
            address(usdc),
            address(tokenA),
            address(tokenB),
            address(new MockRiskController()),
            address(fees)
        );
        usdc.mint(address(this), 100_000_000e6);
        usdc.approve(address(market), type(uint256).max);
        tokenA.approve(address(market), type(uint256).max);
        tokenB.approve(address(market), type(uint256).max);
    }

    function testFixedV2LargeBuyInsideDeclaredCapacitySucceeds() external {
        uint256 gross = 21_000_000e6;
        uint256 paidCurveWad = (gross - XbidTradeMathV2.tradingFeeUnits(gross)) * 1e12;
        assertLt(paidCurveWad, XbidLmsrMathV2.costWad(30_000_000e18, 0));
        XbidTradeMath.BuyResult memory v1 = XbidTradeMath.quoteBuy(0, 0, 0, true, gross);
        assertLt(v1.qAAfterWei, 30_000_000e18);
        assertGt(v1.tokenOutputWei, 0);
        XbidTradeMathV2.BuyResult memory quote = market.previewBuy(MarketVaultV2.Side.A, gross);
        assertLt(quote.qAAfterWei, 30_000_000e18);
        assertGt(quote.tokenOutputWei, 0);
        uint256 beforeBalance = usdc.balanceOf(address(this));
        uint256 output = market.buy(MarketVaultV2.Side.A, gross, quote.tokenOutputWei, block.timestamp, address(0));
        assertEq(output, quote.tokenOutputWei);
        assertEq(usdc.balanceOf(address(this)), beforeBalance - gross);
        assertEq(market.reserveUnits(), quote.reserveAfterUnits);
        assertEq(tokenA.totalSupply(), quote.qAAfterWei);
        assertGe(market.reserveUnits(), market.requiredReserveUnits());
    }

    function testFixedV2LargeBuyDoesNotCastNextWeightToNegativeInt() external {
        uint256 gross = 19_850_000e6;
        uint256 paidCurveWad = (gross - XbidTradeMathV2.tradingFeeUnits(gross)) * 1e12;
        assertLt(paidCurveWad, XbidLmsrMathV2.costWad(30_000_000e18, 0));
        assertLt(paidCurveWad / 150_000, 135305999368893231589);
        XbidTradeMathV2.BuyResult memory quote = market.previewBuy(MarketVaultV2.Side.A, gross);
        assertGt(quote.tokenOutputWei, 0);
        assertLt(quote.qAAfterWei, 30_000_000e18);
        assertLe(XbidLmsrMathV2.costWad(quote.qAAfterWei, quote.qBAfterWei), paidCurveWad);
    }

    function testFixedV2LargeReachableMarketAcceptsAdditionAndOwnerCanExit() external {
        uint256 initialBalance = usdc.balanceOf(address(this));
        market.buy(MarketVaultV2.Side.A, 19_000_000e6, 0, block.timestamp, address(0));
        uint256 reserveBefore = market.reserveUnits();
        uint256 nextCurveWad = 990_000e6 * 1e12;
        assertLt(XbidLmsrMathV2.costWad(market.qAWei(), 0) + nextCurveWad, XbidLmsrMathV2.costWad(30_000_000e18, 0));
        uint256 added = market.buy(MarketVaultV2.Side.A, 1_000_000e6, 0, block.timestamp, address(0));
        assertGt(added, 0);
        assertEq(market.reserveUnits(), reserveBefore + 990_000e6);
        uint256 supply = tokenA.balanceOf(address(this));
        market.sellAll(MarketVaultV2.Side.A, supply, 0, block.timestamp);
        assertEq(tokenA.totalSupply(), 0);
        assertLe(market.reserveUnits(), 2);
        assertLt(usdc.balanceOf(address(this)), initialBalance);
    }

    function testVictimAllowanceCannotBeUsedByAnotherTrader() external {
        usdc.mint(VICTIM, 10_000e6);
        vm.startPrank(VICTIM);
        usdc.approve(address(market), type(uint256).max);
        uint256 owned = market.buy(MarketVaultV2.Side.A, 10_000e6, 0, block.timestamp, address(0));
        tokenA.approve(address(market), type(uint256).max);
        vm.stopPrank();
        vm.expectRevert();
        vm.prank(ATTACKER);
        market.sell(MarketVaultV2.Side.A, owned, 0, block.timestamp);
        assertEq(tokenA.balanceOf(VICTIM), owned);
        assertEq(usdc.balanceOf(ATTACKER), 0);
    }

    function testDonationDoesNotIncreaseTraderRedemption() external {
        uint256 bought = market.buy(MarketVaultV2.Side.A, 10_000e6, 0, block.timestamp, address(0));
        uint256 quoteBefore = market.previewSell(MarketVaultV2.Side.A, bought).netOutputUnits;
        usdc.transfer(address(market), 1_000_000e6);
        assertEq(market.previewSell(MarketVaultV2.Side.A, bought).netOutputUnits, quoteBefore);
        market.sellAll(MarketVaultV2.Side.A, bought, quoteBefore, block.timestamp);
        assertGe(usdc.balanceOf(address(market)), 1_000_000e6);
    }

    function testPermitCannotReplayOrCrossClone() external {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 permitTypeHash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(permitTypeHash, owner, address(market), 100e18, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tokenA.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        tokenA.permit(owner, address(market), 100e18, deadline, v, r, s);
        vm.expectRevert();
        tokenA.permit(owner, address(market), 100e18, deadline, v, r, s);
        vm.expectRevert();
        tokenB.permit(owner, address(market), 100e18, deadline, v, r, s);
        assertEq(tokenA.nonces(owner), 1);
        assertEq(tokenB.allowance(owner, address(market)), 0);
    }

    function testFixedImplementationUsesNewAppendOnlyMarketVersion() external {
        MarketVaultV3 v3 = MarketVaultV3(LibClone.clone(address(new MarketVaultV3())));
        SideToken implementation = new SideToken();
        SideToken v3TokenA = SideToken(LibClone.clone(address(implementation)));
        SideToken v3TokenB = SideToken(LibClone.clone(address(implementation)));
        bytes32 id = keccak256("fixed-market-v3");
        v3TokenA.initialize(id, 0, address(v3), "V3 A", "V3A");
        v3TokenB.initialize(id, 1, address(v3), "V3 B", "V3B");
        v3.initialize(
            id,
            3,
            address(this),
            address(usdc),
            address(v3TokenA),
            address(v3TokenB),
            address(new MockRiskController()),
            address(fees)
        );
        assertEq(v3.marketVersion(), 3);

        MarketVaultV3 wrongVersion = MarketVaultV3(LibClone.clone(address(new MarketVaultV3())));
        MockRiskController wrongVersionRisk = new MockRiskController();
        vm.expectRevert(abi.encodeWithSelector(MarketVaultV2.InvalidMarketVersion.selector, 2));
        wrongVersion.initialize(
            id,
            2,
            address(this),
            address(usdc),
            address(v3TokenA),
            address(v3TokenB),
            address(wrongVersionRisk),
            address(fees)
        );
    }

    function testTrustBoundaryGovernanceUpgradeCanSpendHistoricalFactoryAllowance() external {
        address governance = address(0x600d);
        MarketRegistry registry = new MarketRegistry(governance, governance);
        XBIDFactory factory = XBIDFactory(
            address(
                new ERC1967Proxy(
                    address(new XBIDFactory()),
                    abi.encodeCall(
                        XBIDFactory.initialize, (governance, address(usdc), address(registry), address(0x7ea0))
                    )
                )
            )
        );
        usdc.mint(VICTIM, 10_000e6);
        vm.prank(VICTIM);
        usdc.approve(address(factory), type(uint256).max);
        AuditOnlyHostileFactory hostile = new AuditOnlyHostileFactory();
        vm.expectRevert(XBIDFactory.Unauthorized.selector);
        vm.prank(ATTACKER);
        factory.upgradeToAndCall(address(hostile), "");
        // This requires compromising/controlling the authorized governance, NOT an unprivileged caller.
        vm.prank(governance);
        factory.upgradeToAndCall(address(hostile), "");
        AuditOnlyHostileFactory(address(factory)).pullHistoricalApproval(usdc, VICTIM, ATTACKER, 10_000e6);
        assertEq(usdc.balanceOf(ATTACKER), 10_000e6);
        assertEq(usdc.balanceOf(VICTIM), 0);
    }

    function testFuzzV2CycleCannotExtractExistingHoldersReserveEvenWithFullFeeRebate(uint256 seed) external {
        usdc.mint(VICTIM, 200_000e6);
        vm.startPrank(VICTIM);
        usdc.approve(address(market), type(uint256).max);
        market.buy(MarketVaultV2.Side.A, 100_000e6, 0, block.timestamp, address(0));
        market.buy(MarketVaultV2.Side.B, 100_000e6, 0, block.timestamp, address(0));
        vm.stopPrank();
        uint256 qA = market.qAWei();
        uint256 qB = market.qBWei();
        uint256 reserveBefore = market.reserveUnits();
        uint256 beforeBalance = usdc.balanceOf(address(this));
        uint256 feeBefore = usdc.balanceOf(address(fees));
        uint256 bought = market.buy(MarketVaultV2.Side.A, 1_000e6 + seed % 999_000e6, 0, block.timestamp, address(0));
        uint256 flipped = market.flip(MarketVaultV2.Side.A, bought, 0, block.timestamp);
        market.sellAll(MarketVaultV2.Side.B, flipped, 0, block.timestamp);
        uint256 cycleFees = usdc.balanceOf(address(fees)) - feeBefore;
        assertLe(usdc.balanceOf(address(this)) + cycleFees, beforeBalance);
        assertGe(market.reserveUnits(), reserveBefore);
        assertEq(market.qAWei(), qA);
        assertEq(market.qBWei(), qB);
    }

    function testFuzzV2BuyFlipSellCannotProfitWithoutOtherTraders(uint256 seed, bool sideA) external {
        uint256 gross = 1_000e6 + seed % 999_000e6;
        uint256 beforeBalance = usdc.balanceOf(address(this));
        MarketVaultV2.Side source = sideA ? MarketVaultV2.Side.A : MarketVaultV2.Side.B;
        MarketVaultV2.Side destination = sideA ? MarketVaultV2.Side.B : MarketVaultV2.Side.A;
        uint256 bought = market.buy(source, gross, 0, block.timestamp, address(0));
        uint256 flipped = market.flip(source, bought, 0, block.timestamp);
        market.sellAll(destination, flipped, 0, block.timestamp);
        uint256 afterBalance = usdc.balanceOf(address(this));
        assertLt(afterBalance, beforeBalance);
        assertEq(tokenA.totalSupply(), 0);
        assertEq(tokenB.totalSupply(), 0);
        assertEq(beforeBalance - afterBalance, usdc.balanceOf(address(market)) + usdc.balanceOf(address(fees)));
        assertGe(market.reserveUnits(), market.requiredReserveUnits());
    }
}
