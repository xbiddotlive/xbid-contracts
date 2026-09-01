// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FeeVault} from "../../src/core/FeeVault.sol";
import {MockFeeSplitBatcher} from "../mocks/MockFeeSplitBatcher.sol";
import {MockMarketRegistry} from "../mocks/MockMarketRegistry.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

contract FeeVaultTest is Test {
    bytes32 private constant CONTEST_ID = keccak256("fee-vault-contest");
    address private constant GOVERNANCE = address(0x600d);
    address private constant EMERGENCY = address(0xe911);
    address private constant PROTOCOL_TREASURY = address(0x7007);
    address private constant MARKET = address(0xa11ce);
    address private constant UNREGISTERED_MARKET = address(0xbad);
    address private constant CREATOR = address(0xc0ffee);
    address private constant REFERRER = address(0xb0b);
    address private constant RELAYER = address(0x1234);

    MockSettlementToken private usdc;
    MockMarketRegistry private registry;
    FeeVault private feeVault;

    function setUp() public {
        usdc = new MockSettlementToken();
        registry = new MockMarketRegistry();
        feeVault = _deployFeeVault(GOVERNANCE);
        registry.setRegistered(MARKET, true);
    }

    function testConstructorLocksVersionAndInitialConfiguration() external {
        assertEq(feeVault.feeVaultVersion(), 1);
        assertEq(feeVault.feeSplitVersion(), 1);
        assertEq(feeVault.settlementToken(), address(usdc));
        assertEq(feeVault.marketRegistry(), address(registry));
        assertEq(feeVault.governanceTimelock(), GOVERNANCE);
        assertEq(feeVault.emergencyRole(), EMERGENCY);
        assertEq(feeVault.protocolTreasury(), PROTOCOL_TREASURY);
        assertEq(feeVault.protocolBps(), 7_000);
        assertEq(feeVault.creatorBps(), 2_000);
        assertEq(feeVault.referrerBps(), 1_000);
    }

    function testConstructorRejectsInvalidVersionContractsAndSplit() external {
        vm.expectRevert(FeeVault.InvalidFeeVaultVersion.selector);
        new FeeVault(0, address(usdc), address(registry), GOVERNANCE, EMERGENCY, PROTOCOL_TREASURY, 7_000, 2_000, 1_000);

        vm.expectRevert(abi.encodeWithSelector(FeeVault.InvalidContract.selector, MARKET));
        new FeeVault(1, MARKET, address(registry), GOVERNANCE, EMERGENCY, PROTOCOL_TREASURY, 7_000, 2_000, 1_000);

        vm.expectRevert(abi.encodeWithSelector(FeeVault.InvalidFeeSplit.selector, 8_000, 2_000, 1_000));
        new FeeVault(1, address(usdc), address(registry), GOVERNANCE, EMERGENCY, PROTOCOL_TREASURY, 8_000, 2_000, 1_000);
    }

    function testCreditUsesInitialSplitAndAssignsDustToProtocol() external {
        (uint256 protocolUnits, uint256 creatorUnits, uint256 referrerUnits, uint32 splitVersion) =
            _credit(101, CREATOR, REFERRER);

        assertEq(protocolUnits, 71);
        assertEq(creatorUnits, 20);
        assertEq(referrerUnits, 10);
        assertEq(splitVersion, 1);
        assertEq(feeVault.protocolClaimable(), 71);
        assertEq(feeVault.claimable(CREATOR), 20);
        assertEq(feeVault.claimable(REFERRER), 10);
        assertEq(feeVault.totalAccountClaimable(), 30);
        assertEq(feeVault.totalLiabilityUnits(), 101);
        assertEq(usdc.balanceOf(address(feeVault)), 101);
    }

    function testMissingReferrerShareGoesToProtocol() external {
        (uint256 protocolUnits, uint256 creatorUnits, uint256 referrerUnits,) = _credit(101, CREATOR, address(0));
        assertEq(protocolUnits, 81);
        assertEq(creatorUnits, 20);
        assertEq(referrerUnits, 0);
        assertEq(feeVault.protocolClaimable(), 81);
        assertEq(feeVault.totalLiabilityUnits(), 101);
    }

    function testRejectsUnregisteredOrUnderfundedCredit() external {
        usdc.mint(address(feeVault), 100);
        vm.expectRevert(abi.encodeWithSelector(FeeVault.UnregisteredMarket.selector, UNREGISTERED_MARKET));
        vm.prank(UNREGISTERED_MARKET);
        feeVault.creditFee(CONTEST_ID, CREATOR, REFERRER, 100);

        vm.expectRevert(abi.encodeWithSelector(FeeVault.InsolventFeeBalance.selector, 100, 101));
        vm.prank(MARKET);
        feeVault.creditFee(CONTEST_ID, CREATOR, REFERRER, 101);
        assertEq(feeVault.totalLiabilityUnits(), 0);
    }

    function testRejectsInvalidCreditInputs() external {
        vm.startPrank(MARKET);
        vm.expectRevert(FeeVault.InvalidFeeAmount.selector);
        feeVault.creditFee(CONTEST_ID, CREATOR, REFERRER, 0);

        vm.expectRevert(abi.encodeWithSelector(FeeVault.InvalidBeneficiary.selector, address(0)));
        feeVault.creditFee(CONTEST_ID, address(0), REFERRER, 1);

        vm.expectRevert(abi.encodeWithSelector(FeeVault.InvalidBeneficiary.selector, address(feeVault)));
        feeVault.creditFee(CONTEST_ID, CREATOR, address(feeVault), 1);
        vm.stopPrank();
    }

    function testFeeSplitUpdateDoesNotRepriceHistoricalClaimables() external {
        _credit(1_000, CREATOR, REFERRER);
        vm.prank(GOVERNANCE);
        feeVault.setFeeSplit(8_000, 1_000, 1_000);
        assertEq(feeVault.feeSplitVersion(), 2);

        _credit(1_000, CREATOR, REFERRER);
        assertEq(feeVault.protocolClaimable(), 1_500);
        assertEq(feeVault.claimable(CREATOR), 300);
        assertEq(feeVault.claimable(REFERRER), 200);
        assertEq(feeVault.totalLiabilityUnits(), 2_000);

        vm.expectRevert(FeeVault.Unauthorized.selector);
        feeVault.setFeeSplit(7_000, 2_000, 1_000);
        vm.expectRevert(abi.encodeWithSelector(FeeVault.InvalidFeeSplit.selector, 8_000, 2_000, 1_000));
        vm.prank(GOVERNANCE);
        feeVault.setFeeSplit(8_000, 2_000, 1_000);
    }

    function testAccountClaimCanBeTriggeredByRelayerButOnlyPaysAccount() external {
        _credit(100_000_000, CREATOR, REFERRER);
        uint256 creatorBalanceBefore = usdc.balanceOf(CREATOR);

        vm.prank(RELAYER);
        uint256 amount = feeVault.claimFeesFor(CREATOR);

        assertEq(amount, 20_000_000);
        assertEq(usdc.balanceOf(CREATOR), creatorBalanceBefore + amount);
        assertEq(usdc.balanceOf(RELAYER), 0);
        assertEq(feeVault.claimable(CREATOR), 0);
        assertEq(feeVault.totalAccountClaimable(), 10_000_000);
        assertEq(feeVault.totalLiabilityUnits(), 80_000_000);
    }

    function testProtocolClaimRequiresCurrentTreasuryAndSupportsTinyAmount() external {
        _credit(1, CREATOR, address(0));
        vm.expectRevert(FeeVault.Unauthorized.selector);
        feeVault.claimProtocolFees();

        vm.prank(PROTOCOL_TREASURY);
        uint256 amount = feeVault.claimProtocolFees();
        assertEq(amount, 1);
        assertEq(usdc.balanceOf(PROTOCOL_TREASURY), 1);
        assertEq(feeVault.protocolClaimable(), 0);
        assertEq(feeVault.totalLiabilityUnits(), 0);
    }

    function testClaimPauseNeverBlocksCreditAndEmergencyCannotResume() external {
        _credit(100, CREATOR, REFERRER);
        vm.prank(EMERGENCY);
        feeVault.pauseClaims(keccak256("token incident"));
        assertTrue(feeVault.claimPaused());

        vm.expectRevert(FeeVault.ClaimsArePaused.selector);
        vm.prank(CREATOR);
        feeVault.claimFees();
        vm.expectRevert(FeeVault.ClaimsArePaused.selector);
        vm.prank(PROTOCOL_TREASURY);
        feeVault.claimProtocolFees();

        _credit(100, CREATOR, REFERRER);
        assertEq(feeVault.totalLiabilityUnits(), 200);

        vm.expectRevert(FeeVault.Unauthorized.selector);
        vm.prank(EMERGENCY);
        feeVault.resumeClaims(keccak256("unauthorized recovery"));
        vm.prank(GOVERNANCE);
        feeVault.resumeClaims(keccak256("governance recovery"));
        assertFalse(feeVault.claimPaused());
    }

    function testGovernanceCanRotateTreasuryAndEmergencyRole() external {
        address newTreasury = address(0x8888);
        address newEmergency = address(0x9999);
        vm.startPrank(GOVERNANCE);
        feeVault.setProtocolTreasury(newTreasury);
        feeVault.setEmergencyRole(newEmergency);
        vm.stopPrank();
        assertEq(feeVault.protocolTreasury(), newTreasury);
        assertEq(feeVault.emergencyRole(), newEmergency);

        vm.expectRevert(FeeVault.Unauthorized.selector);
        vm.prank(EMERGENCY);
        feeVault.pauseClaims(bytes32(0));
        vm.prank(newEmergency);
        feeVault.pauseClaims(bytes32(0));
        assertTrue(feeVault.claimPaused());
    }

    function testFeeOnTransferClaimRevertsAndRestoresLedger() external {
        _credit(100_000_000, CREATOR, REFERRER);
        uint256 claimableBefore = feeVault.claimable(CREATOR);
        uint256 vaultBalanceBefore = usdc.balanceOf(address(feeVault));
        usdc.setTransferFeeBps(100);
        uint256 expectedReceived = claimableBefore - claimableBefore / 100;

        vm.expectRevert(
            abi.encodeWithSelector(
                FeeVault.UnexpectedBalanceDelta.selector, address(usdc), CREATOR, claimableBefore, expectedReceived
            )
        );
        vm.prank(CREATOR);
        feeVault.claimFees();

        assertEq(feeVault.claimable(CREATOR), claimableBefore);
        assertEq(feeVault.totalLiabilityUnits(), 100_000_000);
        assertEq(usdc.balanceOf(address(feeVault)), vaultBalanceBefore);
    }

    function testReentrantSettlementClaimRevertsAndRestoresLedger() external {
        _credit(100_000_000, CREATOR, REFERRER);
        uint256 claimableBefore = feeVault.claimable(CREATOR);
        usdc.setTransferCallback(address(feeVault), abi.encodeCall(FeeVault.claimFees, ()));

        // SafeTransferLib deliberately normalizes the token's bubbled inner
        // Reentrancy() revert to TransferFailed().
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        vm.prank(CREATOR);
        feeVault.claimFees();

        assertEq(feeVault.claimable(CREATOR), claimableBefore);
        assertEq(feeVault.totalLiabilityUnits(), 100_000_000);
        assertEq(usdc.balanceOf(address(feeVault)), 100_000_000);
    }

    function testDonationIsReportedAsSurplusAndCannotChangeLiability() external {
        _credit(100, CREATOR, REFERRER);
        usdc.mint(address(feeVault), 55);
        assertEq(feeVault.surplusUnits(), 55);
        assertEq(feeVault.totalLiabilityUnits(), 100);
    }

    function testCrossVersionBatchFailureRollsBackEarlierVersionUpdate() external {
        MockFeeSplitBatcher batcher = new MockFeeSplitBatcher();
        FeeVault first = _deployFeeVault(address(batcher));
        FeeVault second = _deployFeeVault(GOVERNANCE);

        vm.expectRevert(FeeVault.Unauthorized.selector);
        batcher.setTwo(first, second, 8_000, 1_000, 1_000);
        assertEq(first.feeSplitVersion(), 1);
        assertEq(first.protocolBps(), 7_000);
        assertEq(second.feeSplitVersion(), 1);
    }

    function testCrossVersionBatchUpdatesAllVersionsTogether() external {
        MockFeeSplitBatcher batcher = new MockFeeSplitBatcher();
        FeeVault first = _deployFeeVault(address(batcher));
        FeeVault second = _deployFeeVault(address(batcher));

        batcher.setTwo(first, second, 8_000, 1_000, 1_000);

        assertEq(first.feeSplitVersion(), 2);
        assertEq(first.protocolBps(), 8_000);
        assertEq(second.feeSplitVersion(), 2);
        assertEq(second.protocolBps(), 8_000);
    }

    function testFuzzFeeSplitAlwaysConservesFeeAndAssignsDustToProtocol(uint96 feeSeed, bool hasReferrer) external {
        uint256 feeUnits = 1 + uint256(feeSeed);
        address referrer = hasReferrer ? REFERRER : address(0);
        (uint256 protocolUnits, uint256 creatorUnits, uint256 referrerUnits,) = _credit(feeUnits, CREATOR, referrer);

        assertEq(protocolUnits + creatorUnits + referrerUnits, feeUnits);
        assertEq(creatorUnits, feeUnits * 2_000 / 10_000);
        assertEq(referrerUnits, hasReferrer ? feeUnits * 1_000 / 10_000 : 0);
        assertEq(feeVault.totalLiabilityUnits(), feeUnits);
        assertTrue(usdc.balanceOf(address(feeVault)) >= feeVault.totalLiabilityUnits());
    }

    function _credit(uint256 feeUnits, address creator, address referrer)
        private
        returns (uint256 protocolUnits, uint256 creatorUnits, uint256 referrerUnits, uint32 splitVersion)
    {
        usdc.mint(address(feeVault), feeUnits);
        vm.prank(MARKET);
        return feeVault.creditFee(CONTEST_ID, creator, referrer, feeUnits);
    }

    function _deployFeeVault(address governance) private returns (FeeVault) {
        return new FeeVault(
            1, address(usdc), address(registry), governance, EMERGENCY, PROTOCOL_TREASURY, 7_000, 2_000, 1_000
        );
    }
}
