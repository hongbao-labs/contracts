// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HongBaoFactory} from "../src/HongBao/HongBaoFactory.sol";
import {HongBaoPool} from "../src/HongBao/HongBaoPool.sol";
import {IHongBaoFactory} from "../src/HongBao/interfaces/IHongBaoFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract HongBaoFactoryTest is Test {
    HongBaoFactory public factory;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address initiator = address(0xA);

    function setUp() public {
        factory = new HongBaoFactory();
        tokenA = new MockERC20("TokenA", "TA", 18);
        tokenB = new MockERC20("TokenB", "TB", 18);
    }

    function test_createPool_ok() public {
        address pool = factory.createPool(address(tokenA), initiator);

        assertEq(factory.pools(address(tokenA), initiator), pool);

        HongBaoPool p = HongBaoPool(pool);
        assertEq(p.lockedToken(), address(tokenA));
        assertEq(p.initiator(), initiator);
    }

    function test_createPool_address_matches_compute() public {
        address predicted = factory.computePoolAddress(address(tokenA), initiator);
        address deployed = factory.createPool(address(tokenA), initiator);
        assertEq(predicted, deployed);
    }

    function test_createPool_zero_token_reverts() public {
        vm.expectRevert(IHongBaoFactory.ZeroAddress.selector);
        factory.createPool(address(0), initiator);
    }

    function test_createPool_open_pool_ok() public {
        // initiator == 0 is a valid "open" pool.
        address pool = factory.createPool(address(tokenA), address(0));
        assertEq(HongBaoPool(pool).initiator(), address(0));
        assertEq(factory.pools(address(tokenA), address(0)), pool);
    }

    function test_createPool_duplicate_reverts() public {
        address first = factory.createPool(address(tokenA), initiator);

        vm.expectRevert(
            abi.encodeWithSelector(IHongBaoFactory.PoolExists.selector, address(tokenA), initiator, first)
        );
        factory.createPool(address(tokenA), initiator);
    }

    function test_createPool_different_initiator_same_token_ok() public {
        address initiatorB = address(0xB);
        address poolA = factory.createPool(address(tokenA), initiator);
        address poolB = factory.createPool(address(tokenA), initiatorB);

        assertTrue(poolA != poolB);
        assertEq(factory.pools(address(tokenA), initiator), poolA);
        assertEq(factory.pools(address(tokenA), initiatorB), poolB);
    }

    function test_createPool_different_token_same_initiator_ok() public {
        address poolA = factory.createPool(address(tokenA), initiator);
        address poolB = factory.createPool(address(tokenB), initiator);

        assertTrue(poolA != poolB);
        assertEq(factory.pools(address(tokenA), initiator), poolA);
        assertEq(factory.pools(address(tokenB), initiator), poolB);
    }

    function test_computePoolAddress_stable_before_deploy() public view {
        address a1 = factory.computePoolAddress(address(tokenA), initiator);
        address a2 = factory.computePoolAddress(address(tokenA), initiator);
        assertEq(a1, a2);
    }
}
