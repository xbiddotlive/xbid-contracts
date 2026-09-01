// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "solady/test/utils/forge-std/Script.sol";
import {FeeVault} from "../src/core/FeeVault.sol";
import {MarketRegistry} from "../src/core/MarketRegistry.sol";
import {MarketVault} from "../src/core/MarketVault.sol";
import {RiskController} from "../src/core/RiskController.sol";
import {SideToken} from "../src/core/SideToken.sol";
import {XBIDFactory} from "../src/core/XBIDFactory.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {XbidTradeMath} from "../src/libraries/XbidTradeMath.sol";

interface ITestSettlementToken {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function mint(address account, uint256 amount) external returns (bool);
}

/// @notice Executes the standard user-path E2E round against the activated
/// Robinhood Testnet deployment. Governance and emergency cases are deliberately
/// excluded because they require their respective Safes and a separate round.
contract RunRobinhoodTestnetE2E is Script {
    uint256 private constant CHAIN_ID = 46_630;
    uint256 private constant BUY_GROSS_UNITS = 10_000_000_000;
    uint256 private constant MINIMUM_STARTING_USDC_UNITS = 20_000_000_000;
    uint256 private constant SLIPPAGE_BPS = 50;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    address private constant SETTLEMENT_TOKEN = 0xAc80194dc1aE8eF52df73e7e1864fB3C62290fe0;
    MarketRegistry private constant REGISTRY = MarketRegistry(0x0B68fD82965Fd853907CA4E2f7E6E6d478Aaef8b);
    RiskController private constant RISK_CONTROLLER = RiskController(0xfeebdbB42de39B95f8dE5FcdBDd11e986443c278);
    FeeVault private constant FEE_VAULT = FeeVault(0x82D9159cB488175cAcdcD145A7285d80563e69d0);
    XBIDFactory private constant FACTORY = XBIDFactory(0x8f9208FD358c62FB4052e4C2FBbCA3152A17E4b6);
    address private constant TEAM_TREASURY = 0x6AE1c7B6c583E50777002b70FE289321f23B8fF3;

    struct FeeTotals {
        uint256 total;
        uint256 protocol;
        uint256 creator;
        uint256 referrer;
    }

    struct RunResult {
        address account;
        address referrer;
        bytes32 contestId;
        bytes32 metadataHash;
        address market;
        address sideA;
        address sideB;
        uint256 usdcBefore;
        uint256 usdcAfter;
        uint256 teamTreasuryBefore;
        uint256 teamTreasuryAfter;
        uint256 creatorClaimed;
        uint256 referrerClaimed;
        FeeTotals fees;
    }

    error E2ECheckFailed(string check);

    function run() external {
        uint256 privateKey = vm.envUint("E2E_PRIVATE_KEY");
        address expectedAccount = vm.envAddress("E2E_TEST_ACCOUNT");
        string memory roundId = vm.envString("E2E_ROUND_ID");
        string memory resultPath = vm.envString("E2E_RESULT_PATH");
        bool fundIfNeeded = vm.envOr("E2E_FUND_IF_NEEDED", false);

        _require(block.chainid == CHAIN_ID, "chain id");
        _require(vm.addr(privateKey) == expectedAccount, "private key/account mismatch");
        _require(expectedAccount.balance > 0, "test account gas balance");
        _require(REGISTRY.registrar() == address(FACTORY), "registry registrar");
        _require(FACTORY.defaultMarketVersion() == 1, "default market version");
        _require(uint8(RISK_CONTROLLER.globalMode()) == 0, "global risk mode");

        ITestSettlementToken token = ITestSettlementToken(SETTLEMENT_TOKEN);
        uint256 balanceBeforeFunding = token.balanceOf(expectedAccount);
        if (balanceBeforeFunding < MINIMUM_STARTING_USDC_UNITS) {
            _require(fundIfNeeded, "starting Test USDC");
        }
        _require(FEE_VAULT.claimable(expectedAccount) == 0, "pre-existing creator claimable");

        RunResult memory result;
        result.account = expectedAccount;
        result.referrer = _roundReferrer(roundId, expectedAccount);
        result.metadataHash = keccak256(abi.encode("XBID_TESTNET_E2E_METADATA", roundId, expectedAccount));
        bytes32 userSalt = keccak256(abi.encode("XBID_TESTNET_E2E_SALT", roundId, expectedAccount));
        result.contestId = FACTORY.computeContestId(expectedAccount, userSalt, result.metadataHash);
        (result.market, result.sideA, result.sideB) = FACTORY.predictContestAddresses(result.contestId, 1);

        IMarketRegistry.ContestRecord memory existing = REGISTRY.getContest(CHAIN_ID, result.contestId);
        _require(existing.marketVault == address(0), "round contest already exists");
        _require(FEE_VAULT.claimable(result.referrer) == 0, "pre-existing referrer claimable");

        result.usdcBefore = token.balanceOf(expectedAccount);
        result.teamTreasuryBefore = token.balanceOf(TEAM_TREASURY);
        uint256 protocolClaimableBefore = FEE_VAULT.protocolClaimable();
        uint256 referrerBalanceBefore = token.balanceOf(result.referrer);

        vm.startBroadcast(privateKey);
        if (balanceBeforeFunding < MINIMUM_STARTING_USDC_UNITS) {
            _require(
                token.mint(expectedAccount, MINIMUM_STARTING_USDC_UNITS - balanceBeforeFunding), "Test USDC funding"
            );
            result.usdcBefore = token.balanceOf(expectedAccount);
        }
        _require(token.approve(address(FACTORY), FACTORY.CONTEST_CREATION_FEE_UNITS()), "factory approval");
        _createContest(userSalt, result.metadataHash, roundId, result);
        _require(token.approve(result.market, BUY_GROSS_UNITS), "market settlement approval");
        result.fees = _exerciseMarket(result);

        result.creatorClaimed = FEE_VAULT.claimFees();
        result.referrerClaimed = FEE_VAULT.claimFeesFor(result.referrer);
        vm.stopBroadcast();

        result.usdcAfter = token.balanceOf(expectedAccount);
        result.teamTreasuryAfter = token.balanceOf(TEAM_TREASURY);
        _validatePostState(result, protocolClaimableBefore, referrerBalanceBefore);
        _writeResult(roundId, resultPath, result);
    }

    function _createContest(bytes32 userSalt, bytes32 metadataHash, string memory roundId, RunResult memory result)
        private
    {
        XBIDFactory.CreateContestParams memory params = XBIDFactory.CreateContestParams({
            userSalt: userSalt,
            metadataHash: metadataHash,
            metadataURI: string.concat("ipfs://xbid-testnet-e2e/", roundId),
            sideAName: "XBID E2E Alpha",
            sideASymbol: "E2EA",
            sideBName: "XBID E2E Beta",
            sideBSymbol: "E2EB"
        });
        (bytes32 contestId, address market, address sideA, address sideB) = FACTORY.createContest(params);
        _require(contestId == result.contestId, "contest id");
        _require(market == result.market, "deterministic market");
        _require(sideA == result.sideA, "deterministic side A");
        _require(sideB == result.sideB, "deterministic side B");
    }

    function _exerciseMarket(RunResult memory result) private returns (FeeTotals memory fees) {
        MarketVault market = MarketVault(result.market);
        SideToken sideA = SideToken(result.sideA);
        SideToken sideB = SideToken(result.sideB);
        uint256 deadline = block.timestamp + 30 minutes;

        _buyAndFlip(result, market, sideA, sideB, deadline, fees);
        _sellSideB(result, market, sideB, deadline, fees);
        _sellAllSideA(result, market, sideA, deadline, fees);
    }

    function _buyAndFlip(
        RunResult memory result,
        MarketVault market,
        SideToken sideA,
        SideToken sideB,
        uint256 deadline,
        FeeTotals memory fees
    ) private {
        XbidTradeMath.BuyResult memory buyQuote = market.previewBuy(MarketVault.Side.A, BUY_GROSS_UNITS);
        _addFee(fees, buyQuote.feeUnits);
        market.buy(
            MarketVault.Side.A, BUY_GROSS_UNITS, _minimumOutput(buyQuote.tokenOutputWei), deadline, result.referrer
        );

        uint256 sideABalance = sideA.balanceOf(result.account);
        _require(sideABalance == buyQuote.tokenOutputWei, "buy output");
        _require(sideA.approve(result.market, type(uint256).max), "side A approval");
        uint256 flipInput = sideABalance / 4;
        XbidTradeMath.FlipResult memory flipQuote = market.previewFlip(MarketVault.Side.A, flipInput);
        _addFee(fees, flipQuote.feeUnits);
        market.flip(MarketVault.Side.A, flipInput, _minimumOutput(flipQuote.destinationTokenOutputWei), deadline);

        _require(sideB.approve(result.market, type(uint256).max), "side B approval");
    }

    function _sellSideB(
        RunResult memory result,
        MarketVault market,
        SideToken sideB,
        uint256 deadline,
        FeeTotals memory fees
    ) private {
        uint256 sideBBalance = sideB.balanceOf(result.account);
        uint256 sellInput = sideBBalance / 2;
        XbidTradeMath.SellResult memory sellQuote = market.previewSell(MarketVault.Side.B, sellInput);
        _addFee(fees, sellQuote.feeUnits);
        market.sell(MarketVault.Side.B, sellInput, _minimumOutput(sellQuote.netOutputUnits), deadline);

        sideBBalance = sideB.balanceOf(result.account);
        XbidTradeMath.SellResult memory sellAllBQuote =
            market.previewSellAll(MarketVault.Side.B, result.account, sideBBalance);
        _addFee(fees, sellAllBQuote.feeUnits);
        market.sellAll(MarketVault.Side.B, sideBBalance, _minimumOutput(sellAllBQuote.netOutputUnits), deadline);
    }

    function _sellAllSideA(
        RunResult memory result,
        MarketVault market,
        SideToken sideA,
        uint256 deadline,
        FeeTotals memory fees
    ) private {
        uint256 sideABalance = sideA.balanceOf(result.account);
        XbidTradeMath.SellResult memory sellAllAQuote =
            market.previewSellAll(MarketVault.Side.A, result.account, sideABalance);
        _addFee(fees, sellAllAQuote.feeUnits);
        market.sellAll(MarketVault.Side.A, sideABalance, _minimumOutput(sellAllAQuote.netOutputUnits), deadline);
    }

    function _validatePostState(RunResult memory result, uint256 protocolBefore, uint256 referrerBalanceBefore)
        private
        view
    {
        ITestSettlementToken token = ITestSettlementToken(SETTLEMENT_TOKEN);
        MarketVault market = MarketVault(result.market);
        SideToken sideA = SideToken(result.sideA);
        SideToken sideB = SideToken(result.sideB);
        IMarketRegistry.ContestRecord memory record = REGISTRY.getContest(CHAIN_ID, result.contestId);

        _require(record.creator == result.account, "registered creator");
        _require(record.marketVault == result.market, "registered market");
        _require(record.sideAToken == result.sideA && record.sideBToken == result.sideB, "registered sides");
        _require(record.versionId == 1 && record.metadataHash == result.metadataHash, "registered version metadata");
        _require(REGISTRY.isRegisteredMarket(result.market), "registered market index");
        _require(market.creator() == result.account && market.marketVersion() == 1, "market binding");
        _require(sideA.marketVault() == result.market && sideB.marketVault() == result.market, "token binding");
        _require(sideA.balanceOf(result.account) == 0 && sideB.balanceOf(result.account) == 0, "sell all balances");
        _require(sideA.totalSupply() == market.qAWei() && sideB.totalSupply() == market.qBWei(), "supply quantities");
        _require(token.balanceOf(result.market) >= market.reserveUnits(), "market reserve solvency");
        _require(
            token.balanceOf(address(FACTORY)) == 0 && token.balanceOf(address(REGISTRY)) == 0, "zero retained fees"
        );
        _require(
            result.teamTreasuryAfter == result.teamTreasuryBefore + FACTORY.CONTEST_CREATION_FEE_UNITS(),
            "creation fee treasury"
        );
        _require(result.creatorClaimed == result.fees.creator, "creator fee claim");
        _require(result.referrerClaimed == result.fees.referrer, "referrer fee claim");
        _require(FEE_VAULT.claimable(result.account) == 0, "creator claim cleared");
        _require(FEE_VAULT.claimable(result.referrer) == 0, "referrer claim cleared");
        _require(FEE_VAULT.protocolClaimable() == protocolBefore + result.fees.protocol, "protocol fee accrual");
        _require(
            token.balanceOf(result.referrer) == referrerBalanceBefore + result.fees.referrer, "referrer fee destination"
        );
        _require(token.balanceOf(address(FEE_VAULT)) >= FEE_VAULT.totalLiabilityUnits(), "fee vault solvency");
    }

    function _addFee(FeeTotals memory fees, uint256 feeUnits) private pure {
        uint256 creatorUnits = feeUnits * 2_000 / BPS_DENOMINATOR;
        uint256 referrerUnits = feeUnits * 1_000 / BPS_DENOMINATOR;
        fees.total += feeUnits;
        fees.creator += creatorUnits;
        fees.referrer += referrerUnits;
        fees.protocol += feeUnits - creatorUnits - referrerUnits;
    }

    function _minimumOutput(uint256 quotedOutput) private pure returns (uint256) {
        return quotedOutput * (BPS_DENOMINATOR - SLIPPAGE_BPS) / BPS_DENOMINATOR;
    }

    function _roundReferrer(string memory roundId, address account) private pure returns (address referrer) {
        referrer = address(uint160(uint256(keccak256(abi.encode("XBID_TESTNET_E2E_REFERRER", roundId, account)))));
        if (referrer == address(0) || referrer == account || referrer == address(FEE_VAULT)) {
            referrer = address(0xBEEF);
        }
    }

    function _writeResult(string memory roundId, string memory resultPath, RunResult memory result) private {
        string memory object = "e2e-result";
        vm.serializeString(object, "status", "SCRIPT_COMPLETED");
        vm.serializeString(object, "roundId", roundId);
        vm.serializeUint(object, "chainId", CHAIN_ID);
        vm.serializeUint(object, "observedBlock", block.number);
        vm.serializeUint(object, "observedTimestamp", block.timestamp);
        vm.serializeAddress(object, "account", result.account);
        vm.serializeAddress(object, "referrer", result.referrer);
        vm.serializeBytes32(object, "contestId", result.contestId);
        vm.serializeBytes32(object, "metadataHash", result.metadataHash);
        vm.serializeAddress(object, "marketVault", result.market);
        vm.serializeAddress(object, "sideAToken", result.sideA);
        vm.serializeAddress(object, "sideBToken", result.sideB);
        vm.serializeUint(object, "testUsdcBeforeUnits", result.usdcBefore);
        vm.serializeUint(object, "testUsdcAfterUnits", result.usdcAfter);
        vm.serializeUint(object, "teamTreasuryBeforeUnits", result.teamTreasuryBefore);
        vm.serializeUint(object, "teamTreasuryAfterUnits", result.teamTreasuryAfter);
        vm.serializeUint(object, "totalTradingFeeUnits", result.fees.total);
        vm.serializeUint(object, "protocolFeeUnits", result.fees.protocol);
        vm.serializeUint(object, "creatorFeeUnits", result.fees.creator);
        vm.serializeUint(object, "referrerFeeUnits", result.fees.referrer);
        vm.serializeUint(object, "creatorClaimedUnits", result.creatorClaimed);
        string memory json = vm.serializeUint(object, "referrerClaimedUnits", result.referrerClaimed);
        vm.writeJson(json, resultPath);
    }

    function _require(bool condition, string memory check) private pure {
        if (!condition) revert E2ECheckFailed(check);
    }
}
