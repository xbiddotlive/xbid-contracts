// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {RiskControllerV2} from "../../src/core/RiskControllerV2.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";

contract RiskControllerV2Test is Test {
    address constant GOVERNOR = address(0x600d);
    address constant EMERGENCY = address(0xe911);
    address constant MARKET = address(0xbeef);
    address constant OTHER = address(0xcafe);
    RiskControllerV2 risk;
    TimelockController timelock;

    function setUp() public {
        address[] memory owners = new address[](1);
        owners[0] = GOVERNOR;
        timelock = new TimelockController(600, owners, owners, address(0));
        risk = new RiskControllerV2(address(timelock), EMERGENCY);
    }

    function _pause(address market, IRiskController.RiskMode mode) private {
        vm.prank(EMERGENCY);
        if (market == address(0)) risk.setGlobalMode(mode, bytes32(0));
        else risk.setMarketMode(market, mode, bytes32(0));
    }

    function _queue(address market, IRiskController.RiskMode target) private returns (bytes32) {
        vm.prank(EMERGENCY);
        return risk.queueRecovery(market, target, bytes32(0));
    }

    function _execute(address market, bytes32 id) private {
        vm.prank(EMERGENCY);
        risk.executeRecovery(market, id);
    }

    function testImmediatePauseDelayedRecoveryAndReplayProtection() public {
        _pause(address(0), IRiskController.RiskMode.FullPause);
        assertEq(uint256(risk.effectiveMode(MARKET)), 2);
        bytes32 id = _queue(address(0), IRiskController.RiskMode.Normal);
        vm.warp(block.timestamp + 299);
        vm.expectRevert(abi.encodeWithSelector(RiskControllerV2.RecoveryNotReady.selector, block.timestamp + 1));
        _execute(address(0), id);
        vm.warp(block.timestamp + 1);
        assertEq(uint256(risk.effectiveMode(MARKET)), 2); // No automatic recovery.
        _execute(address(0), id);
        assertEq(uint256(risk.effectiveMode(MARKET)), 0);
        vm.expectRevert(RiskControllerV2.InvalidRecovery.selector);
        _execute(address(0), id);
    }

    function testNewIncidentInvalidatesGlobalAndMarketQueues() public {
        _pause(address(0), IRiskController.RiskMode.RiskOff);
        _pause(MARKET, IRiskController.RiskMode.RiskOff);
        bytes32 globalId = _queue(address(0), IRiskController.RiskMode.Normal);
        bytes32 marketId = _queue(MARKET, IRiskController.RiskMode.Normal);
        _pause(OTHER, IRiskController.RiskMode.FullPause);
        vm.warp(block.timestamp + 300);
        vm.expectRevert(RiskControllerV2.InvalidRecovery.selector);
        _execute(address(0), globalId);
        vm.expectRevert(RiskControllerV2.InvalidRecovery.selector);
        _execute(MARKET, marketId);
    }

    function testRecoveryCannotOverrideOtherScope() public {
        _pause(address(0), IRiskController.RiskMode.FullPause);
        _pause(MARKET, IRiskController.RiskMode.RiskOff);
        bytes32 id = _queue(MARKET, IRiskController.RiskMode.Normal);
        vm.warp(block.timestamp + 300);
        _execute(MARKET, id);
        assertEq(uint256(risk.effectiveMode(MARKET)), 2);
        _pause(MARKET, IRiskController.RiskMode.FullPause);
        id = _queue(address(0), IRiskController.RiskMode.Normal);
        vm.warp(block.timestamp + 300);
        _execute(address(0), id);
        assertEq(uint256(risk.effectiveMode(MARKET)), 2);
        assertEq(uint256(risk.effectiveMode(OTHER)), 0);
    }

    function testCancelAndReplacementResetDelay() public {
        _pause(MARKET, IRiskController.RiskMode.FullPause);
        bytes32 first = _queue(MARKET, IRiskController.RiskMode.Normal);
        vm.warp(block.timestamp + 299);
        bytes32 second = _queue(MARKET, IRiskController.RiskMode.RiskOff);
        vm.expectRevert(RiskControllerV2.InvalidRecovery.selector);
        _execute(MARKET, first);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(RiskControllerV2.RecoveryNotReady.selector, block.timestamp + 299));
        _execute(MARKET, second);
        vm.prank(EMERGENCY);
        risk.cancelRecovery(MARKET, second);
        vm.warp(block.timestamp + 300);
        vm.expectRevert(RiskControllerV2.InvalidRecovery.selector);
        _execute(MARKET, second);
    }

    function testScopeAndCallerBinding() public {
        _pause(MARKET, IRiskController.RiskMode.FullPause);
        bytes32 id = _queue(MARKET, IRiskController.RiskMode.Normal);
        vm.warp(block.timestamp + 300);
        vm.expectRevert(RiskControllerV2.Unauthorized.selector);
        risk.executeRecovery(MARKET, id);
        vm.expectRevert(RiskControllerV2.Unauthorized.selector);
        risk.cancelRecovery(MARKET, id);
        vm.expectRevert(RiskControllerV2.Unauthorized.selector);
        risk.queueRecovery(MARKET, IRiskController.RiskMode.Normal, bytes32(0));
        vm.expectRevert(RiskControllerV2.InvalidRecovery.selector);
        _execute(OTHER, id);
        vm.expectRevert(RiskControllerV2.Unauthorized.selector);
        vm.prank(EMERGENCY);
        risk.setMarketMode(MARKET, IRiskController.RiskMode.Normal, bytes32(0));
    }

    function testGovernanceRequires600SecondsAndRotationInvalidatesQueue() public {
        _pause(MARKET, IRiskController.RiskMode.FullPause);
        bytes32 id = _queue(MARKET, IRiskController.RiskMode.Normal);
        bytes memory data = abi.encodeCall(risk.setEmergencyRole, (OTHER));
        vm.expectRevert();
        vm.prank(EMERGENCY);
        timelock.schedule(address(risk), 0, data, bytes32(0), bytes32(0), 600);
        vm.prank(GOVERNOR);
        timelock.schedule(address(risk), 0, data, bytes32(0), bytes32(0), 600);
        vm.warp(block.timestamp + 599);
        vm.expectRevert();
        vm.prank(GOVERNOR);
        timelock.execute(address(risk), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 1);
        vm.prank(GOVERNOR);
        timelock.execute(address(risk), 0, data, bytes32(0), bytes32(0));
        vm.expectRevert(RiskControllerV2.Unauthorized.selector);
        _execute(MARKET, id);
        vm.expectRevert(RiskControllerV2.InvalidRecovery.selector);
        vm.prank(OTHER);
        risk.executeRecovery(MARKET, id);
    }

    function testGovernanceRecoveryThenRePauseInvalidatesOldQueue() public {
        _pause(MARKET, IRiskController.RiskMode.FullPause);
        bytes32 id = _queue(MARKET, IRiskController.RiskMode.Normal);
        vm.prank(address(timelock));
        risk.setMarketMode(MARKET, IRiskController.RiskMode.Normal, bytes32(0));
        _pause(MARKET, IRiskController.RiskMode.FullPause);
        vm.warp(block.timestamp + 300);
        vm.expectRevert(RiskControllerV2.InvalidRecovery.selector);
        _execute(MARKET, id);
    }

    function testGovernanceCanCancelAndEmergencyCannotRotateRoles() public {
        _pause(address(0), IRiskController.RiskMode.FullPause);
        bytes32 id = _queue(address(0), IRiskController.RiskMode.Normal);
        vm.prank(address(timelock));
        risk.cancelRecovery(address(0), id);
        vm.warp(block.timestamp + 300);
        vm.expectRevert(RiskControllerV2.InvalidRecovery.selector);
        _execute(address(0), id);
        vm.expectRevert(RiskControllerV2.Unauthorized.selector);
        vm.prank(EMERGENCY);
        risk.setEmergencyRole(OTHER);
    }

    function testInvalidRolesModesAndMarkets() public {
        vm.expectRevert(RiskControllerV2.InvalidRole.selector);
        new RiskControllerV2(address(0), EMERGENCY);
        vm.expectRevert(RiskControllerV2.InvalidRole.selector);
        new RiskControllerV2(EMERGENCY, EMERGENCY);
        vm.expectRevert(RiskControllerV2.InvalidTransition.selector);
        _queue(MARKET, IRiskController.RiskMode.Normal);
        vm.expectRevert(RiskControllerV2.InvalidMarket.selector);
        vm.prank(EMERGENCY);
        risk.setMarketMode(address(0), IRiskController.RiskMode.FullPause, bytes32(0));
    }

    function testFuzzNoRecoveryBeforeDelay(uint32 secondsElapsed) public {
        uint256 elapsed = uint256(secondsElapsed) % 300;
        _pause(MARKET, IRiskController.RiskMode.FullPause);
        bytes32 id = _queue(MARKET, IRiskController.RiskMode.RiskOff);
        uint256 readyAt = block.timestamp + 300;
        vm.warp(block.timestamp + elapsed);
        vm.expectRevert(abi.encodeWithSelector(RiskControllerV2.RecoveryNotReady.selector, readyAt));
        _execute(MARKET, id);
        assertEq(uint256(risk.marketMode(MARKET)), 2);
    }
}
