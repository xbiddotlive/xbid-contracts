// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InvariantTest} from "solady/test/utils/InvariantTest.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {Vm} from "solady/test/utils/forge-std/Vm.sol";
import {MarketVaultV2} from "../../src/core/MarketVaultV2.sol";
import {SideToken} from "../../src/core/SideToken.sol";
import {XbidTradeMathV2} from "../../src/libraries/XbidTradeMathV2.sol";
import {XbidLmsrMathV2} from "../../src/libraries/XbidLmsrMathV2.sol";
import {MockFeeVault} from "../mocks/MockFeeVault.sol";
import {MockRiskController} from "../mocks/MockRiskController.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

contract MarketVaultV2Handler {
    Vm private constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MarketVaultV2 public immutable market;
    SideToken public immutable tokenA;
    SideToken public immutable tokenB;
    MockSettlementToken public immutable usdc;
    uint256 public unexpectedBuyFailures;

    constructor(MarketVaultV2 market_, SideToken tokenA_, SideToken tokenB_, MockSettlementToken usdc_) {
        market = market_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        usdc = usdc_;
        usdc_.approve(address(market_), type(uint256).max);
        tokenA_.approve(address(market_), type(uint256).max);
        tokenB_.approve(address(market_), type(uint256).max);
    }

    function buyA(uint256 seed) external {
        _buy(MarketVaultV2.Side.A, seed);
    }

    function buyB(uint256 seed) external {
        _buy(MarketVaultV2.Side.B, seed);
    }

    function sellA(uint256 seed) external {
        _sell(MarketVaultV2.Side.A, tokenA.balanceOf(address(this)), seed);
    }

    function sellB(uint256 seed) external {
        _sell(MarketVaultV2.Side.B, tokenB.balanceOf(address(this)), seed);
    }

    function flipA(uint256 seed) external {
        _flip(MarketVaultV2.Side.A, tokenA.balanceOf(address(this)), seed);
    }

    function flipB(uint256 seed) external {
        _flip(MarketVaultV2.Side.B, tokenB.balanceOf(address(this)), seed);
    }

    function sellAllA() external {
        _sellAll(MarketVaultV2.Side.A, tokenA.balanceOf(address(this)));
    }

    function sellAllB() external {
        _sellAll(MarketVaultV2.Side.B, tokenB.balanceOf(address(this)));
    }

    function advanceTimeAndFinalize(uint32 seed) external {
        VM.warp(block.timestamp + 1 + uint256(seed) % 120);
        try market.finalizeCrownChallenge() {} catch {}
    }

    function _buy(MarketVaultV2.Side side, uint256 seed) private {
        uint256 availableUnits = usdc.balanceOf(address(this));
        if (availableUnits < 1_000_000) return;
        uint256 qAWei = market.qAWei();
        uint256 qBWei = market.qBWei();
        uint256 maximum = XbidLmsrMathV2.maximumSideQuantityWad();
        uint256 currentCostWad = XbidLmsrMathV2.costWad(qAWei, qBWei);
        uint256 maximumCostWad = XbidLmsrMathV2.costWad(
            side == MarketVaultV2.Side.A ? maximum : qAWei, side == MarketVaultV2.Side.A ? qBWei : maximum
        );
        uint256 capacityUnits = (maximumCostWad - currentCostWad) / 1e12;
        if (capacityUnits < 1_000_000) return;
        uint256 maximumGross = availableUnits < capacityUnits ? availableUnits : capacityUnits;
        if (maximumGross > 29_600_000_000_000) maximumGross = 29_600_000_000_000;
        uint256 gross = 1_000_000 + seed % (maximumGross - 1_000_000 + 1);
        try market.buy(side, gross, 0, block.timestamp, address(0)) {}
        catch {
            unexpectedBuyFailures += 1;
        }
    }

    function _sell(MarketVaultV2.Side side, uint256 balance, uint256 seed) private {
        if (balance == 0) return;
        uint256 input = 1 + seed % balance;
        try market.sell(side, input, 0, block.timestamp) {} catch {}
    }

    function _flip(MarketVaultV2.Side side, uint256 balance, uint256 seed) private {
        if (balance == 0) return;
        uint256 input = 1 + seed % balance;
        try market.flip(side, input, 0, block.timestamp) {} catch {}
    }

    function _sellAll(MarketVaultV2.Side side, uint256 balance) private {
        if (balance == 0) return;
        try market.sellAll(side, balance, 0, block.timestamp) {} catch {}
    }
}

contract MarketVaultV2InvariantTest is InvariantTest {
    bytes32 private constant CONTEST_ID = keccak256("xbid-market-vault-v2-invariant");
    uint256 private constant INITIAL_USDC_UNITS = 1_000_000_000_000_000;

    MarketVaultV2 private market;
    SideToken private tokenA;
    SideToken private tokenB;
    MockSettlementToken private usdc;
    MockFeeVault private feeVault;
    MarketVaultV2Handler private handler;

    function setUp() public {
        MarketVaultV2 marketImplementation = new MarketVaultV2();
        SideToken tokenImplementation = new SideToken();
        usdc = new MockSettlementToken();
        MockRiskController riskController = new MockRiskController();
        feeVault = new MockFeeVault();

        market = MarketVaultV2(LibClone.clone(address(marketImplementation)));
        tokenA = SideToken(LibClone.clone(address(tokenImplementation)));
        tokenB = SideToken(LibClone.clone(address(tokenImplementation)));
        tokenA.initialize(CONTEST_ID, 0, address(market), "XBID A", "XA");
        tokenB.initialize(CONTEST_ID, 1, address(market), "XBID B", "XB");
        market.initialize(
            CONTEST_ID,
            2,
            address(this),
            address(usdc),
            address(tokenA),
            address(tokenB),
            address(riskController),
            address(feeVault)
        );

        handler = new MarketVaultV2Handler(market, tokenA, tokenB, usdc);
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
        XbidTradeMathV2.validateReserve(market.qAWei(), market.qBWei(), market.reserveUnits());
        require(handler.unexpectedBuyFailures() == 0, "executable V2 buy reverted");
    }

    function invariantCrownStateIsInternallyConsistent() external view {
        bool activated = market.crownActivated();
        MarketVaultV2.CrownSide currentCrown = market.crownSide();
        bool open = market.challengeOpen();
        uint64 hold = market.holdStartedAt();
        bool waitingForReset = market.needsResetBelow45();

        if (!activated) {
            require(currentCrown == MarketVaultV2.CrownSide.None, "inactive crown assigned");
            require(!open && hold == 0 && !waitingForReset, "inactive crown state dirty");
        }
        if (currentCrown == MarketVaultV2.CrownSide.None) {
            require(!open && hold == 0 && !waitingForReset, "unassigned crown state dirty");
        }
        if (open) {
            require(activated && currentCrown != MarketVaultV2.CrownSide.None, "challenge without crown");
            require(!waitingForReset, "challenge while reset blocked");
            if (currentCrown == MarketVaultV2.CrownSide.A) {
                require(market.challengerSide() == MarketVaultV2.Side.B, "A challenged by A");
            } else {
                require(market.challengerSide() == MarketVaultV2.Side.A, "B challenged by B");
            }
        }
        if (hold != 0) require(open, "hold without challenge");
        if (waitingForReset) require(!open && hold == 0, "reset state inconsistent");
        if (market.reserveUnits() >= market.CROWN_ACTIVATION_RESERVE_UNITS()) {
            require(activated, "activation threshold missed");
        }
    }
}
