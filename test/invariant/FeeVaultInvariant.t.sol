// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InvariantTest} from "solady/test/utils/InvariantTest.sol";
import {FeeVault} from "../../src/core/FeeVault.sol";
import {MockMarketRegistry} from "../mocks/MockMarketRegistry.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

contract FeeVaultHandler {
    bytes32 private constant CONTEST_ID = keccak256("xbid-fee-vault-invariant");
    address private constant CREATOR_A = address(0xA11CE);
    address private constant CREATOR_B = address(0xB0B);
    address private constant CREATOR_C = address(0xCA201);

    FeeVault public immutable feeVault;
    MockSettlementToken public immutable usdc;
    uint256 public creditFailures;

    constructor(MockSettlementToken usdc_, MockMarketRegistry registry_) {
        usdc = usdc_;
        feeVault = new FeeVault(
            1, address(usdc_), address(registry_), address(this), address(this), address(this), 7_000, 2_000, 1_000
        );
    }

    function credit(uint256 feeSeed, uint8 creatorSeed, uint8 referrerSeed, bool hasReferrer) external {
        uint256 feeUnits = 1 + feeSeed % 1_000_000_000_000;
        address creator = _account(creatorSeed);
        address referrer = hasReferrer ? _account(referrerSeed) : address(0);
        usdc.mint(address(feeVault), feeUnits);
        try feeVault.creditFee(CONTEST_ID, creator, referrer, feeUnits) {}
        catch {
            creditFailures += 1;
        }
    }

    function claimAccount(uint8 accountSeed) external {
        try feeVault.claimFeesFor(_account(accountSeed)) {} catch {}
    }

    function claimProtocol() external {
        try feeVault.claimProtocolFees() {} catch {}
    }

    function setSplit(uint16 protocolSeed, uint16 creatorSeed) external {
        uint16 protocol = uint16(uint256(protocolSeed) % 10_001);
        uint16 remaining = uint16(10_000 - protocol);
        uint16 creator = uint16(uint256(creatorSeed) % (uint256(remaining) + 1));
        uint16 referrer = remaining - creator;
        feeVault.setFeeSplit(protocol, creator, referrer);
    }

    function pauseClaims() external {
        if (!feeVault.claimPaused()) feeVault.pauseClaims(keccak256("invariant-pause"));
    }

    function resumeClaims() external {
        if (feeVault.claimPaused()) feeVault.resumeClaims(keccak256("invariant-resume"));
    }

    function account(uint8 seed) external pure returns (address) {
        return _account(seed);
    }

    function _account(uint8 seed) private pure returns (address) {
        uint8 index = seed % 3;
        if (index == 0) return CREATOR_A;
        if (index == 1) return CREATOR_B;
        return CREATOR_C;
    }
}

contract FeeVaultInvariantTest is InvariantTest {
    MockSettlementToken private usdc;
    FeeVault private feeVault;
    FeeVaultHandler private handler;

    function setUp() public {
        usdc = new MockSettlementToken();
        MockMarketRegistry registry = new MockMarketRegistry();

        // The handler deploys FeeVault and therefore holds every operational
        // role needed to exercise governance, emergency, claim, and credit paths.
        handler = new FeeVaultHandler(usdc, registry);
        feeVault = handler.feeVault();
        registry.setRegistered(address(handler), true);
        _addTargetContract(address(handler));
    }

    function invariantFeeVaultRemainsSolvent() external view {
        require(usdc.balanceOf(address(feeVault)) >= feeVault.totalLiabilityUnits(), "fee vault insolvent");
    }

    function invariantLiabilitiesEqualAllClaimables() external view {
        uint256 accountLiability = feeVault.claimable(handler.account(0)) + feeVault.claimable(handler.account(1))
            + feeVault.claimable(handler.account(2));
        require(accountLiability == feeVault.totalAccountClaimable(), "account liability mismatch");
        require(
            feeVault.totalLiabilityUnits() == feeVault.protocolClaimable() + accountLiability,
            "total liability mismatch"
        );
    }

    function invariantSplitAlwaysSumsToDenominator() external view {
        require(
            uint256(feeVault.protocolBps()) + feeVault.creatorBps() + feeVault.referrerBps()
                == feeVault.BPS_DENOMINATOR(),
            "invalid fee split"
        );
        require(feeVault.feeSplitVersion() >= 1, "invalid split version");
    }

    function invariantCreditNeverDependsOnClaimPause() external view {
        require(handler.creditFailures() == 0, "fee credit failed");
    }
}
