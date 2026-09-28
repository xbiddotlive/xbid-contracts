// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {MarketVaultV4} from "../../src/core/MarketVaultV4.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {MockRiskController} from "../mocks/MockRiskController.sol";

contract MarketVaultV4CrownHarness is MarketVaultV4 {
    function setMarketState(uint256 qAWei_, uint256 qBWei_, uint256 reserveUnits_) external {
        qAWei = qAWei_;
        qBWei = qBWei_;
        reserveUnits = reserveUnits_;
    }

    function setCrownState(
        bool activated_,
        CrownSide crownSide_,
        Side challengerSide_,
        bool challengeOpen_,
        uint64 holdStartedAt_,
        bool needsResetBelow45_
    ) external {
        crownActivated = activated_;
        crownSide = crownSide_;
        challengerSide = challengerSide_;
        challengeOpen = challengeOpen_;
        holdStartedAt = holdStartedAt_;
        needsResetBelow45 = needsResetBelow45_;
    }

    function syncCrownAfterTrade() external {
        _syncCrownAfterTrade();
    }

    function setRiskControllerForTest(address riskController_) external {
        riskController = riskController_;
    }
}

contract MarketVaultV4CrownTest is Test {
    int256 private constant THRESHOLD_48 = -12_006_406_151_030_463_873_566;
    int256 private constant THRESHOLD_52 = 12_006_406_151_030_463_873_567;
    int256 private constant THRESHOLD_55 = 30_100_604_319_322_674_190_718;
    int256 private constant STRICTLY_BELOW_45 = -30_100_604_319_322_674_190_718;
    uint256 private constant BASE_QUANTITY = 100_000e18;

    MarketVaultV4CrownHarness private market;

    function setUp() public {
        market = new MarketVaultV4CrownHarness();
    }

    function testActivationBoundaryPreservesTieUntilFirstUnequalTrade() external {
        market.setMarketState(0, 0, market.CROWN_ACTIVATION_RESERVE_UNITS() - 1);
        market.syncCrownAfterTrade();
        assertFalse(market.crownActivated());
        assertEq(uint256(market.crownStatus()), uint256(MarketVaultV4.CrownStatus.Inactive));

        market.setMarketState(0, 0, market.CROWN_ACTIVATION_RESERVE_UNITS());
        market.syncCrownAfterTrade();
        assertTrue(market.crownActivated());
        assertEq(uint256(market.crownSide()), uint256(MarketVaultV4.CrownSide.None));
        assertEq(uint256(market.crownStatus()), uint256(MarketVaultV4.CrownStatus.ActiveUnassigned));

        market.setMarketState(1, 0, market.CROWN_ACTIVATION_RESERVE_UNITS());
        market.syncCrownAfterTrade();
        assertEq(uint256(market.crownSide()), uint256(MarketVaultV4.CrownSide.A));
        assertTrue(market.challengeOpen());
        assertEq(uint256(market.challengerSide()), uint256(MarketVaultV4.Side.B));
    }

    function testChallengeOpensAtExact48Boundary() external {
        _setIdleCrownA();
        _setChallengerBDifference(THRESHOLD_48 - 1);
        market.syncCrownAfterTrade();
        assertFalse(market.challengeOpen());

        _setChallengerBDifference(THRESHOLD_48);
        market.syncCrownAfterTrade();
        assertTrue(market.challengeOpen());
        assertEq(uint256(market.challengerSide()), uint256(MarketVaultV4.Side.B));
        assertEq(uint256(market.crownStatus()), uint256(MarketVaultV4.CrownStatus.ChallengeOpen));
    }

    function testHoldStartsAtExact52AndResetsOneWeiBelow() external {
        _setOpenChallengeB();
        vm.warp(100);
        _setChallengerBDifference(THRESHOLD_52 - 1);
        market.syncCrownAfterTrade();
        assertEq(market.holdStartedAt(), 0);

        _setChallengerBDifference(THRESHOLD_52);
        market.syncCrownAfterTrade();
        assertEq(market.holdStartedAt(), 100);
        assertEq(uint256(market.crownStatus()), uint256(MarketVaultV4.CrownStatus.TakeoverHold));

        _setChallengerBDifference(THRESHOLD_52 - 1);
        market.syncCrownAfterTrade();
        assertEq(market.holdStartedAt(), 0);
        assertTrue(market.challengeOpen());
        assertEq(uint256(market.crownStatus()), uint256(MarketVaultV4.CrownStatus.ChallengeOpen));
    }

    function testFinalizeAt59SecondsRevertsAndAt60Transfers() external {
        _setOpenChallengeB();
        _setChallengerBDifference(THRESHOLD_52);
        vm.warp(100);
        market.syncCrownAfterTrade();

        vm.warp(159);
        vm.expectRevert(abi.encodeWithSelector(MarketVaultV4.CrownChallengeNotReady.selector, 160, 159));
        market.finalizeCrownChallenge();

        vm.warp(160);
        MockRiskController riskController = new MockRiskController();
        riskController.setMode(address(market), IRiskController.RiskMode.FullPause);
        market.setRiskControllerForTest(address(riskController));
        market.finalizeCrownChallenge();
        assertEq(uint256(market.crownSide()), uint256(MarketVaultV4.CrownSide.B));
        assertFalse(market.challengeOpen());
        assertEq(market.holdStartedAt(), 0);
        assertEq(uint256(market.crownStatus()), uint256(MarketVaultV4.CrownStatus.ActiveIdle));
    }

    function testSuccessfulTradeSyncAlsoTransfersAt60Seconds() external {
        _setOpenChallengeB();
        _setChallengerBDifference(THRESHOLD_52);
        vm.warp(100);
        market.syncCrownAfterTrade();

        vm.warp(160);
        market.syncCrownAfterTrade();
        assertEq(uint256(market.crownSide()), uint256(MarketVaultV4.CrownSide.B));
        assertFalse(market.challengeOpen());
    }

    function testHoldResetRequiresANewFull60Seconds() external {
        _setOpenChallengeB();
        _setChallengerBDifference(THRESHOLD_52);
        vm.warp(100);
        market.syncCrownAfterTrade();

        vm.warp(120);
        _setChallengerBDifference(THRESHOLD_52 - 1);
        market.syncCrownAfterTrade();
        assertEq(market.holdStartedAt(), 0);

        vm.warp(130);
        _setChallengerBDifference(THRESHOLD_52);
        market.syncCrownAfterTrade();
        assertEq(market.holdStartedAt(), 130);

        vm.warp(189);
        vm.expectRevert(abi.encodeWithSelector(MarketVaultV4.CrownChallengeNotReady.selector, 190, 189));
        market.finalizeCrownChallenge();
        vm.warp(190);
        market.finalizeCrownChallenge();
        assertEq(uint256(market.crownSide()), uint256(MarketVaultV4.CrownSide.B));
    }

    function testFinalizeRejectsAChallengeThatLost52Threshold() external {
        _setOpenChallengeB();
        market.setCrownState(true, MarketVaultV4.CrownSide.A, MarketVaultV4.Side.B, true, 100, false);
        _setChallengerBDifference(THRESHOLD_52 - 1);
        vm.warp(200);

        vm.expectRevert(MarketVaultV4.CrownChallengeThresholdLost.selector);
        market.finalizeCrownChallenge();
        assertEq(uint256(market.crownSide()), uint256(MarketVaultV4.CrownSide.A));
    }

    function testDefenseUses55BoundaryAndStrictBelow45Reset() external {
        _setOpenChallengeB();
        _setCrownADifference(THRESHOLD_55 - 1);
        market.syncCrownAfterTrade();
        assertTrue(market.challengeOpen());

        _setCrownADifference(THRESHOLD_55);
        market.syncCrownAfterTrade();
        assertFalse(market.challengeOpen());
        assertFalse(market.needsResetBelow45());
        assertEq(uint256(market.crownStatus()), uint256(MarketVaultV4.CrownStatus.ActiveIdle));

        market.setCrownState(true, MarketVaultV4.CrownSide.A, MarketVaultV4.Side.B, false, 0, true);
        _setChallengerBDifference(STRICTLY_BELOW_45 + 1);
        market.syncCrownAfterTrade();
        assertTrue(market.needsResetBelow45());

        _setChallengerBDifference(STRICTLY_BELOW_45);
        market.syncCrownAfterTrade();
        assertFalse(market.needsResetBelow45());
        assertFalse(market.challengeOpen());

        _setChallengerBDifference(THRESHOLD_48);
        market.syncCrownAfterTrade();
        assertTrue(market.challengeOpen());
    }

    function testActivationAndCrownRemainAfterReserveFalls() external {
        _setIdleCrownA();
        market.setMarketState(BASE_QUANTITY, 0, 0);
        market.syncCrownAfterTrade();
        assertTrue(market.crownActivated());
        assertEq(uint256(market.crownSide()), uint256(MarketVaultV4.CrownSide.A));
    }

    function _setIdleCrownA() private {
        market.setCrownState(true, MarketVaultV4.CrownSide.A, MarketVaultV4.Side.B, false, 0, false);
    }

    function _setOpenChallengeB() private {
        market.setCrownState(true, MarketVaultV4.CrownSide.A, MarketVaultV4.Side.B, true, 0, false);
    }

    function _setChallengerBDifference(int256 challengerMinusCrown) private {
        uint256 qB = uint256(int256(BASE_QUANTITY) + challengerMinusCrown);
        market.setMarketState(BASE_QUANTITY, qB, 0);
    }

    function _setCrownADifference(int256 crownMinusChallenger) private {
        uint256 qB = uint256(int256(BASE_QUANTITY) - crownMinusChallenger);
        market.setMarketState(BASE_QUANTITY, qB, 0);
    }
}
