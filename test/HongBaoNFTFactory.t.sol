// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HongBaoNFTFactory} from "../src/HongBao/nft/HongBaoNFTFactory.sol";
import {HongBaoNFTPool} from "../src/HongBao/nft/HongBaoNFTPool.sol";
import {IHongBaoNFTFactory} from "../src/HongBao/nft/interfaces/IHongBaoNFTFactory.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract HongBaoNFTFactoryTest is Test {
    HongBaoNFTFactory public factory;
    MockERC721 public nftA;

    address initiator = address(0xA);

    function setUp() public {
        factory = new HongBaoNFTFactory();
        nftA = new MockERC721("A", "A");
    }

    function test_createPool_ok() public {
        address pool = factory.createPool(address(nftA), initiator);

        assertEq(factory.pools(address(nftA), initiator), pool);
        HongBaoNFTPool p = HongBaoNFTPool(pool);
        assertEq(p.lockedCollection(), address(nftA));
        assertEq(p.initiator(), initiator);
    }

    function test_createPool_duplicate_reverts() public {
        address first = factory.createPool(address(nftA), initiator);

        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTFactory.PoolExists.selector, address(nftA), initiator, first));
        factory.createPool(address(nftA), initiator);
    }

    function test_createPool_address_matches_compute() public {
        address predicted = factory.computePoolAddress(address(nftA), initiator);
        address deployed = factory.createPool(address(nftA), initiator);
        assertEq(predicted, deployed);
    }
}
