// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "solady/test/utils/forge-std/Script.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";

/// @notice Read-only validator for the deployed Robinhood Testnet Timelock.
contract ValidateRobinhoodTimelock is Script {
    error ValidationFailed(string check);

    function run() external view {
        string memory defaultPath = string.concat(vm.projectRoot(), "/deployments/robinhood-testnet/timelock.json");
        string memory json = vm.readFile(vm.envOr("TIMELOCK_MANIFEST_PATH", defaultPath));

        _require(block.chainid == RobinhoodDeploymentConfig.CHAIN_ID, "runtime chain id");
        _require(vm.parseJsonUint(json, ".manifestVersion") == 1, "manifest version");
        _require(vm.parseJsonUint(json, ".chainId") == RobinhoodDeploymentConfig.CHAIN_ID, "manifest chain id");
        _require(keccak256(bytes(vm.parseJsonString(json, ".status"))) == keccak256(bytes("ACTIVE")), "manifest status");
        _require(vm.parseJsonUint(json, ".simulationBlock") > 0, "simulation block");
        _require(vm.parseJsonUint(json, ".deploymentBlock") > 0, "deployment block");
        _require(vm.parseJsonBytes32(json, ".deploymentTransactionHash") != bytes32(0), "deployment transaction");
        _require(
            vm.parseJsonAddress(json, ".governanceSafe") == RobinhoodDeploymentConfig.GOVERNANCE_SAFE, "governance safe"
        );
        _require(
            vm.parseJsonAddress(json, ".emergencySafe") == RobinhoodDeploymentConfig.EMERGENCY_SAFE, "emergency safe"
        );
        _require(
            vm.parseJsonUint(json, ".minimumDelaySeconds") == RobinhoodDeploymentConfig.TESTNET_GOVERNANCE_DELAY,
            "manifest delay"
        );

        address timelockAddress = vm.parseJsonAddress(json, ".timelock");
        address deployer = vm.parseJsonAddress(json, ".deployer");
        _require(timelockAddress.code.length != 0, "timelock code");
        _require(timelockAddress.codehash == vm.parseJsonBytes32(json, ".timelockCodeHash"), "timelock code hash");
        _require(TimelockController(payable(timelockAddress)).getMinDelay() == 5 minutes, "runtime delay");
        _require(vm.parseJsonAddress(json, ".proposer") == RobinhoodDeploymentConfig.GOVERNANCE_SAFE, "proposer");
        _require(vm.parseJsonAddress(json, ".executor") == RobinhoodDeploymentConfig.GOVERNANCE_SAFE, "executor");
        _require(vm.parseJsonAddress(json, ".canceller") == RobinhoodDeploymentConfig.GOVERNANCE_SAFE, "canceller");
        _require(vm.parseJsonAddress(json, ".admin") == timelockAddress, "self admin");

        RobinhoodDeploymentConfig.validateLockedSafes();
        RobinhoodDeploymentConfig.validateLockedTimelock(timelockAddress, deployer);
    }

    function _require(bool condition, string memory check) private pure {
        if (!condition) revert ValidationFailed(check);
    }
}
