// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {RiskController} from "../../src/core/RiskController.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";

contract RiskControllerTest is Test {
    address private constant GOVERNANCE = address(0x600d);
    address private constant EMERGENCY = address(0xe911);
    address private constant MARKET_A = address(0xa11ce);
    address private constant MARKET_B = address(0xb0b);

    RiskController private controller;

    function setUp() public {
        controller = new RiskController(1, GOVERNANCE, EMERGENCY);
    }

    function testConstructorLocksVersionRolesAndNormalDefaults() external {
        assertEq(controller.riskControllerVersion(), 1);
        assertEq(controller.governanceTimelock(), GOVERNANCE);
        assertEq(controller.emergencyRole(), EMERGENCY);
        assertEq(uint256(controller.globalMode()), uint256(IRiskController.RiskMode.Normal));
        assertEq(uint256(controller.marketMode(MARKET_A)), uint256(IRiskController.RiskMode.Normal));
        assertEq(uint256(controller.effectiveMode(MARKET_A)), uint256(IRiskController.RiskMode.Normal));
    }

    function testConstructorRejectsInvalidVersionOrRoles() external {
        vm.expectRevert(RiskController.InvalidRiskControllerVersion.selector);
        new RiskController(0, GOVERNANCE, EMERGENCY);

        vm.expectRevert(RiskController.ZeroAddress.selector);
        new RiskController(1, address(0), EMERGENCY);

        vm.expectRevert(RiskController.ZeroAddress.selector);
        new RiskController(1, GOVERNANCE, address(0));

        vm.expectRevert(abi.encodeWithSelector(RiskController.RoleCollision.selector, GOVERNANCE));
        new RiskController(1, GOVERNANCE, GOVERNANCE);
    }

    function testEffectiveModeAlwaysUsesStricterScope() external {
        vm.prank(GOVERNANCE);
        controller.setGlobalMode(IRiskController.RiskMode.RiskOff, keccak256("global incident"));
        vm.prank(GOVERNANCE);
        controller.setMarketMode(MARKET_A, IRiskController.RiskMode.FullPause, keccak256("market incident"));

        assertEq(uint256(controller.effectiveMode(MARKET_A)), uint256(IRiskController.RiskMode.FullPause));
        assertEq(uint256(controller.effectiveMode(MARKET_B)), uint256(IRiskController.RiskMode.RiskOff));

        vm.prank(GOVERNANCE);
        controller.setGlobalMode(IRiskController.RiskMode.FullPause, keccak256("global escalation"));
        assertEq(uint256(controller.effectiveMode(MARKET_A)), uint256(IRiskController.RiskMode.FullPause));
        assertEq(uint256(controller.effectiveMode(MARKET_B)), uint256(IRiskController.RiskMode.FullPause));
    }

    function testEmergencyCanOnlyStrictlyEscalateGlobalMode() external {
        vm.startPrank(EMERGENCY);
        controller.setGlobalMode(IRiskController.RiskMode.RiskOff, keccak256("risk off"));
        controller.setGlobalMode(IRiskController.RiskMode.FullPause, keccak256("full pause"));

        vm.expectRevert(
            abi.encodeWithSelector(
                RiskController.EmergencyCannotLowerRisk.selector,
                IRiskController.RiskMode.FullPause,
                IRiskController.RiskMode.RiskOff
            )
        );
        controller.setGlobalMode(IRiskController.RiskMode.RiskOff, keccak256("forbidden downgrade"));

        vm.expectRevert(
            abi.encodeWithSelector(
                RiskController.InvalidModeTransition.selector,
                IRiskController.RiskMode.FullPause,
                IRiskController.RiskMode.FullPause
            )
        );
        controller.setGlobalMode(IRiskController.RiskMode.FullPause, keccak256("duplicate"));
        vm.stopPrank();
    }

    function testEmergencyCanOnlyStrictlyEscalatePerMarketMode() external {
        vm.startPrank(EMERGENCY);
        controller.setMarketMode(MARKET_A, IRiskController.RiskMode.RiskOff, keccak256("market risk off"));
        controller.setMarketMode(MARKET_A, IRiskController.RiskMode.FullPause, keccak256("market full pause"));

        vm.expectRevert(
            abi.encodeWithSelector(
                RiskController.EmergencyCannotLowerRisk.selector,
                IRiskController.RiskMode.FullPause,
                IRiskController.RiskMode.Normal
            )
        );
        controller.setMarketMode(MARKET_A, IRiskController.RiskMode.Normal, keccak256("forbidden recovery"));
        vm.stopPrank();

        assertEq(uint256(controller.marketMode(MARKET_B)), uint256(IRiskController.RiskMode.Normal));
    }

    function testGovernanceCanEscalateAndRecoverEachScope() external {
        vm.startPrank(GOVERNANCE);
        controller.setGlobalMode(IRiskController.RiskMode.FullPause, keccak256("global stop"));
        controller.setMarketMode(MARKET_A, IRiskController.RiskMode.FullPause, keccak256("market stop"));
        controller.setGlobalMode(IRiskController.RiskMode.Normal, keccak256("global recovery"));
        controller.setMarketMode(MARKET_A, IRiskController.RiskMode.Normal, keccak256("market recovery"));
        vm.stopPrank();

        assertEq(uint256(controller.effectiveMode(MARKET_A)), uint256(IRiskController.RiskMode.Normal));
    }

    function testUnauthorizedCallerCannotChangeModesOrEmergencyRole() external {
        vm.expectRevert(RiskController.Unauthorized.selector);
        controller.setGlobalMode(IRiskController.RiskMode.RiskOff, bytes32(0));

        vm.expectRevert(RiskController.Unauthorized.selector);
        controller.setMarketMode(MARKET_A, IRiskController.RiskMode.FullPause, bytes32(0));

        vm.expectRevert(RiskController.Unauthorized.selector);
        controller.setEmergencyRole(address(0x9999));
    }

    function testGovernanceRotatesEmergencyRoleAndOldRoleImmediatelyLosesPower() external {
        address newEmergency = address(0x9999);
        vm.prank(GOVERNANCE);
        controller.setEmergencyRole(newEmergency);
        assertEq(controller.emergencyRole(), newEmergency);

        vm.expectRevert(RiskController.Unauthorized.selector);
        vm.prank(EMERGENCY);
        controller.setGlobalMode(IRiskController.RiskMode.RiskOff, bytes32(0));

        vm.prank(newEmergency);
        controller.setGlobalMode(IRiskController.RiskMode.RiskOff, bytes32(0));
        assertEq(uint256(controller.globalMode()), uint256(IRiskController.RiskMode.RiskOff));
    }

    function testRejectsZeroMarketAndInvalidEmergencyRole() external {
        vm.expectRevert(RiskController.ZeroAddress.selector);
        vm.prank(GOVERNANCE);
        controller.setMarketMode(address(0), IRiskController.RiskMode.RiskOff, bytes32(0));

        vm.expectRevert(RiskController.ZeroAddress.selector);
        vm.prank(GOVERNANCE);
        controller.setEmergencyRole(address(0));

        vm.expectRevert(RiskController.ZeroAddress.selector);
        vm.prank(GOVERNANCE);
        controller.setEmergencyRole(address(controller));

        vm.expectRevert(abi.encodeWithSelector(RiskController.RoleCollision.selector, GOVERNANCE));
        vm.prank(GOVERNANCE);
        controller.setEmergencyRole(GOVERNANCE);
    }

    function testFuzzEffectiveModeIsMaximum(uint8 globalSeed, uint8 marketSeed) external {
        IRiskController.RiskMode requestedGlobal = IRiskController.RiskMode(globalSeed % 3);
        IRiskController.RiskMode requestedMarket = IRiskController.RiskMode(marketSeed % 3);

        vm.startPrank(GOVERNANCE);
        if (requestedGlobal != IRiskController.RiskMode.Normal) {
            controller.setGlobalMode(requestedGlobal, bytes32(0));
        }
        if (requestedMarket != IRiskController.RiskMode.Normal) {
            controller.setMarketMode(MARKET_A, requestedMarket, bytes32(0));
        }
        vm.stopPrank();

        IRiskController.RiskMode expected =
            uint8(requestedMarket) > uint8(requestedGlobal) ? requestedMarket : requestedGlobal;
        assertEq(uint256(controller.effectiveMode(MARKET_A)), uint256(expected));
    }
}
