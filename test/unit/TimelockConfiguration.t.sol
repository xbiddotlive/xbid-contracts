// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "solady/test/utils/forge-std/Test.sol";
import {RobinhoodDeploymentConfig} from "../../script/RobinhoodDeploymentConfig.sol";

contract TimelockConfigurationHarness {
    function validate(address timelock, address deployer) external view {
        RobinhoodDeploymentConfig.validateLockedTimelock(timelock, deployer);
    }
}

contract TimelockTarget {
    uint256 public value;

    function setValue(uint256 value_) external {
        value = value_;
    }
}

contract TimelockConfigurationTest is Test {
    address private constant GOVERNANCE = 0xf72028a7f304e0585bdF7cd8BB0E0cB91fF2fBe1;
    address private constant EMERGENCY = 0x7f4601752bd49155c47A943893Ddb13C9f1Aa446;
    address private constant DEPLOYER = address(0xd001);

    TimelockConfigurationHarness private harness;

    function setUp() external {
        harness = new TimelockConfigurationHarness();
    }

    function testLockedLeastPrivilegeRoleMatrix() external {
        TimelockController timelock = _deploy(_single(GOVERNANCE), _single(GOVERNANCE), address(0));

        harness.validate(address(timelock), DEPLOYER);
        assertEq(timelock.getMinDelay(), 5 minutes);
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), DEPLOYER));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), GOVERNANCE));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), GOVERNANCE));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), GOVERNANCE));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), EMERGENCY));
    }

    function testRejectsOpenExecution() external {
        TimelockController timelock = _deploy(_single(GOVERNANCE), _single(address(0)), address(0));
        vm.expectRevert();
        harness.validate(address(timelock), DEPLOYER);
    }

    function testRejectsEmergencyGovernanceRole() external {
        address[] memory proposers = new address[](2);
        proposers[0] = GOVERNANCE;
        proposers[1] = EMERGENCY;
        TimelockController timelock = _deploy(proposers, _single(GOVERNANCE), address(0));
        vm.expectRevert();
        harness.validate(address(timelock), DEPLOYER);
    }

    function testRejectsTemporaryDeployerAdmin() external {
        TimelockController timelock = _deploy(_single(GOVERNANCE), _single(GOVERNANCE), DEPLOYER);
        vm.expectRevert();
        harness.validate(address(timelock), DEPLOYER);
    }

    function testRejectsUnexpectedLongerTestnetDelay() external {
        TimelockController timelock =
            new TimelockController(5 minutes + 1, _single(GOVERNANCE), _single(GOVERNANCE), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodDeploymentConfig.GovernanceDelayMismatch.selector, 5 minutes + 1, 5 minutes)
        );
        harness.validate(address(timelock), DEPLOYER);
    }

    function testScheduledOperationCannotExecuteBeforeExactlyFiveMinutes() external {
        TimelockController timelock = _deploy(_single(GOVERNANCE), _single(GOVERNANCE), address(0));
        TimelockTarget target = new TimelockTarget();
        bytes memory payload = abi.encodeCall(TimelockTarget.setValue, (42));
        bytes32 predecessor;
        bytes32 salt = keccak256("xbid-testnet-five-minute-delay");

        vm.prank(GOVERNANCE);
        timelock.schedule(address(target), 0, payload, predecessor, salt, 5 minutes);

        vm.warp(block.timestamp + 5 minutes - 1);
        vm.prank(GOVERNANCE);
        vm.expectRevert();
        timelock.execute(address(target), 0, payload, predecessor, salt);

        vm.warp(block.timestamp + 1);
        vm.prank(GOVERNANCE);
        timelock.execute(address(target), 0, payload, predecessor, salt);
        assertEq(target.value(), 42);
    }

    function _deploy(address[] memory proposers, address[] memory executors, address admin)
        private
        returns (TimelockController)
    {
        return new TimelockController(5 minutes, proposers, executors, admin);
    }

    function _single(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
