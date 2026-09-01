// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InvariantTest} from "solady/test/utils/InvariantTest.sol";
import {Vm} from "solady/test/utils/forge-std/Vm.sol";
import {RiskController} from "../../src/core/RiskController.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

contract RiskControllerHandler {
    Vm private constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address public constant GOVERNANCE = address(0x600d);
    address public constant EMERGENCY = address(0xe911);
    address public constant MARKET_A = address(0xa11ce);
    address public constant MARKET_B = address(0xb0b);

    RiskController public immutable controller;
    uint256 public illegalEmergencyDowngradeSuccesses;
    uint256 public unauthorizedModeChangeSuccesses;

    constructor() {
        controller = new RiskController(1, GOVERNANCE, EMERGENCY);
    }

    function governanceGlobal(uint8 modeSeed) external {
        IRiskController.RiskMode requested = IRiskController.RiskMode(modeSeed % 3);
        if (requested == controller.globalMode()) return;
        VM.prank(GOVERNANCE);
        controller.setGlobalMode(requested, keccak256("invariant-governance-global"));
    }

    function governanceMarket(uint8 marketSeed, uint8 modeSeed) external {
        address market = _market(marketSeed);
        IRiskController.RiskMode requested = IRiskController.RiskMode(modeSeed % 3);
        if (requested == controller.marketMode(market)) return;
        VM.prank(GOVERNANCE);
        controller.setMarketMode(market, requested, keccak256("invariant-governance-market"));
    }

    function emergencyEscalateGlobal() external {
        IRiskController.RiskMode current = controller.globalMode();
        if (current == IRiskController.RiskMode.FullPause) return;
        IRiskController.RiskMode requested = IRiskController.RiskMode(uint8(current) + 1);
        VM.prank(EMERGENCY);
        controller.setGlobalMode(requested, keccak256("invariant-emergency-global"));
    }

    function emergencyEscalateMarket(uint8 marketSeed) external {
        address market = _market(marketSeed);
        IRiskController.RiskMode current = controller.marketMode(market);
        if (current == IRiskController.RiskMode.FullPause) return;
        IRiskController.RiskMode requested = IRiskController.RiskMode(uint8(current) + 1);
        VM.prank(EMERGENCY);
        controller.setMarketMode(market, requested, keccak256("invariant-emergency-market"));
    }

    function emergencyTryDowngradeGlobal() external {
        IRiskController.RiskMode current = controller.globalMode();
        if (current == IRiskController.RiskMode.Normal) return;
        IRiskController.RiskMode requested = IRiskController.RiskMode(uint8(current) - 1);
        VM.prank(EMERGENCY);
        try controller.setGlobalMode(requested, keccak256("forbidden-global-downgrade")) {
            illegalEmergencyDowngradeSuccesses += 1;
        } catch {}
    }

    function emergencyTryDowngradeMarket(uint8 marketSeed) external {
        address market = _market(marketSeed);
        IRiskController.RiskMode current = controller.marketMode(market);
        if (current == IRiskController.RiskMode.Normal) return;
        IRiskController.RiskMode requested = IRiskController.RiskMode(uint8(current) - 1);
        VM.prank(EMERGENCY);
        try controller.setMarketMode(market, requested, keccak256("forbidden-market-downgrade")) {
            illegalEmergencyDowngradeSuccesses += 1;
        } catch {}
    }

    function unauthorizedTryChange(uint8 modeSeed) external {
        IRiskController.RiskMode requested = IRiskController.RiskMode(modeSeed % 3);
        if (requested == controller.globalMode()) {
            requested = IRiskController.RiskMode((uint8(requested) + 1) % 3);
        }
        try controller.setGlobalMode(requested, keccak256("unauthorized")) {
            unauthorizedModeChangeSuccesses += 1;
        } catch {}
    }

    function _market(uint8 seed) private pure returns (address) {
        return seed % 2 == 0 ? MARKET_A : MARKET_B;
    }
}

contract RiskControllerInvariantTest is InvariantTest {
    uint256 private constant DONATION_UNITS = 1_000_000_000;

    RiskController private controller;
    RiskControllerHandler private handler;
    MockSettlementToken private usdc;

    function setUp() public {
        handler = new RiskControllerHandler();
        controller = handler.controller();
        usdc = new MockSettlementToken();
        usdc.mint(address(controller), DONATION_UNITS);
        _addTargetContract(address(handler));
    }

    function invariantEffectiveModeIsMaximumForEveryTrackedMarket() external view {
        _assertEffectiveMaximum(handler.MARKET_A());
        _assertEffectiveMaximum(handler.MARKET_B());
        _assertEffectiveMaximum(address(0xCA201));
    }

    function invariantEmergencyAndUnauthorizedCallersNeverGainRecoveryPower() external view {
        require(handler.illegalEmergencyDowngradeSuccesses() == 0, "emergency downgraded mode");
        require(handler.unauthorizedModeChangeSuccesses() == 0, "unauthorized mode change");
    }

    function invariantControllerCannotMoveDonatedAssets() external view {
        require(usdc.balanceOf(address(controller)) == DONATION_UNITS, "controller moved funds");
    }

    function invariantImmutableConfigurationNeverChanges() external view {
        require(controller.riskControllerVersion() == 1, "version changed");
        require(controller.governanceTimelock() == handler.GOVERNANCE(), "governance changed");
        require(controller.emergencyRole() == handler.EMERGENCY(), "emergency changed");
    }

    function _assertEffectiveMaximum(address market) private view {
        IRiskController.RiskMode global = controller.globalMode();
        IRiskController.RiskMode local = controller.marketMode(market);
        IRiskController.RiskMode expected = uint8(local) > uint8(global) ? local : global;
        require(controller.effectiveMode(market) == expected, "effective mode mismatch");
    }
}
