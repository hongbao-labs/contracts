// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockERC721} from "../test/mocks/MockERC721.sol";

/// @title DeployMocks — one-click deploy of a fresh MockERC20 + MockERC721
///
/// @notice Convenience script for spinning up test assets on a testnet so the
///         HongBao Token / NFT pools have something to lock. Deploys both mocks
///         in a single broadcast and optionally seeds the deployer's balance.
///
/// @notice Environment variables (all optional, sensible defaults shown):
///           ERC20_NAME        — ERC20 token name        (default "Test USDC")
///           ERC20_SYMBOL      — ERC20 token symbol       (default "USDC")
///           ERC20_DECIMALS    — ERC20 decimals, 0..255   (default 6)
///           ERC20_MINT        — whole tokens to mint to the deployer
///                               (default 1000000; set 0 to skip). The script
///                               scales this by 10**decimals.
///           ERC721_NAME       — ERC721 collection name   (default "Test HongBao NFT")
///           ERC721_SYMBOL     — ERC721 collection symbol (default "HBNFT")
///           ERC721_MINT_COUNT — how many tokenIds to freeMint to the deployer
///                               (default 0; freeMint is permissionless so you
///                               can also mint later)
///
/// @notice Usage:
///   ERC20_NAME="Test DAI" ERC20_SYMBOL=DAI ERC20_DECIMALS=18 ERC20_MINT=1000000 \
///   ERC721_NAME="My NFT" ERC721_SYMBOL=MNFT ERC721_MINT_COUNT=3 \
///   forge script script/DeployMocks.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract DeployMocks is Script {
    function run() external returns (MockERC20 token, MockERC721 nft) {
        // ---- ERC20 params ----
        string memory erc20Name = vm.envOr("ERC20_NAME", string("Test USDC"));
        string memory erc20Symbol = vm.envOr("ERC20_SYMBOL", string("USDC"));
        uint256 decimalsRaw = vm.envOr("ERC20_DECIMALS", uint256(6));
        require(decimalsRaw <= type(uint8).max, "ERC20_DECIMALS out of range (0..255)");
        uint8 erc20Decimals = uint8(decimalsRaw);
        uint256 erc20MintWhole = vm.envOr("ERC20_MINT", uint256(1_000_000));

        // ---- ERC721 params ----
        string memory erc721Name = vm.envOr("ERC721_NAME", string("Test HongBao NFT"));
        string memory erc721Symbol = vm.envOr("ERC721_SYMBOL", string("HBNFT"));
        uint256 erc721MintCount = vm.envOr("ERC721_MINT_COUNT", uint256(0));

        vm.startBroadcast();

        token = new MockERC20(erc20Name, erc20Symbol, erc20Decimals);
        uint256 mintedBase;
        if (erc20MintWhole > 0) {
            mintedBase = erc20MintWhole * (10 ** erc20Decimals);
            token.mint(msg.sender, mintedBase);
        }

        nft = new MockERC721(erc721Name, erc721Symbol);
        for (uint256 i = 0; i < erc721MintCount;) {
            nft.freeMint();
            unchecked {
                ++i;
            }
        }

        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  DeployMocks");
        console.log("=========================================");
        console.log("Deployer:        ", msg.sender);
        console.log("-- MockERC20 --");
        console.log("Address:         ", address(token));
        console.log("Name:            ", erc20Name);
        console.log("Symbol:          ", erc20Symbol);
        console.log("Decimals:        ", erc20Decimals);
        console.log("Minted (whole):  ", erc20MintWhole);
        console.log("Minted (base):   ", mintedBase);
        console.log("-- MockERC721 --");
        console.log("Address:         ", address(nft));
        console.log("Name:            ", erc721Name);
        console.log("Symbol:          ", erc721Symbol);
        console.log("freeMint count:  ", erc721MintCount);
    }
}
