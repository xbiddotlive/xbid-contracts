// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {IFeeVault} from "../interfaces/IFeeVault.sol";
import {IMarketRegistry} from "../interfaces/IMarketRegistry.sol";

/// @notice Non-upgradeable, versioned trading-fee ledger for XBID markets.
/// @dev Fee credit stays live independently of claim pause. MarketVault sends
///      Settlement Token before calling creditFee in the same transaction.
contract FeeVault is IFeeVault, ReentrancyGuard {
    error ZeroAddress();
    error InvalidContract(address account);
    error InvalidSettlementDecimals(uint8 decimals);
    error InvalidFeeVaultVersion();
    error InvalidFeeSplit(uint16 protocolBps, uint16 creatorBps, uint16 referrerBps);
    error Unauthorized();
    error UnregisteredMarket(address market);
    error InvalidFeeAmount();
    error InvalidBeneficiary(address beneficiary);
    error InsolventFeeBalance(uint256 actualBalance, uint256 requiredLiability);
    error NothingToClaim(address account);
    error ClaimsArePaused();
    error InvalidClaimPauseTransition(bool currentPaused, bool requestedPaused);
    error UnexpectedBalanceDelta(address token, address account, uint256 expected, uint256 actual);

    event TradingFeeAccrued(
        bytes32 indexed contestId,
        address indexed market,
        address indexed creator,
        address referrer,
        uint256 totalFeeUnits,
        uint256 protocolUnits,
        uint256 creatorUnits,
        uint256 referrerUnits,
        uint32 feeSplitVersion
    );
    event ProtocolFeesClaimed(address indexed protocolTreasury, uint256 amountUnits);
    event AccountFeesClaimed(address indexed account, address indexed caller, uint256 amountUnits);
    event FeeSplitUpdated(
        uint32 indexed feeSplitVersion,
        uint16 oldProtocolBps,
        uint16 oldCreatorBps,
        uint16 oldReferrerBps,
        uint16 newProtocolBps,
        uint16 newCreatorBps,
        uint16 newReferrerBps,
        uint256 effectiveAt
    );
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event EmergencyRoleUpdated(address indexed oldEmergencyRole, address indexed newEmergencyRole);
    event ClaimPauseChanged(
        bool indexed paused, address indexed actor, bytes32 indexed reasonHash, uint256 effectiveAt
    );

    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable settlementToken;
    address public immutable marketRegistry;
    address public immutable governanceTimelock;
    uint32 public immutable feeVaultVersion;

    address public protocolTreasury;
    address public emergencyRole;

    uint16 public protocolBps;
    uint16 public creatorBps;
    uint16 public referrerBps;
    uint32 public feeSplitVersion;
    bool public claimPaused;

    uint256 public protocolClaimable;
    uint256 public totalAccountClaimable;
    uint256 public totalLiabilityUnits;
    mapping(address account => uint256 amountUnits) public claimable;

    constructor(
        uint32 feeVaultVersion_,
        address settlementToken_,
        address marketRegistry_,
        address governanceTimelock_,
        address emergencyRole_,
        address protocolTreasury_,
        uint16 protocolBps_,
        uint16 creatorBps_,
        uint16 referrerBps_
    ) {
        if (feeVaultVersion_ == 0) revert InvalidFeeVaultVersion();
        if (
            settlementToken_ == address(0) || marketRegistry_ == address(0) || governanceTimelock_ == address(0)
                || emergencyRole_ == address(0) || protocolTreasury_ == address(0)
        ) revert ZeroAddress();
        if (protocolTreasury_ == address(this)) revert InvalidBeneficiary(protocolTreasury_);
        _requireContract(settlementToken_);
        _requireContract(marketRegistry_);
        uint8 settlementDecimals = _decimals(settlementToken_);
        if (settlementDecimals != 6) revert InvalidSettlementDecimals(settlementDecimals);
        _validateFeeSplit(protocolBps_, creatorBps_, referrerBps_);

        feeVaultVersion = feeVaultVersion_;
        settlementToken = settlementToken_;
        marketRegistry = marketRegistry_;
        governanceTimelock = governanceTimelock_;
        emergencyRole = emergencyRole_;
        protocolTreasury = protocolTreasury_;
        protocolBps = protocolBps_;
        creatorBps = creatorBps_;
        referrerBps = referrerBps_;
        feeSplitVersion = 1;
    }

    modifier onlyGovernance() {
        if (msg.sender != governanceTimelock) revert Unauthorized();
        _;
    }

    modifier whenClaimsActive() {
        if (claimPaused) revert ClaimsArePaused();
        _;
    }

    function creditFee(bytes32 contestId, address creator, address referrer, uint256 feeUnits)
        external
        returns (uint256 protocolUnits, uint256 creatorUnits, uint256 referrerUnits, uint32 splitVersion)
    {
        if (!IMarketRegistry(marketRegistry).isRegisteredMarket(msg.sender)) {
            revert UnregisteredMarket(msg.sender);
        }
        if (feeUnits == 0) revert InvalidFeeAmount();
        _validateBeneficiary(creator);
        if (referrer != address(0)) _validateBeneficiary(referrer);

        creatorUnits = FixedPointMathLib.fullMulDiv(feeUnits, creatorBps, BPS_DENOMINATOR);
        if (referrer != address(0)) {
            referrerUnits = FixedPointMathLib.fullMulDiv(feeUnits, referrerBps, BPS_DENOMINATOR);
        }
        protocolUnits = feeUnits - creatorUnits - referrerUnits;

        protocolClaimable += protocolUnits;
        claimable[creator] += creatorUnits;
        if (referrerUnits != 0) claimable[referrer] += referrerUnits;
        totalAccountClaimable += creatorUnits + referrerUnits;
        totalLiabilityUnits += feeUnits;
        _assertSolvent();

        splitVersion = feeSplitVersion;
        emit TradingFeeAccrued(
            contestId, msg.sender, creator, referrer, feeUnits, protocolUnits, creatorUnits, referrerUnits, splitVersion
        );
    }

    function claimProtocolFees() external nonReentrant whenClaimsActive returns (uint256 amountUnits) {
        if (msg.sender != protocolTreasury) revert Unauthorized();
        amountUnits = protocolClaimable;
        if (amountUnits == 0) revert NothingToClaim(msg.sender);

        protocolClaimable = 0;
        totalLiabilityUnits -= amountUnits;
        _pushExact(protocolTreasury, amountUnits);
        _assertSolvent();
        emit ProtocolFeesClaimed(protocolTreasury, amountUnits);
    }

    function claimFees() external nonReentrant whenClaimsActive returns (uint256 amountUnits) {
        return _claimAccount(msg.sender, msg.sender);
    }

    /// @notice Permissionlessly sends an account's full claimable balance to that account.
    function claimFeesFor(address account) external nonReentrant whenClaimsActive returns (uint256 amountUnits) {
        return _claimAccount(account, msg.sender);
    }

    function setFeeSplit(uint16 protocolBps_, uint16 creatorBps_, uint16 referrerBps_) external onlyGovernance {
        _validateFeeSplit(protocolBps_, creatorBps_, referrerBps_);
        uint16 oldProtocolBps = protocolBps;
        uint16 oldCreatorBps = creatorBps;
        uint16 oldReferrerBps = referrerBps;

        protocolBps = protocolBps_;
        creatorBps = creatorBps_;
        referrerBps = referrerBps_;
        feeSplitVersion += 1;
        emit FeeSplitUpdated(
            feeSplitVersion,
            oldProtocolBps,
            oldCreatorBps,
            oldReferrerBps,
            protocolBps_,
            creatorBps_,
            referrerBps_,
            block.timestamp
        );
    }

    function setProtocolTreasury(address newProtocolTreasury) external onlyGovernance {
        if (newProtocolTreasury == address(0)) revert ZeroAddress();
        if (newProtocolTreasury == address(this)) revert InvalidBeneficiary(newProtocolTreasury);
        address oldProtocolTreasury = protocolTreasury;
        protocolTreasury = newProtocolTreasury;
        emit ProtocolTreasuryUpdated(oldProtocolTreasury, newProtocolTreasury);
    }

    function setEmergencyRole(address newEmergencyRole) external onlyGovernance {
        if (newEmergencyRole == address(0)) revert ZeroAddress();
        if (newEmergencyRole == address(this)) revert InvalidBeneficiary(newEmergencyRole);
        address oldEmergencyRole = emergencyRole;
        emergencyRole = newEmergencyRole;
        emit EmergencyRoleUpdated(oldEmergencyRole, newEmergencyRole);
    }

    function pauseClaims(bytes32 reasonHash) external {
        if (msg.sender != emergencyRole && msg.sender != governanceTimelock) revert Unauthorized();
        if (claimPaused) revert InvalidClaimPauseTransition(true, true);
        claimPaused = true;
        emit ClaimPauseChanged(true, msg.sender, reasonHash, block.timestamp);
    }

    function resumeClaims(bytes32 reasonHash) external onlyGovernance {
        if (!claimPaused) revert InvalidClaimPauseTransition(false, false);
        claimPaused = false;
        emit ClaimPauseChanged(false, msg.sender, reasonHash, block.timestamp);
    }

    function surplusUnits() external view returns (uint256) {
        uint256 balance = SafeTransferLib.balanceOf(settlementToken, address(this));
        return balance > totalLiabilityUnits ? balance - totalLiabilityUnits : 0;
    }

    function _claimAccount(address account, address caller) private returns (uint256 amountUnits) {
        _validateBeneficiary(account);
        amountUnits = claimable[account];
        if (amountUnits == 0) revert NothingToClaim(account);

        claimable[account] = 0;
        totalAccountClaimable -= amountUnits;
        totalLiabilityUnits -= amountUnits;
        _pushExact(account, amountUnits);
        _assertSolvent();
        emit AccountFeesClaimed(account, caller, amountUnits);
    }

    function _pushExact(address recipient, uint256 amount) private {
        uint256 senderBefore = SafeTransferLib.balanceOf(settlementToken, address(this));
        uint256 recipientBefore = SafeTransferLib.balanceOf(settlementToken, recipient);
        SafeTransferLib.safeTransfer(settlementToken, recipient, amount);
        uint256 senderAfter = SafeTransferLib.balanceOf(settlementToken, address(this));
        uint256 recipientAfter = SafeTransferLib.balanceOf(settlementToken, recipient);
        uint256 senderDelta = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        uint256 recipientDelta = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        if (senderDelta != amount) {
            revert UnexpectedBalanceDelta(settlementToken, address(this), amount, senderDelta);
        }
        if (recipientDelta != amount) {
            revert UnexpectedBalanceDelta(settlementToken, recipient, amount, recipientDelta);
        }
    }

    function _assertSolvent() private view {
        uint256 actualBalance = SafeTransferLib.balanceOf(settlementToken, address(this));
        if (actualBalance < totalLiabilityUnits) {
            revert InsolventFeeBalance(actualBalance, totalLiabilityUnits);
        }
    }

    function _validateFeeSplit(uint16 protocolBps_, uint16 creatorBps_, uint16 referrerBps_) private pure {
        if (uint256(protocolBps_) + creatorBps_ + referrerBps_ != BPS_DENOMINATOR) {
            revert InvalidFeeSplit(protocolBps_, creatorBps_, referrerBps_);
        }
    }

    function _validateBeneficiary(address beneficiary) private view {
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidBeneficiary(beneficiary);
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
