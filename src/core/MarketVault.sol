// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "solady/src/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {IFeeVault} from "../interfaces/IFeeVault.sol";
import {IRiskController} from "../interfaces/IRiskController.sol";
import {ISideToken} from "../interfaces/ISideToken.sol";
import {XbidCrownMath} from "../libraries/XbidCrownMath.sol";
import {XbidLmsrMath} from "../libraries/XbidLmsrMath.sol";
import {XbidTradeMath} from "../libraries/XbidTradeMath.sol";

/// @notice Isolated Curve Reserve and trading entry point for one XBID Contest.
/// @dev Market Version 1 implementation for EIP-1167 clones. The implementation
///      is non-upgradeable and every configuration address is initialized once.
contract MarketVault is Initializable, ReentrancyGuard {
    enum Side {
        A,
        B
    }

    enum CrownSide {
        None,
        A,
        B
    }

    enum CrownStatus {
        Inactive,
        ActiveUnassigned,
        ActiveIdle,
        ChallengeOpen,
        TakeoverHold,
        DefendedWaitReset
    }

    error ZeroAddress();
    error InvalidContestId();
    error InvalidMarketVersion(uint32 version);
    error InvalidContract(address account);
    error InvalidSettlementDecimals(uint8 decimals);
    error InvalidSideToken(address token, uint8 expectedSide);
    error DeadlineExpired(uint256 deadline, uint256 currentTimestamp);
    error ContestPaused(IRiskController.RiskMode mode);
    error MinimumOutputNotMet(uint256 actual, uint256 minimum);
    error BalanceChanged(uint256 expected, uint256 actual);
    error UnexpectedBalanceDelta(address token, address account, uint256 expected, uint256 actual);
    error SupplyInvariantViolation(address token, uint256 actualSupply, uint256 expectedSupply);
    error ReserveBalanceViolation(uint256 actualBalance, uint256 recordedReserve);
    error InvalidReferrer(address referrer);
    error ReferrerAlreadyBound(address existingReferrer, address suppliedReferrer);
    error InvalidFeeAllocation(uint256 feeUnits, uint256 allocatedUnits);
    error CrownChallengeNotReady(uint256 readyAt, uint256 currentTimestamp);
    error CrownChallengeThresholdLost();

    event MarketInitialized(
        bytes32 indexed contestId,
        uint32 indexed marketVersion,
        address indexed creator,
        address settlementToken,
        address sideAToken,
        address sideBToken,
        address riskController,
        address feeVault
    );
    event ReferrerBound(address indexed trader, address indexed referrer);
    event TradingFeeProcessed(
        bytes32 indexed contestId,
        address indexed trader,
        uint256 feeUnits,
        uint256 protocolUnits,
        uint256 creatorUnits,
        uint256 referrerUnits,
        uint32 feeSplitVersion
    );
    event Bought(
        bytes32 indexed contestId,
        address indexed trader,
        Side indexed side,
        uint256 grossInputUnits,
        uint256 feeUnits,
        uint256 tokenOutputWei,
        uint256 qAAfterWei,
        uint256 qBAfterWei,
        uint256 reserveAfterUnits
    );
    event Sold(
        bytes32 indexed contestId,
        address indexed trader,
        Side indexed side,
        uint256 tokenInputWei,
        uint256 grossOutputUnits,
        uint256 feeUnits,
        uint256 netOutputUnits,
        uint256 qAAfterWei,
        uint256 qBAfterWei,
        uint256 reserveAfterUnits,
        bool sellAll
    );
    event Flipped(
        bytes32 indexed contestId,
        address indexed trader,
        Side indexed sourceSide,
        uint256 sourceTokenInputWei,
        uint256 sourceGrossOutputUnits,
        uint256 feeUnits,
        uint256 destinationTokenOutputWei,
        uint256 qAAfterWei,
        uint256 qBAfterWei,
        uint256 reserveAfterUnits
    );
    event CrownActivated(bytes32 indexed contestId, uint256 qAWei, uint256 qBWei, uint256 reserveUnits);
    event CrownAssigned(bytes32 indexed contestId, CrownSide indexed crownSide, uint256 qAWei, uint256 qBWei);
    event CrownChallengeOpened(bytes32 indexed contestId, CrownSide indexed crownSide, Side indexed challengerSide);
    event CrownHoldStarted(
        bytes32 indexed contestId, Side indexed challengerSide, uint64 holdStartedAt, uint64 readyAt
    );
    event CrownHoldReset(bytes32 indexed contestId, Side indexed challengerSide, uint64 previousHoldStartedAt);
    event CrownDefended(
        bytes32 indexed contestId,
        CrownSide indexed crownSide,
        Side indexed challengerSide,
        bool resetRequirementSatisfied
    );
    event CrownResetRequirementSatisfied(bytes32 indexed contestId, Side indexed formerChallengerSide);
    event CrownTransferred(
        bytes32 indexed contestId, CrownSide indexed previousCrownSide, CrownSide indexed newCrownSide
    );

    uint256 public constant CROWN_ACTIVATION_RESERVE_UNITS = 70_000_000_000;
    uint64 public constant CROWN_HOLD_SECONDS = 60;

    bytes32 public contestId;
    uint32 public marketVersion;
    address public creator;
    address public settlementToken;
    address public sideAToken;
    address public sideBToken;
    address public riskController;
    address public feeVault;

    uint256 public qAWei;
    uint256 public qBWei;
    uint256 public reserveUnits;

    bool public crownActivated;
    CrownSide public crownSide;
    Side public challengerSide;
    bool public challengeOpen;
    uint64 public holdStartedAt;
    bool public needsResetBelow45;

    mapping(address trader => address referrer) public referrerOf;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        bytes32 contestId_,
        uint32 marketVersion_,
        address creator_,
        address settlementToken_,
        address sideAToken_,
        address sideBToken_,
        address riskController_,
        address feeVault_
    ) external initializer {
        if (contestId_ == bytes32(0)) revert InvalidContestId();
        if (marketVersion_ != 1) revert InvalidMarketVersion(marketVersion_);
        if (
            creator_ == address(0) || settlementToken_ == address(0) || sideAToken_ == address(0)
                || sideBToken_ == address(0) || riskController_ == address(0) || feeVault_ == address(0)
        ) revert ZeroAddress();
        if (sideAToken_ == sideBToken_ || feeVault_ == address(this)) revert InvalidContract(address(this));

        _requireContract(settlementToken_);
        _requireContract(sideAToken_);
        _requireContract(sideBToken_);
        _requireContract(riskController_);
        _requireContract(feeVault_);

        uint8 settlementDecimals = _decimals(settlementToken_);
        if (settlementDecimals != 6) revert InvalidSettlementDecimals(settlementDecimals);
        _validateSideToken(sideAToken_, contestId_, 0);
        _validateSideToken(sideBToken_, contestId_, 1);

        contestId = contestId_;
        marketVersion = marketVersion_;
        creator = creator_;
        settlementToken = settlementToken_;
        sideAToken = sideAToken_;
        sideBToken = sideBToken_;
        riskController = riskController_;
        feeVault = feeVault_;

        emit MarketInitialized(
            contestId_, marketVersion_, creator_, settlementToken_, sideAToken_, sideBToken_, riskController_, feeVault_
        );
    }

    function bWad() external pure returns (int256) {
        return XbidLmsrMath.bWad();
    }

    function requiredReserveUnits() public view returns (uint256) {
        return XbidTradeMath.requiredReserveUnits(qAWei, qBWei);
    }

    function crownStatus() public view returns (CrownStatus) {
        if (!crownActivated) return CrownStatus.Inactive;
        if (crownSide == CrownSide.None) return CrownStatus.ActiveUnassigned;
        if (needsResetBelow45) return CrownStatus.DefendedWaitReset;
        if (!challengeOpen) return CrownStatus.ActiveIdle;
        if (holdStartedAt != 0) return CrownStatus.TakeoverHold;
        return CrownStatus.ChallengeOpen;
    }

    function previewBuy(Side side, uint256 grossInputUnits) public view returns (XbidTradeMath.BuyResult memory) {
        _requireBuyAndFlipAllowed();
        return XbidTradeMath.quoteBuy(qAWei, qBWei, reserveUnits, side == Side.A, grossInputUnits);
    }

    function previewSell(Side side, uint256 tokenInputWei) public view returns (XbidTradeMath.SellResult memory) {
        _requireSellAllowed();
        return XbidTradeMath.quoteSell(qAWei, qBWei, reserveUnits, side == Side.A, tokenInputWei, false);
    }

    function previewSellAll(Side side, address account, uint256 expectedBalance)
        public
        view
        returns (XbidTradeMath.SellResult memory)
    {
        _requireSellAllowed();
        uint256 actualBalance = ISideToken(_sideToken(side)).balanceOf(account);
        if (actualBalance != expectedBalance) revert BalanceChanged(expectedBalance, actualBalance);
        return XbidTradeMath.quoteSell(qAWei, qBWei, reserveUnits, side == Side.A, expectedBalance, true);
    }

    function previewFlip(Side sourceSide, uint256 sourceTokenInputWei)
        public
        view
        returns (XbidTradeMath.FlipResult memory)
    {
        _requireBuyAndFlipAllowed();
        return XbidTradeMath.quoteFlip(qAWei, qBWei, reserveUnits, sourceSide == Side.A, sourceTokenInputWei);
    }

    function buy(Side side, uint256 grossInputUnits, uint256 minimumTokenOutputWei, uint256 deadline, address referrer)
        external
        nonReentrant
        returns (uint256 tokenOutputWei)
    {
        _checkDeadline(deadline);
        XbidTradeMath.BuyResult memory quote = previewBuy(side, grossInputUnits);
        if (quote.tokenOutputWei < minimumTokenOutputWei) {
            revert MinimumOutputNotMet(quote.tokenOutputWei, minimumTokenOutputWei);
        }
        address boundReferrer = _bindOrLoadReferrer(msg.sender, referrer);

        _pullExact(settlementToken, msg.sender, grossInputUnits);
        qAWei = quote.qAAfterWei;
        qBWei = quote.qBAfterWei;
        reserveUnits = quote.reserveAfterUnits;
        _processFee(msg.sender, boundReferrer, quote.feeUnits);
        _mintExact(_sideToken(side), msg.sender, quote.tokenOutputWei, side == Side.A ? qAWei : qBWei);
        _assertMarketInvariants();
        _syncCrownAfterTrade();

        emit Bought(
            contestId,
            msg.sender,
            side,
            grossInputUnits,
            quote.feeUnits,
            quote.tokenOutputWei,
            qAWei,
            qBWei,
            reserveUnits
        );
        return quote.tokenOutputWei;
    }

    function sell(Side side, uint256 tokenInputWei, uint256 minimumNetOutputUnits, uint256 deadline)
        external
        nonReentrant
        returns (uint256 netOutputUnits)
    {
        _checkDeadline(deadline);
        XbidTradeMath.SellResult memory quote = previewSell(side, tokenInputWei);
        return _executeSell(side, tokenInputWei, minimumNetOutputUnits, quote, false);
    }

    function sellAll(Side side, uint256 expectedBalance, uint256 minimumNetOutputUnits, uint256 deadline)
        external
        nonReentrant
        returns (uint256 netOutputUnits)
    {
        _checkDeadline(deadline);
        XbidTradeMath.SellResult memory quote = previewSellAll(side, msg.sender, expectedBalance);
        return _executeSell(side, expectedBalance, minimumNetOutputUnits, quote, true);
    }

    function flip(
        Side sourceSide,
        uint256 sourceTokenInputWei,
        uint256 minimumDestinationTokenOutputWei,
        uint256 deadline
    ) external nonReentrant returns (uint256 destinationTokenOutputWei) {
        _checkDeadline(deadline);
        XbidTradeMath.FlipResult memory quote = previewFlip(sourceSide, sourceTokenInputWei);
        if (quote.destinationTokenOutputWei < minimumDestinationTokenOutputWei) {
            revert MinimumOutputNotMet(quote.destinationTokenOutputWei, minimumDestinationTokenOutputWei);
        }

        address sourceToken = _sideToken(sourceSide);
        Side destinationSide = sourceSide == Side.A ? Side.B : Side.A;
        _pullAndBurnExact(sourceToken, msg.sender, sourceTokenInputWei);
        qAWei = quote.qAAfterWei;
        qBWei = quote.qBAfterWei;
        reserveUnits = quote.reserveAfterUnits;
        _processFee(msg.sender, referrerOf[msg.sender], quote.feeUnits);
        _mintExact(
            _sideToken(destinationSide),
            msg.sender,
            quote.destinationTokenOutputWei,
            destinationSide == Side.A ? qAWei : qBWei
        );
        _assertMarketInvariants();
        _syncCrownAfterTrade();

        emit Flipped(
            contestId,
            msg.sender,
            sourceSide,
            sourceTokenInputWei,
            quote.sourceGrossOutputUnits,
            quote.feeUnits,
            quote.destinationTokenOutputWei,
            qAWei,
            qBWei,
            reserveUnits
        );
        return quote.destinationTokenOutputWei;
    }

    /// @notice Permissionlessly completes an elapsed Crown hold without a trade.
    /// @dev Deliberately remains available during Risk-Off and Full Pause because
    ///      it moves no funds and only settles a state transition already earned.
    function finalizeCrownChallenge() external nonReentrant {
        if (!challengeOpen || holdStartedAt == 0) {
            revert CrownChallengeNotReady(0, block.timestamp);
        }
        (uint256 challengerQuantityWei, uint256 crownQuantityWei) = _challengeQuantities();
        if (!XbidCrownMath.challengerAtLeast52(challengerQuantityWei, crownQuantityWei)) {
            revert CrownChallengeThresholdLost();
        }
        uint256 readyAt = uint256(holdStartedAt) + CROWN_HOLD_SECONDS;
        if (block.timestamp < readyAt) revert CrownChallengeNotReady(readyAt, block.timestamp);
        _transferCrown();
    }

    function _executeSell(
        Side side,
        uint256 tokenInputWei,
        uint256 minimumNetOutputUnits,
        XbidTradeMath.SellResult memory quote,
        bool sellAll_
    ) private returns (uint256) {
        if (quote.netOutputUnits < minimumNetOutputUnits) {
            revert MinimumOutputNotMet(quote.netOutputUnits, minimumNetOutputUnits);
        }

        address token = _sideToken(side);
        _pullAndBurnExact(token, msg.sender, tokenInputWei);
        qAWei = quote.qAAfterWei;
        qBWei = quote.qBAfterWei;
        reserveUnits = quote.reserveAfterUnits;
        _processFee(msg.sender, referrerOf[msg.sender], quote.feeUnits);
        _pushExact(settlementToken, msg.sender, quote.netOutputUnits);
        _assertMarketInvariants();
        _syncCrownAfterTrade();

        emit Sold(
            contestId,
            msg.sender,
            side,
            tokenInputWei,
            quote.grossOutputUnits,
            quote.feeUnits,
            quote.netOutputUnits,
            qAWei,
            qBWei,
            reserveUnits,
            sellAll_
        );
        return quote.netOutputUnits;
    }

    function _syncCrownAfterTrade() internal {
        if (!crownActivated) {
            if (reserveUnits < CROWN_ACTIVATION_RESERVE_UNITS) return;
            crownActivated = true;
            emit CrownActivated(contestId, qAWei, qBWei, reserveUnits);
        }

        if (crownSide == CrownSide.None) {
            if (qAWei == qBWei) return;
            crownSide = qAWei > qBWei ? CrownSide.A : CrownSide.B;
            emit CrownAssigned(contestId, crownSide, qAWei, qBWei);
        }

        Side nonCrownSide = crownSide == CrownSide.A ? Side.B : Side.A;
        (uint256 nonCrownQuantityWei, uint256 currentCrownQuantityWei) = _quantities(nonCrownSide);

        if (needsResetBelow45) {
            if (!XbidCrownMath.challengerStrictlyBelow45(nonCrownQuantityWei, currentCrownQuantityWei)) return;
            needsResetBelow45 = false;
            emit CrownResetRequirementSatisfied(contestId, nonCrownSide);
        }

        if (!challengeOpen) {
            if (!XbidCrownMath.challengerAtLeast48(nonCrownQuantityWei, currentCrownQuantityWei)) return;
            challengeOpen = true;
            challengerSide = nonCrownSide;
            emit CrownChallengeOpened(contestId, crownSide, challengerSide);
        }

        (uint256 challengerQuantityWei, uint256 crownQuantityWei) = _challengeQuantities();
        if (XbidCrownMath.challengerAtLeast52(challengerQuantityWei, crownQuantityWei)) {
            if (holdStartedAt == 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                holdStartedAt = uint64(block.timestamp);
                emit CrownHoldStarted(contestId, challengerSide, holdStartedAt, holdStartedAt + CROWN_HOLD_SECONDS);
                return;
            }
            if (block.timestamp >= uint256(holdStartedAt) + CROWN_HOLD_SECONDS) _transferCrown();
            return;
        }

        if (holdStartedAt != 0) {
            uint64 previousHoldStartedAt = holdStartedAt;
            holdStartedAt = 0;
            emit CrownHoldReset(contestId, challengerSide, previousHoldStartedAt);
        }

        if (XbidCrownMath.crownAtLeast55(crownQuantityWei, challengerQuantityWei)) {
            bool resetSatisfied = XbidCrownMath.challengerStrictlyBelow45(challengerQuantityWei, crownQuantityWei);
            challengeOpen = false;
            needsResetBelow45 = !resetSatisfied;
            emit CrownDefended(contestId, crownSide, challengerSide, resetSatisfied);
        }
    }

    function _transferCrown() private {
        CrownSide previousCrownSide = crownSide;
        CrownSide newCrownSide = challengerSide == Side.A ? CrownSide.A : CrownSide.B;
        crownSide = newCrownSide;
        challengeOpen = false;
        holdStartedAt = 0;
        needsResetBelow45 = false;
        emit CrownTransferred(contestId, previousCrownSide, newCrownSide);
    }

    function _challengeQuantities() private view returns (uint256 challengerQuantityWei, uint256 crownQuantityWei) {
        return _quantities(challengerSide);
    }

    function _quantities(Side side_) private view returns (uint256 sideQuantityWei, uint256 otherQuantityWei) {
        return side_ == Side.A ? (qAWei, qBWei) : (qBWei, qAWei);
    }

    function _bindOrLoadReferrer(address trader, address suppliedReferrer) private returns (address boundReferrer) {
        boundReferrer = referrerOf[trader];
        if (boundReferrer != address(0)) {
            if (suppliedReferrer != address(0) && suppliedReferrer != boundReferrer) {
                revert ReferrerAlreadyBound(boundReferrer, suppliedReferrer);
            }
            return boundReferrer;
        }
        if (suppliedReferrer == address(0)) return address(0);
        if (suppliedReferrer == trader) revert InvalidReferrer(suppliedReferrer);
        referrerOf[trader] = suppliedReferrer;
        emit ReferrerBound(trader, suppliedReferrer);
        return suppliedReferrer;
    }

    function _processFee(address trader, address referrer, uint256 feeUnits) private {
        _pushExact(settlementToken, feeVault, feeUnits);
        (uint256 protocolUnits, uint256 creatorUnits, uint256 referrerUnits, uint32 feeSplitVersion) =
            IFeeVault(feeVault).creditFee(contestId, creator, referrer, feeUnits);
        uint256 allocatedUnits = protocolUnits + creatorUnits + referrerUnits;
        if (allocatedUnits != feeUnits) revert InvalidFeeAllocation(feeUnits, allocatedUnits);
        emit TradingFeeProcessed(
            contestId, trader, feeUnits, protocolUnits, creatorUnits, referrerUnits, feeSplitVersion
        );
    }

    function _pullExact(address token, address from, uint256 amount) private {
        uint256 balanceBefore = SafeTransferLib.balanceOf(token, address(this));
        SafeTransferLib.safeTransferFrom(token, from, address(this), amount);
        uint256 balanceAfter = SafeTransferLib.balanceOf(token, address(this));
        uint256 delta = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (delta != amount) revert UnexpectedBalanceDelta(token, address(this), amount, delta);
    }

    function _pushExact(address token, address recipient, uint256 amount) private {
        uint256 senderBefore = SafeTransferLib.balanceOf(token, address(this));
        uint256 recipientBefore = SafeTransferLib.balanceOf(token, recipient);
        SafeTransferLib.safeTransfer(token, recipient, amount);
        uint256 senderAfter = SafeTransferLib.balanceOf(token, address(this));
        uint256 recipientAfter = SafeTransferLib.balanceOf(token, recipient);
        uint256 senderDelta = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        uint256 recipientDelta = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        if (senderDelta != amount) revert UnexpectedBalanceDelta(token, address(this), amount, senderDelta);
        if (recipientDelta != amount) revert UnexpectedBalanceDelta(token, recipient, amount, recipientDelta);
    }

    function _pullAndBurnExact(address token, address from, uint256 amount) private {
        _pullExact(token, from, amount);
        uint256 balanceBefore = ISideToken(token).balanceOf(address(this));
        uint256 supplyBefore = ISideToken(token).totalSupply();
        ISideToken(token).burnHeld(amount);
        uint256 balanceAfter = ISideToken(token).balanceOf(address(this));
        uint256 supplyAfter = ISideToken(token).totalSupply();
        if (balanceBefore - balanceAfter != amount) {
            revert UnexpectedBalanceDelta(token, address(this), amount, balanceBefore - balanceAfter);
        }
        if (supplyBefore - supplyAfter != amount) {
            revert UnexpectedBalanceDelta(token, address(0), amount, supplyBefore - supplyAfter);
        }
    }

    function _mintExact(address token, address account, uint256 amount, uint256 expectedSupply) private {
        uint256 balanceBefore = ISideToken(token).balanceOf(account);
        ISideToken(token).mintTo(account, amount);
        uint256 balanceAfter = ISideToken(token).balanceOf(account);
        uint256 delta = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (delta != amount) revert UnexpectedBalanceDelta(token, account, amount, delta);
        uint256 actualSupply = ISideToken(token).totalSupply();
        if (actualSupply != expectedSupply) revert SupplyInvariantViolation(token, actualSupply, expectedSupply);
    }

    function _assertMarketInvariants() private view {
        XbidTradeMath.validateReserve(qAWei, qBWei, reserveUnits);
        uint256 actualReserveBalance = SafeTransferLib.balanceOf(settlementToken, address(this));
        if (actualReserveBalance < reserveUnits) {
            revert ReserveBalanceViolation(actualReserveBalance, reserveUnits);
        }
        uint256 supplyA = ISideToken(sideAToken).totalSupply();
        uint256 supplyB = ISideToken(sideBToken).totalSupply();
        if (supplyA != qAWei) revert SupplyInvariantViolation(sideAToken, supplyA, qAWei);
        if (supplyB != qBWei) revert SupplyInvariantViolation(sideBToken, supplyB, qBWei);
    }

    function _requireBuyAndFlipAllowed() private view {
        IRiskController.RiskMode mode = IRiskController(riskController).effectiveMode(address(this));
        if (mode != IRiskController.RiskMode.Normal) revert ContestPaused(mode);
    }

    function _requireSellAllowed() private view {
        IRiskController.RiskMode mode = IRiskController(riskController).effectiveMode(address(this));
        if (mode == IRiskController.RiskMode.FullPause) revert ContestPaused(mode);
    }

    function _checkDeadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
    }

    function _sideToken(Side side) private view returns (address) {
        return side == Side.A ? sideAToken : sideBToken;
    }

    function _validateSideToken(address token, bytes32 expectedContestId, uint8 expectedSide) private view {
        if (
            ISideToken(token).contestId() != expectedContestId || ISideToken(token).side() != expectedSide
                || ISideToken(token).marketVault() != address(this) || ISideToken(token).decimals() != 18
                || ISideToken(token).totalSupply() != 0
        ) revert InvalidSideToken(token, expectedSide);
    }

    function _requireContract(address account) private view {
        if (account.code.length == 0) revert InvalidContract(account);
    }

    function _decimals(address token) private view returns (uint8 result) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!success || data.length < 32) revert InvalidContract(token);
        result = abi.decode(data, (uint8));
    }
}
