// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IDeploymentSettlementToken {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IDeploymentGovernanceTimelock {
    function getMinDelay() external view returns (uint256);
}

/// @notice Locked network constants and reusable deployment preflight checks.
library RobinhoodDeploymentConfig {
    error WrongChainId(uint256 actual, uint256 expected);
    error ZeroAddress(string field);
    error InvalidContract(string field, address account);
    error InvalidSettlementCodeHash(bytes32 actual, bytes32 expected);
    error InvalidSettlementDecimals(uint8 actual, uint8 expected);
    error InvalidSettlementSymbol(string actual, string expected);
    error GovernanceEmergencyCollision(address account);
    error GovernanceDelayUnreadable(address account);
    error GovernanceDelayTooShort(uint256 actual, uint256 minimum);

    uint256 internal constant CHAIN_ID = 46_630;
    address internal constant SETTLEMENT_TOKEN = 0xAc80194dc1aE8eF52df73e7e1864fB3C62290fe0;
    bytes32 internal constant SETTLEMENT_TOKEN_RUNTIME_HASH =
        0xf45e11ddae86e83321f1f290f0e6e99f50dceb81d19b7edbf2bf1b1fbb0c9b5c;
    uint8 internal constant SETTLEMENT_TOKEN_DECIMALS = 6;
    string internal constant SETTLEMENT_TOKEN_SYMBOL = "USDC";

    uint32 internal constant MARKET_VERSION = 1;
    uint32 internal constant FEE_VAULT_VERSION = 1;
    uint32 internal constant RISK_CONTROLLER_VERSION = 1;
    uint32 internal constant ABI_VERSION = 1;
    uint16 internal constant PROTOCOL_BPS = 7_000;
    uint16 internal constant CREATOR_BPS = 2_000;
    uint16 internal constant REFERRER_BPS = 1_000;
    uint256 internal constant MIN_GOVERNANCE_DELAY = 48 hours;

    function validateLockedPreflight(
        address deployer,
        address governanceTimelock,
        address emergencyRole,
        address teamTreasury,
        address protocolTreasury
    ) internal view {
        validatePreflight(
            CHAIN_ID,
            SETTLEMENT_TOKEN,
            SETTLEMENT_TOKEN_RUNTIME_HASH,
            deployer,
            governanceTimelock,
            emergencyRole,
            teamTreasury,
            protocolTreasury
        );
    }

    function validatePreflight(
        uint256 expectedChainId,
        address settlementToken,
        bytes32 expectedSettlementRuntimeHash,
        address deployer,
        address governanceTimelock,
        address emergencyRole,
        address teamTreasury,
        address protocolTreasury
    ) internal view {
        if (block.chainid != expectedChainId) {
            revert WrongChainId(block.chainid, expectedChainId);
        }
        _requireNonZero("deployer", deployer);
        _requireNonZero("governanceTimelock", governanceTimelock);
        _requireNonZero("emergencyRole", emergencyRole);
        _requireNonZero("teamTreasury", teamTreasury);
        _requireNonZero("protocolTreasury", protocolTreasury);
        if (governanceTimelock.code.length == 0) {
            revert InvalidContract("governanceTimelock", governanceTimelock);
        }
        try IDeploymentGovernanceTimelock(governanceTimelock).getMinDelay() returns (uint256 delay) {
            if (delay < MIN_GOVERNANCE_DELAY) {
                revert GovernanceDelayTooShort(delay, MIN_GOVERNANCE_DELAY);
            }
        } catch {
            revert GovernanceDelayUnreadable(governanceTimelock);
        }
        if (governanceTimelock == emergencyRole) revert GovernanceEmergencyCollision(governanceTimelock);
        if (settlementToken.code.length == 0) revert InvalidContract("settlementToken", settlementToken);
        bytes32 actualRuntimeHash = settlementToken.codehash;
        if (actualRuntimeHash != expectedSettlementRuntimeHash) {
            revert InvalidSettlementCodeHash(actualRuntimeHash, expectedSettlementRuntimeHash);
        }
        uint8 actualDecimals = IDeploymentSettlementToken(settlementToken).decimals();
        if (actualDecimals != SETTLEMENT_TOKEN_DECIMALS) {
            revert InvalidSettlementDecimals(actualDecimals, SETTLEMENT_TOKEN_DECIMALS);
        }
        string memory actualSymbol = IDeploymentSettlementToken(settlementToken).symbol();
        if (keccak256(bytes(actualSymbol)) != keccak256(bytes(SETTLEMENT_TOKEN_SYMBOL))) {
            revert InvalidSettlementSymbol(actualSymbol, SETTLEMENT_TOKEN_SYMBOL);
        }
    }

    function _requireNonZero(string memory field, address account) private pure {
        if (account == address(0)) revert ZeroAddress(field);
    }
}
