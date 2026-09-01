// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "solady/test/utils/forge-std/Test.sol";
import {MarketVault} from "../../src/core/MarketVault.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {MockRiskController} from "../mocks/MockRiskController.sol";

contract MarketVaultCrownHarness is MarketVault {
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

contract MarketVaultCrownTest is Test {
    int256 private constant THRESHOLD_48 = -21_611_531_071_854_834_972_420;
    int256 private constant THRESHOLD_52 = 21_611_531_071_854_834_972_421;
    int256 private constant THRESHOLD_55 = 54_181_087_774_780_813_543_293;
    int256 private constant STRICTLY_BELOW_45 = -54_181_087_774_780_813_543_293;
    uint256 private constant BASE_QUANTITY = 100_000e18;

    MarketVaultCrownHarness private market;

    function setUp() public {
        market = new MarketVaultCrownHarness();
    }

    function testActivationBoundaryPreservesTieUntilFirstUnequalTrade() external {
        market.setMarketState(0, 0, market.CROWN_ACTIVATION_RESERVE_UNITS() - 1);
        market.syncCrownAfterTrade();
        assertFalse(market.crownActivated());
        assertEq(uint256(market.crownStatus()), uint256(MarketVault.CrownStatus.Inactive));

        market.setMarketState(0, 0, market.CROWN_ACTIVATION_RESERVE_UNITS());
        market.syncCrownAfterTrade();
        assertTrue(market.crownActivated());
        assertEq(uint256(market.crownSide()), uint256(MarketVault.CrownSide.None));
        assertEq(uint256(market.crownStatus()), uint256(MarketVault.CrownStatus.ActiveUnassigned));

        market.setMarketState(1, 0, market.CROWN_ACTIVATION_RESERVE_UNITS());
        market.syncCrownAfterTrade();
        assertEq(uint256(market.crownSide()), uint256(MarketVault.CrownSide.A));
        assertTrue(market.challengeOpen());
        assertEq(uint256(market.challengerSide()), uint256(MarketVault.Side.B));
    }

    function testChallengeOpensAtExact48Boundary() external {
        _setIdleCrownA();
        _setChallengerBDifference(THRESHOLD_48 - 1);
        market.syncCrownAfterTrade();
        assertFalse(market.challengeOpen());

        _setChallengerBDifference(THRESHOLD_48);
        market.syncCrownAfterTrade();
        assertTrue(market.challengeOpen());
        assertEq(uint256(market.challengerSide()), uint256(MarketVault.Side.B));
        assertEq(uint256(market.crownStatus()), uint256(MarketVault.CrownStatus.ChallengeOpen));
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
        assertEq(uint256(market.crownStatus()), uint256(MarketVault.CrownStatus.TakeoverHold));

        _setChallengerBDifference(THRESHOLD_52 - 1);
        market.syncCrownAfterTrade();
        assertEq(market.holdStartedAt(), 0);
        assertTrue(market.challengeOpen());
        assertEq(uint256(market.crownStatus()), uint256(MarketVault.CrownStatus.ChallengeOpen));
    }

    function testFinalizeAt59SecondsRevertsAndAt60Transfers() external {
        _setOpenChallengeB();
        _setChallengerBDifference(THRESHOLD_52);
        vm.warp(100);
        market.syncCrownAfterTrade();

        vm.warp(159);
        vm.expectRevert(abi.encodeWithSelector(MarketVault.CrownChallengeNotReady.selector, 160, 159));
        market.finalizeCrownChallenge();

        vm.warp(160);
        MockRiskController riskController = new MockRiskController();
        riskController.setMode(address(market), IRiskController.RiskMode.FullPause);
        market.setRiskControllerForTest(address(riskController));
        market.finalizeCrownChallenge();
        assertEq(uint256(market.crownSide()), uint256(MarketVault.CrownSide.B));
        assertFalse(market.challengeOpen());
        assertEq(market.holdStartedAt(), 0);
        assertEq(uint256(market.crownStatus()), uint256(MarketVault.CrownStatus.ActiveIdle));
    }

    function testSuccessfulTradeSyncAlsoTransfersAt60Seconds() external {
        _setOpenChallengeB();
        _setChallengerBDifference(THRESHOLD_52);
        vm.warp(100);
        market.syncCrownAfterTrade();

        vm.warp(160);
        market.syncCrownAfterTrade();
        assertEq(uint256(market.crownSide()), uint256(MarketVault.CrownSide.B));
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
        vm.expectRevert(abi.encodeWithSelector(MarketVault.CrownChallengeNotReady.selector, 190, 189));
        market.finalizeCrownChallenge();
        vm.warp(190);
        market.finalizeCrownChallenge();
        assertEq(uint256(market.crownSide()), uint256(MarketVault.CrownSide.B));
    }

    function testFinalizeRejectsAChallengeThatLost52Threshold() external {
        _setOpenChallengeB();
        market.setCrownState(true, MarketVault.CrownSide.A, MarketVault.Side.B, true, 100, false);
        _setChallengerBDifference(THRESHOLD_52 - 1);
        vm.warp(200);

        vm.expectRevert(MarketVault.CrownChallengeThresholdLost.selector);
        market.finalizeCrownChallenge();
        assertEq(uint256(market.crownSide()), uint256(MarketVault.CrownSide.A));
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
        assertEq(uint256(market.crownStatus()), uint256(MarketVault.CrownStatus.ActiveIdle));

        market.setCrownState(true, MarketVault.CrownSide.A, MarketVault.Side.B, false, 0, true);
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
        assertEq(uint256(market.crownSide()), uint256(MarketVault.CrownSide.A));
    }

    function _setIdleCrownA() private {
        market.setCrownState(true, MarketVault.CrownSide.A, MarketVault.Side.B, false, 0, false);
    }

    function _setOpenChallengeB() private {
        market.setCrownState(true, MarketVault.CrownSide.A, MarketVault.Side.B, true, 0, false);
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
