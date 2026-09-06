// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "solady/test/utils/forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {XBIDFactory} from "../src/core/XBIDFactory.sol";
import {MarketRegistry} from "../src/core/MarketRegistry.sol";
import {MarketVaultV2} from "../src/core/MarketVaultV2.sol";
import {MarketVaultV3} from "../src/core/MarketVaultV3.sol";
import {SideToken} from "../src/core/SideToken.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";

interface IV3SimulationToken {
    function mint(address account, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Fork-only governance and trading rehearsal. Never broadcasts transactions.
contract SimulateRobinhoodMarketV3 is Script {
    function run() external {
        require(block.chainid == 46630, "testnet only");
        string memory json = vm.readFile("deployments/robinhood-testnet/market-v3.json");
        address implementation = abi.decode(vm.parseJson(json, ".marketVaultImplementation"), (address));
        bytes32 expectedHash = abi.decode(vm.parseJson(json, ".marketVaultImplementationCodeHash"), (bytes32));
        require(implementation.codehash == expectedHash, "implementation mismatch");
        address timelockAddress = abi.decode(vm.parseJson(json, ".governanceTimelock"), (address));
        address deployer = abi.decode(vm.parseJson(json, ".deployer"), (address));
        RobinhoodDeploymentConfig.validateLockedPreflight(
            deployer,
            timelockAddress,
            RobinhoodDeploymentConfig.EMERGENCY_SAFE,
            RobinhoodDeploymentConfig.TEAM_TREASURY,
            RobinhoodDeploymentConfig.PROTOCOL_TREASURY
        );
        XBIDFactory factory = XBIDFactory(0x8f9208FD358c62FB4052e4C2FBbCA3152A17E4b6);
        MarketRegistry registry = MarketRegistry(factory.marketRegistry());
        require(factory.defaultMarketVersion() == 2 && registry.versionCount() == 2, "state changed");
        bytes32 oldV1 = keccak256(abi.encode(registry.getVersion(1)));
        bytes32 oldV2 = keccak256(abi.encode(registry.getVersion(2)));
        address[] memory targets = new address[](2);
        targets[0] = address(factory);
        targets[1] = address(factory);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.decode(vm.parseJson(json, ".registerVersionCalldata"), (bytes));
        payloads[1] = abi.decode(vm.parseJson(json, ".setDefaultVersionCalldata"), (bytes));
        bytes32 salt = keccak256(abi.encode("XBID-MARKET-V3", block.chainid, implementation, expectedHash));
        TimelockController timelock = TimelockController(payable(timelockAddress));
        bytes32 operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        vm.prank(RobinhoodDeploymentConfig.GOVERNANCE_SAFE);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, timelock.getMinDelay());
        require(!timelock.isOperationReady(operationId), "delay not enforced");
        vm.warp(block.timestamp + timelock.getMinDelay());
        vm.prank(RobinhoodDeploymentConfig.GOVERNANCE_SAFE);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        require(timelock.isOperationDone(operationId), "operation incomplete");
        require(factory.defaultMarketVersion() == 3 && registry.versionCount() == 3, "activation failed");
        require(keccak256(abi.encode(registry.getVersion(1))) == oldV1, "V1 changed");
        require(keccak256(abi.encode(registry.getVersion(2))) == oldV2, "V2 changed");
        require(registry.getVersion(3).marketImplementation == implementation, "wrong V3");
        _smoke(factory, registry);
    }

    function _smoke(XBIDFactory factory, MarketRegistry registry) private {
        address trader = address(0xa11ce);
        IV3SimulationToken usdc = IV3SimulationToken(RobinhoodDeploymentConfig.SETTLEMENT_TOKEN);
        vm.startPrank(trader);
        usdc.mint(trader, 21_000_005e6);
        usdc.approve(address(factory), 5e6);
        (bytes32 id, address market, address tokenA, address tokenB) = factory.createContest(
            XBIDFactory.CreateContestParams({
                userSalt: keccak256("v3-fork-only-smoke"),
                metadataHash: keccak256("v3-fork-only-smoke-metadata"),
                metadataURI: "ipfs://v3-fork-only-smoke",
                sideAName: "V3 Fork A",
                sideASymbol: "V3A",
                sideBName: "V3 Fork B",
                sideBSymbol: "V3B"
            })
        );
        MarketVaultV3 vault = MarketVaultV3(market);
        require(vault.marketVersion() == 3 && vault.bWad() == 150_000e18, "wrong economics");
        require(registry.getContest(block.chainid, id).versionId == 3, "contest version mismatch");
        usdc.approve(market, 21_000_000e6);
        uint256 amount = vault.previewBuy(MarketVaultV2.Side.A, 21_000_000e6).tokenOutputWei;
        uint256 bought = vault.buy(MarketVaultV2.Side.A, 21_000_000e6, amount, block.timestamp, address(0));
        require(bought == amount && bought > 20_000_000e18, "large buy mismatch");
        SideToken(tokenA).approve(market, bought);
        uint256 flipped = vault.flip(MarketVaultV2.Side.A, bought, 1, block.timestamp);
        SideToken(tokenB).approve(market, flipped);
        require(vault.sellAll(MarketVaultV2.Side.B, flipped, 1, block.timestamp) > 0, "exit failed");
        require(vault.qAWei() == 0 && vault.qBWei() == 0, "supply remains");
        require(vault.reserveUnits() >= vault.requiredReserveUnits(), "insolvent");
        vm.stopPrank();
    }
}
