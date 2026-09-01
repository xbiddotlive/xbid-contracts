// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "solady/test/utils/forge-std/Test.sol";
import {XBIDFactory} from "../../src/core/XBIDFactory.sol";
import {MockMarketRegistry} from "../mocks/MockMarketRegistry.sol";
import {MockSettlementToken} from "../mocks/MockSettlementToken.sol";

contract XBIDFactoryStorageLayoutTest is Test {
    bytes32 private constant FACTORY_STORAGE_LOCATION =
        0x2cdc82a277d9c9278933e3b9cae03f832da8b0dbfd0f5b103169073c57d12f00;
    bytes32 private constant INITIALIZABLE_STORAGE_LOCATION =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 private constant REENTRANCY_GUARD_STORAGE_LOCATION =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private constant TEAM = address(0x7ea0);
    address private constant NEW_TEAM = address(0x7ea1);

    XBIDFactory private factory;
    MockSettlementToken private token;
    MockMarketRegistry private registry;

    function setUp() public {
        token = new MockSettlementToken();
        registry = new MockMarketRegistry();
        XBIDFactory implementation = new XBIDFactory();
        factory = XBIDFactory(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(XBIDFactory.initialize, (address(this), address(token), address(registry), TEAM))
                )
            )
        );
    }

    function testErc7201NamespaceAndV1FieldSlotsAreStable() external {
        assertEq(_addressAt(0), address(this), "governance slot");
        assertEq(_addressAt(1), address(token), "settlement slot");
        assertEq(_addressAt(2), address(registry), "registry slot");
        assertEq(_addressAt(3), TEAM, "treasury slot");
        assertEq(_uint32At(3, 20), 0, "default version packed offset");

        factory.setTeamTreasury(NEW_TEAM);
        assertEq(_addressAt(3), NEW_TEAM, "treasury slot after update");
        vm.store(address(factory), _slot(3), bytes32(uint256(uint160(NEW_TEAM)) | (uint256(1) << 160)));
        assertEq(factory.defaultMarketVersion(), 1, "default version offset");
        assertEq(factory.teamTreasury(), NEW_TEAM, "packed treasury preserved");
    }

    function testNamespacesDoNotCollideWithOpenZeppelinOrErc1967() external {
        assertTrue(FACTORY_STORAGE_LOCATION != INITIALIZABLE_STORAGE_LOCATION);
        assertTrue(FACTORY_STORAGE_LOCATION != REENTRANCY_GUARD_STORAGE_LOCATION);
        assertTrue(FACTORY_STORAGE_LOCATION != ERC1967_IMPLEMENTATION_SLOT);
        assertTrue(INITIALIZABLE_STORAGE_LOCATION != REENTRANCY_GUARD_STORAGE_LOCATION);
        assertTrue(INITIALIZABLE_STORAGE_LOCATION != ERC1967_IMPLEMENTATION_SLOT);
        assertTrue(REENTRANCY_GUARD_STORAGE_LOCATION != ERC1967_IMPLEMENTATION_SLOT);
    }

    function _addressAt(uint256 offset) private view returns (address) {
        return address(uint160(uint256(vm.load(address(factory), _slot(offset)))));
    }

    function _slot(uint256 offset) private pure returns (bytes32) {
        return bytes32(uint256(FACTORY_STORAGE_LOCATION) + offset);
    }

    function _uint32At(uint256 slotOffset, uint256 byteOffset) private view returns (uint32) {
        return uint32(uint256(vm.load(address(factory), _slot(slotOffset))) >> (byteOffset * 8));
    }
}
