// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {MarketVaultV3} from "../../src/core/MarketVaultV3.sol";
import {MarketVaultV2} from "../../src/core/MarketVaultV2.sol";
import {SideToken} from "../../src/core/SideToken.sol";
import {FeeVault} from "../../src/core/FeeVault.sol";
import {RiskControllerV2} from "../../src/core/RiskControllerV2.sol";
import {IProbeUsdc} from "./ArcUsdcCompatibilityProbe.sol";

/// @notice eth_call-only harness with actual Arc USDC, V3 market, side tokens and fee vault.
/// @dev Minimal registry stub; this is NOT a deployment script or Safe/governance/Factory validation.
contract ArcMarketCompatibilityProbe {
    error ProbeFailure(uint256 phase, bytes reason);
    address private registeredMarket;
    FeeVault private fees;
    MarketVaultV3 private market;
    SideToken private tokenA;
    SideToken private tokenB;

    function isRegisteredMarket(address candidate) external view returns (bool) {
        return candidate == registeredMarket;
    }

    function probe() external returns (uint256 balanceBefore, uint256 balanceAfter, uint256 feeTotal) {
        require(block.chainid == 5042, "wrong chain");
        IProbeUsdc usdc = IProbeUsdc(0x3600000000000000000000000000000000000000);
        balanceBefore = usdc.balanceOf(address(this));
        address referrer = address(0xbee5042);
        uint256 referrerBefore = usdc.balanceOf(referrer);
        try this.setup(usdc) {} catch (bytes memory reason) { revert ProbeFailure(1, reason); }
        try this.trade(usdc, referrer) {} catch (bytes memory reason) { revert ProbeFailure(2, reason); }
        require(tokenA.totalSupply() == 0 && tokenB.totalSupply() == 0, "exit supply");
        require(usdc.balanceOf(address(market)) == market.reserveUnits(), "reserve accounting");
        feeTotal = fees.totalLiabilityUnits();
        try fees.claimProtocolFees() {} catch (bytes memory reason) { revert ProbeFailure(3, reason); }
        try fees.claimFees() {} catch (bytes memory reason) { revert ProbeFailure(4, reason); }
        try fees.claimFeesFor(referrer) {} catch (bytes memory reason) { revert ProbeFailure(5, reason); }
        require(fees.totalLiabilityUnits() == 0 && usdc.balanceOf(address(fees)) == 0, "fee exit");
        balanceAfter = usdc.balanceOf(address(this));
        require(balanceAfter + usdc.balanceOf(referrer) - referrerBefore + market.reserveUnits() == balanceBefore, "conservation");
    }

    function setup(IProbeUsdc usdc) external {
        require(msg.sender == address(this), "probe self only");
        RiskControllerV2 risk = new RiskControllerV2(address(this), address(0xe911));
        fees = new FeeVault(1, address(usdc), address(this), address(this), address(0xe911), address(this), 5000, 4000, 1000);
        market = MarketVaultV3(LibClone.clone(address(new MarketVaultV3())));
        registeredMarket = address(market);
        address tokenImplementation = address(new SideToken());
        tokenA = SideToken(LibClone.clone(tokenImplementation));
        tokenB = SideToken(LibClone.clone(tokenImplementation));
        bytes32 contestId = keccak256("eth-call-only-arc-probe");
        tokenA.initialize(contestId, 0, address(market), "Probe A", "A");
        tokenB.initialize(contestId, 1, address(market), "Probe B", "B");
        market.initialize(contestId, 3, address(this), address(usdc), address(tokenA), address(tokenB), address(risk), address(fees));
    }

    function trade(IProbeUsdc usdc, address referrer) external {
        require(msg.sender == address(this), "probe self only");
        require(usdc.approve(address(market), 100e6), "approve");
        uint256 bought = market.buy(MarketVaultV2.Side.A, 100e6, market.previewBuy(MarketVaultV2.Side.A, 100e6).tokenOutputWei, block.timestamp, referrer);
        require(fees.protocolClaimable() == 500000 && fees.claimable(address(this)) == 400000 && fees.claimable(referrer) == 100000, "fee split");
        tokenA.approve(address(market), bought);
        uint256 flipped = market.flip(MarketVaultV2.Side.A, bought, market.previewFlip(MarketVaultV2.Side.A, bought).destinationTokenOutputWei, block.timestamp);
        tokenB.approve(address(market), flipped);
        market.sellAll(MarketVaultV2.Side.B, flipped, market.previewSell(MarketVaultV2.Side.B, flipped).netOutputUnits, block.timestamp);
    }
}
