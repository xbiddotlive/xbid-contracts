// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IRiskController} from "../interfaces/IRiskController.sol";

/// @notice Non-upgradeable, non-custodial emergency mode controller for XBID markets.
/// @dev Emergency can only increase a scope's mode. Governance can recover or
///      otherwise change modes after the protocol's off-chain Timelock process.
contract RiskController is IRiskController {
    error ZeroAddress();
    error RoleCollision(address account);
    error InvalidRiskControllerVersion();
    error Unauthorized();
    error EmergencyCannotLowerRisk(RiskMode currentMode, RiskMode requestedMode);
    error InvalidModeTransition(RiskMode currentMode, RiskMode requestedMode);

    enum RiskScope {
        Global,
        Market
    }

    event RiskModeChanged(
        RiskScope indexed scope,
        address indexed market,
        bytes32 indexed reasonHash,
        RiskMode oldMode,
        RiskMode newMode,
        address actor,
        uint256 effectiveAt
    );
    event EmergencyRoleUpdated(address indexed oldEmergencyRole, address indexed newEmergencyRole);

    uint32 public immutable riskControllerVersion;
    address public immutable governanceTimelock;

    address public emergencyRole;
    RiskMode public override globalMode;
    mapping(address market => RiskMode mode) public override marketMode;

    constructor(uint32 riskControllerVersion_, address governanceTimelock_, address emergencyRole_) {
        if (riskControllerVersion_ == 0) revert InvalidRiskControllerVersion();
        if (governanceTimelock_ == address(0) || emergencyRole_ == address(0)) revert ZeroAddress();
        if (governanceTimelock_ == address(this) || emergencyRole_ == address(this)) revert ZeroAddress();
        if (governanceTimelock_ == emergencyRole_) revert RoleCollision(governanceTimelock_);

        riskControllerVersion = riskControllerVersion_;
        governanceTimelock = governanceTimelock_;
        emergencyRole = emergencyRole_;
    }

    /// @notice Changes the global mode. Emergency may only strictly increase it.
    function setGlobalMode(RiskMode newMode, bytes32 reasonHash) external {
        RiskMode oldMode = globalMode;
        _authorizeTransition(oldMode, newMode);
        globalMode = newMode;
        emit RiskModeChanged(RiskScope.Global, address(0), reasonHash, oldMode, newMode, msg.sender, block.timestamp);
    }

    /// @notice Changes one market's local mode. Emergency may only strictly increase it.
    function setMarketMode(address market, RiskMode newMode, bytes32 reasonHash) external {
        if (market == address(0)) revert ZeroAddress();
        RiskMode oldMode = marketMode[market];
        _authorizeTransition(oldMode, newMode);
        marketMode[market] = newMode;
        emit RiskModeChanged(RiskScope.Market, market, reasonHash, oldMode, newMode, msg.sender, block.timestamp);
    }

    function setEmergencyRole(address newEmergencyRole) external {
        if (msg.sender != governanceTimelock) revert Unauthorized();
        if (newEmergencyRole == address(0) || newEmergencyRole == address(this)) revert ZeroAddress();
        if (newEmergencyRole == governanceTimelock) revert RoleCollision(newEmergencyRole);
        address oldEmergencyRole = emergencyRole;
        emergencyRole = newEmergencyRole;
        emit EmergencyRoleUpdated(oldEmergencyRole, newEmergencyRole);
    }

    /// @notice Returns the stricter of global and per-market modes in constant time.
    function effectiveMode(address market) external view override returns (RiskMode) {
        RiskMode localMode = marketMode[market];
        RiskMode currentGlobalMode = globalMode;
        return uint8(localMode) > uint8(currentGlobalMode) ? localMode : currentGlobalMode;
    }

    function _authorizeTransition(RiskMode oldMode, RiskMode newMode) private view {
        if (oldMode == newMode) revert InvalidModeTransition(oldMode, newMode);
        if (msg.sender == governanceTimelock) return;
        if (msg.sender != emergencyRole) revert Unauthorized();
        if (uint8(newMode) < uint8(oldMode)) revert EmergencyCannotLowerRisk(oldMode, newMode);
    }
}
