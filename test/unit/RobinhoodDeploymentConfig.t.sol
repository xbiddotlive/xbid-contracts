// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {RobinhoodDeploymentConfig} from "../../script/RobinhoodDeploymentConfig.sol";

contract MockDeploymentSettlementToken {
    function symbol() external pure returns (string memory) {
        return "USDC";
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract MockGovernanceTimelock {
    uint256 private immutable delay;

    constructor(uint256 delay_) {
        delay = delay_;
    }

    function getMinDelay() external view returns (uint256) {
        return delay;
    }
}

contract RobinhoodDeploymentConfigHarness {
    function validate(
        uint256 expectedChainId,
        address settlementToken,
        bytes32 expectedSettlementRuntimeHash,
        address deployer,
        address governanceTimelock,
        address emergencyRole,
        address teamTreasury,
        address protocolTreasury
    ) external view {
        RobinhoodDeploymentConfig.validatePreflight(
            expectedChainId,
            settlementToken,
            expectedSettlementRuntimeHash,
            deployer,
            governanceTimelock,
            emergencyRole,
            teamTreasury,
            protocolTreasury
        );
    }

    function lockedValues() external pure returns (uint256 chainId, address settlementToken, bytes32 runtimeHash) {
        return (
            RobinhoodDeploymentConfig.CHAIN_ID,
            RobinhoodDeploymentConfig.SETTLEMENT_TOKEN,
            RobinhoodDeploymentConfig.SETTLEMENT_TOKEN_RUNTIME_HASH
        );
    }
}

contract RobinhoodDeploymentConfigTest is Test {
    address private constant DEPLOYER = address(0xd001);
    address private constant EMERGENCY = address(0xe911);
    address private constant TEAM = address(0x7ea0);
    address private constant PROTOCOL = address(0x7007);

    RobinhoodDeploymentConfigHarness private harness;
    MockDeploymentSettlementToken private token;
    MockGovernanceTimelock private governance;

    function setUp() public {
        harness = new RobinhoodDeploymentConfigHarness();
        token = new MockDeploymentSettlementToken();
        governance = new MockGovernanceTimelock(48 hours);
    }

    function testLockedRobinhoodValuesCannotDrift() external {
        (uint256 chainId, address settlementToken, bytes32 runtimeHash) = harness.lockedValues();
        assertEq(chainId, 46_630);
        assertEq(settlementToken, 0xAc80194dc1aE8eF52df73e7e1864fB3C62290fe0);
        assertEq(runtimeHash, 0xf45e11ddae86e83321f1f290f0e6e99f50dceb81d19b7edbf2bf1b1fbb0c9b5c);
    }

    function testValidPreflightRequiresExactChainTokenAndContractGovernance() external view {
        harness.validate(
            block.chainid,
            address(token),
            address(token).codehash,
            DEPLOYER,
            address(governance),
            EMERGENCY,
            TEAM,
            PROTOCOL
        );
    }

    function testRejectsWrongChainBeforeDeployment() external {
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodDeploymentConfig.WrongChainId.selector, block.chainid, block.chainid + 1)
        );
        harness.validate(
            block.chainid + 1,
            address(token),
            address(token).codehash,
            DEPLOYER,
            address(governance),
            EMERGENCY,
            TEAM,
            PROTOCOL
        );
    }

    function testRejectsSettlementRuntimeHashDrift() external {
        bytes32 wrongHash = bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodDeploymentConfig.InvalidSettlementCodeHash.selector, address(token).codehash, wrongHash
            )
        );
        harness.validate(
            block.chainid, address(token), wrongHash, DEPLOYER, address(governance), EMERGENCY, TEAM, PROTOCOL
        );
    }

    function testRejectsEoaGovernanceAndRoleCollision() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodDeploymentConfig.InvalidContract.selector, "governanceTimelock", address(0x1234)
            )
        );
        harness.validate(
            block.chainid, address(token), address(token).codehash, DEPLOYER, address(0x1234), EMERGENCY, TEAM, PROTOCOL
        );

        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodDeploymentConfig.GovernanceEmergencyCollision.selector, address(governance))
        );
        harness.validate(
            block.chainid,
            address(token),
            address(token).codehash,
            DEPLOYER,
            address(governance),
            address(governance),
            TEAM,
            PROTOCOL
        );
    }

    function testRejectsUnreadableOrShortGovernanceDelay() external {
        MockDeploymentSettlementToken notATimelock = new MockDeploymentSettlementToken();
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodDeploymentConfig.GovernanceDelayUnreadable.selector, address(notATimelock))
        );
        harness.validate(
            block.chainid,
            address(token),
            address(token).codehash,
            DEPLOYER,
            address(notATimelock),
            EMERGENCY,
            TEAM,
            PROTOCOL
        );

        MockGovernanceTimelock shortDelay = new MockGovernanceTimelock(47 hours);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodDeploymentConfig.GovernanceDelayTooShort.selector, 47 hours, 48 hours)
        );
        harness.validate(
            block.chainid,
            address(token),
            address(token).codehash,
            DEPLOYER,
            address(shortDelay),
            EMERGENCY,
            TEAM,
            PROTOCOL
        );
    }
}
