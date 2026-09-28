// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IRiskController} from "../interfaces/IRiskController.sol";

/// @notice Non-custodial risk controller with delayed, scope-bound emergency recovery.
/// @dev New deployment only. Does not alter existing RiskController deployments.
///      Governance must be a separately validated Timelock. No arbitrary calls or asset access.
contract RiskControllerV2 is IRiskController {
    error Unauthorized();
    error InvalidRole();
    error InvalidMarket();
    error InvalidTransition();
    error InvalidRecovery();
    error RecoveryNotReady(uint256 readyAt);

    uint32 public constant riskControllerVersion = 2;
    uint256 public constant RECOVERY_DELAY = 5 minutes;
    address public immutable governanceTimelock;
    address public emergencyRole;
    RiskMode public override globalMode;
    mapping(address => RiskMode) public override marketMode;

    // Any risk-mode change or role rotation invalidates ALL pending recoveries.
    // This deliberately favors safety over allowing independent queues to survive incidents.
    uint256 public riskRevision;
    uint256 public recoveryNonce;

    struct Recovery {
        bytes32 id;
        uint256 revision;
        uint256 readyAt;
        RiskMode targetMode;
        bytes32 reasonHash;
    }
    // address(0) denotes global scope, otherwise the exact market address.
    mapping(address => Recovery) public recoveries;

    event RiskModeChanged(
        address indexed market, RiskMode oldMode, RiskMode newMode, address indexed actor, bytes32 reasonHash
    );
    event EmergencyRoleUpdated(address indexed oldRole, address indexed newRole);
    event RecoveryQueued(
        bytes32 indexed id,
        address indexed market,
        RiskMode targetMode,
        uint256 readyAt,
        uint256 revision,
        bytes32 reasonHash
    );
    event RecoveryCancelled(bytes32 indexed id, address indexed market, address indexed actor);
    event RecoveryExecuted(bytes32 indexed id, address indexed market, address indexed actor);

    constructor(address governanceTimelock_, address emergencyRole_) {
        if (
            governanceTimelock_ == address(0) || emergencyRole_ == address(0) || governanceTimelock_ == emergencyRole_
                || governanceTimelock_ == address(this) || emergencyRole_ == address(this)
        ) revert InvalidRole();
        governanceTimelock = governanceTimelock_;
        emergencyRole = emergencyRole_;
    }

    function setGlobalMode(RiskMode newMode, bytes32 reasonHash) external {
        _authorizeTransition(globalMode, newMode);
        _setMode(address(0), newMode, reasonHash);
    }

    function setMarketMode(address market, RiskMode newMode, bytes32 reasonHash) external {
        if (market == address(0)) revert InvalidMarket();
        _authorizeTransition(marketMode[market], newMode);
        _setMode(market, newMode, reasonHash);
    }

    function setEmergencyRole(address newRole) external {
        if (msg.sender != governanceTimelock) revert Unauthorized();
        if (
            newRole == address(0) || newRole == address(this) || newRole == governanceTimelock
                || newRole == emergencyRole
        ) revert InvalidRole();
        address oldRole = emergencyRole;
        emergencyRole = newRole;
        ++riskRevision;
        emit EmergencyRoleUpdated(oldRole, newRole);
    }

    /// @notice Queue a strictly less restrictive mode. Replacing a queue restarts its timer.
    function queueRecovery(address market, RiskMode targetMode, bytes32 reasonHash) external returns (bytes32 id) {
        if (msg.sender != emergencyRole) revert Unauthorized();
        if (uint8(targetMode) >= uint8(_mode(market))) revert InvalidTransition();
        Recovery memory previous = recoveries[market];
        if (previous.id != bytes32(0)) emit RecoveryCancelled(previous.id, market, msg.sender);
        id = keccak256(
            abi.encode(block.chainid, address(this), market, targetMode, riskRevision, ++recoveryNonce, reasonHash)
        );
        uint256 readyAt = block.timestamp + RECOVERY_DELAY;
        recoveries[market] = Recovery(id, riskRevision, readyAt, targetMode, reasonHash);
        emit RecoveryQueued(id, market, targetMode, readyAt, riskRevision, reasonHash);
    }

    /// @notice Explicit execution by the emergency Safe; time alone never unpauses trading.
    function executeRecovery(address market, bytes32 id) external {
        if (msg.sender != emergencyRole) revert Unauthorized();
        Recovery memory recovery = recoveries[market];
        if (id == bytes32(0) || recovery.id != id || recovery.revision != riskRevision) revert InvalidRecovery();
        if (block.timestamp < recovery.readyAt) revert RecoveryNotReady(recovery.readyAt);
        if (uint8(recovery.targetMode) >= uint8(_mode(market))) revert InvalidTransition();
        delete recoveries[market];
        _setMode(market, recovery.targetMode, recovery.reasonHash);
        emit RecoveryExecuted(id, market, msg.sender);
    }

    function cancelRecovery(address market, bytes32 id) external {
        if (msg.sender != emergencyRole && msg.sender != governanceTimelock) revert Unauthorized();
        if (id == bytes32(0) || recoveries[market].id != id) revert InvalidRecovery();
        delete recoveries[market];
        emit RecoveryCancelled(id, market, msg.sender);
    }

    function effectiveMode(address market) external view override returns (RiskMode) {
        RiskMode local = marketMode[market];
        return uint8(local) > uint8(globalMode) ? local : globalMode;
    }

    function _mode(address market) private view returns (RiskMode) {
        return market == address(0) ? globalMode : marketMode[market];
    }

    function _authorizeTransition(RiskMode oldMode, RiskMode newMode) private view {
        if (msg.sender != governanceTimelock && msg.sender != emergencyRole) revert Unauthorized();
        if (oldMode == newMode) revert InvalidTransition();
        if (msg.sender == emergencyRole && uint8(newMode) < uint8(oldMode)) revert Unauthorized();
    }

    function _setMode(address market, RiskMode newMode, bytes32 reasonHash) private {
        RiskMode oldMode = _mode(market);
        if (market == address(0)) globalMode = newMode;
        else marketMode[market] = newMode;
        ++riskRevision;
        emit RiskModeChanged(market, oldMode, newMode, msg.sender, reasonHash);
    }
}
