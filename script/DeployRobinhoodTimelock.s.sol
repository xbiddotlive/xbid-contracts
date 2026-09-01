// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "solady/test/utils/forge-std/Script.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";

/// @notice Deploys XBID's least-privilege governance Timelock on Robinhood Testnet.
/// @dev The deployer receives no role. Governance Safe is the sole proposer,
///      canceller, and executor. Emergency Safe receives no Timelock role.
contract DeployRobinhoodTimelock is Script {
    error DeployerRoleCollision(address account);
    error InvalidSourceCommit();

    function run() external returns (TimelockController timelock) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        string memory sourceCommit = vm.envString("SOURCE_COMMIT");

        if (block.chainid != RobinhoodDeploymentConfig.CHAIN_ID) {
            revert RobinhoodDeploymentConfig.WrongChainId(block.chainid, RobinhoodDeploymentConfig.CHAIN_ID);
        }
        if (
            deployer == RobinhoodDeploymentConfig.GOVERNANCE_SAFE
                || deployer == RobinhoodDeploymentConfig.EMERGENCY_SAFE
        ) {
            revert DeployerRoleCollision(deployer);
        }
        uint256 sourceCommitLength = bytes(sourceCommit).length;
        if (sourceCommitLength != 40 && sourceCommitLength != 64) revert InvalidSourceCommit();

        RobinhoodDeploymentConfig.validateLockedSafes();

        address[] memory proposers = new address[](1);
        proposers[0] = RobinhoodDeploymentConfig.GOVERNANCE_SAFE;
        address[] memory executors = new address[](1);
        executors[0] = RobinhoodDeploymentConfig.GOVERNANCE_SAFE;

        vm.startBroadcast(deployerPrivateKey);
        timelock = new TimelockController(
            RobinhoodDeploymentConfig.TESTNET_GOVERNANCE_DELAY, proposers, executors, address(0)
        );
        vm.stopBroadcast();

        RobinhoodDeploymentConfig.validateLockedTimelock(address(timelock), deployer);
        _writeManifest(timelock, deployer, sourceCommit);
    }

    function _writeManifest(TimelockController timelock, address deployer, string memory sourceCommit) private {
        string memory object = "timelock";
        vm.serializeUint(object, "manifestVersion", 1);
        vm.serializeString(object, "environment", "robinhood-testnet");
        vm.serializeString(object, "status", "ACTIVE");
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeUint(object, "deploymentBlock", block.number);
        vm.serializeString(object, "sourceCommit", sourceCommit);
        vm.serializeAddress(object, "deployer", deployer);
        vm.serializeAddress(object, "governanceSafe", RobinhoodDeploymentConfig.GOVERNANCE_SAFE);
        vm.serializeAddress(object, "emergencySafe", RobinhoodDeploymentConfig.EMERGENCY_SAFE);
        vm.serializeAddress(object, "timelock", address(timelock));
        vm.serializeBytes32(object, "timelockCodeHash", address(timelock).codehash);
        vm.serializeUint(object, "minimumDelaySeconds", timelock.getMinDelay());
        vm.serializeAddress(object, "proposer", RobinhoodDeploymentConfig.GOVERNANCE_SAFE);
        vm.serializeAddress(object, "executor", RobinhoodDeploymentConfig.GOVERNANCE_SAFE);
        vm.serializeAddress(object, "canceller", RobinhoodDeploymentConfig.GOVERNANCE_SAFE);
        string memory json = vm.serializeAddress(object, "admin", address(timelock));

        string memory defaultPath = string.concat(vm.projectRoot(), "/deployments/robinhood-testnet/timelock.json");
        vm.writeJson(json, vm.envOr("TIMELOCK_OUTPUT_PATH", defaultPath));
    }
}
