// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IDeploymentSettlementToken {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IDeploymentGovernanceTimelock {
    function getMinDelay() external view returns (uint256);

    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

    function PROPOSER_ROLE() external view returns (bytes32);

    function EXECUTOR_ROLE() external view returns (bytes32);

    function CANCELLER_ROLE() external view returns (bytes32);

    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IDeploymentSafe {
    function masterCopy() external view returns (address);

    function getThreshold() external view returns (uint256);

    function getOwners() external view returns (address[] memory);

    function VERSION() external view returns (string memory);

    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);

    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory);
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
    error UnexpectedRoleAddress(string field, address actual, address expected);
    error InvalidSafeSingleton(string field, address actual, address expected);
    error InvalidSafeVersion(string field, string actual, string expected);
    error InvalidSafeThreshold(string field, uint256 actual, uint256 expected);
    error InvalidSafeOwners(string field);
    error InvalidSafeModules(string field);
    error InvalidSafeGuard(string field, address actual);
    error InvalidSafeModuleGuard(string field, address actual);
    error InvalidSafeFallbackHandler(string field, address actual, address expected);
    error GovernanceDelayMismatch(uint256 actual, uint256 expected);
    error InvalidTimelockRole(bytes32 role, address account, bool expected);

    uint256 internal constant CHAIN_ID = 46_630;
    address internal constant SETTLEMENT_TOKEN = 0xAc80194dc1aE8eF52df73e7e1864fB3C62290fe0;
    bytes32 internal constant SETTLEMENT_TOKEN_RUNTIME_HASH =
        0xf45e11ddae86e83321f1f290f0e6e99f50dceb81d19b7edbf2bf1b1fbb0c9b5c;
    uint8 internal constant SETTLEMENT_TOKEN_DECIMALS = 6;
    string internal constant SETTLEMENT_TOKEN_SYMBOL = "USDC";

    address internal constant GOVERNANCE_SAFE = 0xf72028a7f304e0585bdF7cd8BB0E0cB91fF2fBe1;
    address internal constant EMERGENCY_SAFE = 0x7f4601752bd49155c47A943893Ddb13C9f1Aa446;
    address internal constant TEAM_TREASURY = 0x6AE1c7B6c583E50777002b70FE289321f23B8fF3;
    address internal constant PROTOCOL_TREASURY = 0x786c860A8659b63Ebdf885a93a78282b2C80214b;
    address internal constant SAFE_L2_SINGLETON_V1_4_1 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_FALLBACK_HANDLER_V1_4_1 = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address internal constant SAFE_MODULE_SENTINEL = address(0x1);
    string internal constant SAFE_VERSION = "1.4.1";
    uint256 internal constant SAFE_THRESHOLD = 2;
    uint256 internal constant SAFE_OWNER_COUNT = 3;
    bytes32 internal constant SAFE_FALLBACK_HANDLER_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;
    bytes32 internal constant SAFE_GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 internal constant SAFE_MODULE_GUARD_SLOT =
        0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947;

    address internal constant GOVERNANCE_OWNER_1 = 0x9352e25bCE67fE650BC8Ab7fBda5E92c36273E91;
    address internal constant GOVERNANCE_OWNER_2 = 0x9A7A0fa83cA804a56e52853EB4DAFbcc52f998d7;
    address internal constant GOVERNANCE_OWNER_3 = 0xADaA6e8cf259A12BF47616D90023784dC39dA345;

    address internal constant EMERGENCY_OWNER_1 = 0xC103944a67Da5C1b329283C60b0D6CE12A80e3BB;
    address internal constant EMERGENCY_OWNER_2 = 0xC1C5540e11500ead7955B8768d99903638cb808c;
    address internal constant EMERGENCY_OWNER_3 = 0x5AecEf58fC44cB781a57359f93c9Da5125305647;

    uint32 internal constant MARKET_VERSION = 1;
    uint32 internal constant FEE_VAULT_VERSION = 1;
    uint32 internal constant RISK_CONTROLLER_VERSION = 1;
    uint32 internal constant ABI_VERSION = 1;
    uint16 internal constant PROTOCOL_BPS = 7_000;
    uint16 internal constant CREATOR_BPS = 2_000;
    uint16 internal constant REFERRER_BPS = 1_000;
    uint256 internal constant TESTNET_GOVERNANCE_DELAY = 5 minutes;
    uint256 internal constant MAINNET_GOVERNANCE_DELAY = 48 hours;

    function validateLockedPreflight(
        address deployer,
        address governanceTimelock,
        address emergencyRole,
        address teamTreasury,
        address protocolTreasury
    ) internal view {
        if (emergencyRole != EMERGENCY_SAFE) {
            revert UnexpectedRoleAddress("emergencyRole", emergencyRole, EMERGENCY_SAFE);
        }
        if (teamTreasury != TEAM_TREASURY) {
            revert UnexpectedRoleAddress("teamTreasury", teamTreasury, TEAM_TREASURY);
        }
        if (protocolTreasury != PROTOCOL_TREASURY) {
            revert UnexpectedRoleAddress("protocolTreasury", protocolTreasury, PROTOCOL_TREASURY);
        }
        validateLockedSafes();
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
        validateLockedTimelock(governanceTimelock, deployer);
    }

    /// @notice Verifies both user-created Safe proxies and their exact 2-of-3 owner sets.
    function validateLockedSafes() internal view {
        address[3] memory governanceOwners = [GOVERNANCE_OWNER_1, GOVERNANCE_OWNER_2, GOVERNANCE_OWNER_3];
        address[3] memory emergencyOwners = [EMERGENCY_OWNER_1, EMERGENCY_OWNER_2, EMERGENCY_OWNER_3];
        _validateSafe("governanceSafe", GOVERNANCE_SAFE, governanceOwners);
        _validateSafe("emergencySafe", EMERGENCY_SAFE, emergencyOwners);
    }

    /// @notice Verifies the least-privilege Timelock role matrix used on Robinhood Testnet.
    function validateLockedTimelock(address governanceTimelock, address deployer) internal view {
        IDeploymentGovernanceTimelock timelock = IDeploymentGovernanceTimelock(governanceTimelock);
        uint256 delay = timelock.getMinDelay();
        if (delay != TESTNET_GOVERNANCE_DELAY) {
            revert GovernanceDelayMismatch(delay, TESTNET_GOVERNANCE_DELAY);
        }
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();

        _requireRole(timelock, adminRole, governanceTimelock, true);
        _requireRole(timelock, adminRole, deployer, false);
        _requireRole(timelock, adminRole, GOVERNANCE_SAFE, false);
        _requireRole(timelock, adminRole, EMERGENCY_SAFE, false);

        _requireRole(timelock, proposerRole, GOVERNANCE_SAFE, true);
        _requireRole(timelock, executorRole, GOVERNANCE_SAFE, true);
        _requireRole(timelock, cancellerRole, GOVERNANCE_SAFE, true);

        _requireRole(timelock, proposerRole, deployer, false);
        _requireRole(timelock, executorRole, deployer, false);
        _requireRole(timelock, cancellerRole, deployer, false);
        _requireRole(timelock, proposerRole, EMERGENCY_SAFE, false);
        _requireRole(timelock, executorRole, EMERGENCY_SAFE, false);
        _requireRole(timelock, cancellerRole, EMERGENCY_SAFE, false);
        _requireRole(timelock, executorRole, address(0), false);
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
            if (delay < TESTNET_GOVERNANCE_DELAY) {
                revert GovernanceDelayTooShort(delay, TESTNET_GOVERNANCE_DELAY);
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

    function _validateSafe(string memory field, address safe, address[3] memory expectedOwners) private view {
        if (safe.code.length == 0) revert InvalidContract(field, safe);

        address singleton;
        try IDeploymentSafe(safe).masterCopy() returns (address value) {
            singleton = value;
        } catch {
            revert InvalidSafeSingleton(field, address(0), SAFE_L2_SINGLETON_V1_4_1);
        }
        if (singleton != SAFE_L2_SINGLETON_V1_4_1) {
            revert InvalidSafeSingleton(field, singleton, SAFE_L2_SINGLETON_V1_4_1);
        }

        string memory version = IDeploymentSafe(safe).VERSION();
        if (keccak256(bytes(version)) != keccak256(bytes(SAFE_VERSION))) {
            revert InvalidSafeVersion(field, version, SAFE_VERSION);
        }

        uint256 threshold = IDeploymentSafe(safe).getThreshold();
        if (threshold != SAFE_THRESHOLD) revert InvalidSafeThreshold(field, threshold, SAFE_THRESHOLD);

        address[] memory owners = IDeploymentSafe(safe).getOwners();
        if (owners.length != SAFE_OWNER_COUNT) revert InvalidSafeOwners(field);
        for (uint256 i = 0; i < expectedOwners.length; ++i) {
            bool found;
            for (uint256 j = 0; j < owners.length; ++j) {
                if (owners[j] == expectedOwners[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) revert InvalidSafeOwners(field);
        }

        (address[] memory modules, address next) = IDeploymentSafe(safe).getModulesPaginated(SAFE_MODULE_SENTINEL, 1);
        if (modules.length != 0 || next != SAFE_MODULE_SENTINEL) revert InvalidSafeModules(field);

        address guard = _readSafeAddressSlot(safe, SAFE_GUARD_SLOT);
        if (guard != address(0)) revert InvalidSafeGuard(field, guard);
        address moduleGuard = _readSafeAddressSlot(safe, SAFE_MODULE_GUARD_SLOT);
        if (moduleGuard != address(0)) revert InvalidSafeModuleGuard(field, moduleGuard);
        address fallbackHandler = _readSafeAddressSlot(safe, SAFE_FALLBACK_HANDLER_SLOT);
        if (fallbackHandler != SAFE_FALLBACK_HANDLER_V1_4_1) {
            revert InvalidSafeFallbackHandler(field, fallbackHandler, SAFE_FALLBACK_HANDLER_V1_4_1);
        }
    }

    function _readSafeAddressSlot(address safe, bytes32 slot) private view returns (address account) {
        bytes memory value = IDeploymentSafe(safe).getStorageAt(uint256(slot), 1);
        if (value.length != 32) return address(0);
        bytes32 word;
        assembly ("memory-safe") {
            word := mload(add(value, 0x20))
        }
        account = address(uint160(uint256(word)));
    }

    function _requireRole(IDeploymentGovernanceTimelock timelock, bytes32 role, address account, bool expected)
        private
        view
    {
        if (timelock.hasRole(role, account) != expected) revert InvalidTimelockRole(role, account, expected);
    }
}
