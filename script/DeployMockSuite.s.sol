// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockERC721} from "../test/mocks/MockERC721.sol";

/// @title DeployMockSuite — deploy a suite of 5 MockERC20s + 5 MockERC721s and
///                          dump the resulting addresses + metadata to JSON
///
/// @notice Useful for spinning up a test bench with several token shapes
///         (different decimals, different "themes") in one shot.
///
/// @notice Environment variables (all optional):
///           MINT_PER_TOKEN — whole tokens to mint to the deployer per ERC20
///                            (default 1000000; set 0 to skip; auto-scales by
///                            each token's `decimals()`)
///           OUTPUT         — JSON output path (default "mock-suite.json")
///
/// @notice Usage:
///   forge script script/DeployMockSuite.s.sol \
///     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --slow
///
/// @notice After broadcast, the JSON contains addresses + name/symbol/decimals.
///         The corresponding tx hashes live in
///         `broadcast/DeployMockSuite.s.sol/<chainId>/run-latest.json` and can
///         be spliced in with `script/merge-mock-suite-txhashes.sh <chainId>`.
contract DeployMockSuite is Script {
    struct ERC20Spec {
        string name;
        string symbol;
        uint8 decimals;
    }

    struct ERC721Spec {
        string name;
        string symbol;
    }

    function run() external {
        uint256 mintWhole = vm.envOr("MINT_PER_TOKEN", uint256(1_000_000));
        string memory outPath = vm.envOr("OUTPUT", string("mock-suite.json"));

        ERC20Spec[5] memory specs20 = [
            ERC20Spec("Test USDC", "USDC", 6),
            ERC20Spec("Test USDT", "USDT", 6),
            ERC20Spec("Test DAI", "DAI", 18),
            ERC20Spec("Test WBTC", "WBTC", 8),
            ERC20Spec("Test WETH", "WETH", 18)
        ];

        ERC721Spec[5] memory specs721 = [
            ERC721Spec("Test Bored Apes", "TBAYC"),
            ERC721Spec("Test Doodles", "TDOOD"),
            ERC721Spec("Test CryptoPunks", "TPUNK"),
            ERC721Spec("Test Azuki", "TAZUKI"),
            ERC721Spec("Test Mutant Apes", "TMAYC")
        ];

        MockERC20[5] memory tokens;
        MockERC721[5] memory nfts;

        vm.startBroadcast();

        for (uint256 i = 0; i < 5; i++) {
            tokens[i] = new MockERC20(specs20[i].name, specs20[i].symbol, specs20[i].decimals);
            if (mintWhole > 0) {
                uint256 amount = mintWhole * (10 ** uint256(specs20[i].decimals));
                tokens[i].mint(msg.sender, amount);
            }
        }
        for (uint256 i = 0; i < 5; i++) {
            nfts[i] = new MockERC721(specs721[i].name, specs721[i].symbol);
        }

        vm.stopBroadcast();

        // ---- write JSON ----
        string memory json = string.concat(
            "{\n",
            '  "chainId": ', vm.toString(block.chainid), ',\n',
            '  "deployer": "', vm.toString(msg.sender), '",\n',
            '  "mintPerToken": ', vm.toString(mintWhole), ',\n',
            '  "erc20": [\n'
        );
        for (uint256 i = 0; i < 5; i++) {
            json = string.concat(
                json,
                '    {"address": "', vm.toString(address(tokens[i])), '"',
                ', "name": "', specs20[i].name, '"',
                ', "symbol": "', specs20[i].symbol, '"',
                ', "decimals": ', vm.toString(uint256(specs20[i].decimals)),
                i < 4 ? "},\n" : "}\n"
            );
        }
        json = string.concat(json, '  ],\n  "erc721": [\n');
        for (uint256 i = 0; i < 5; i++) {
            json = string.concat(
                json,
                '    {"address": "', vm.toString(address(nfts[i])), '"',
                ', "name": "', specs721[i].name, '"',
                ', "symbol": "', specs721[i].symbol, '"',
                i < 4 ? "},\n" : "}\n"
            );
        }
        json = string.concat(json, "  ]\n}\n");

        vm.writeFile(outPath, json);

        // ---- console summary ----
        console.log("=========================================");
        console.log("  DeployMockSuite");
        console.log("=========================================");
        console.log("Chain id:        ", block.chainid);
        console.log("Deployer:        ", msg.sender);
        console.log("Mint per token:  ", mintWhole);
        console.log("Output:          ", outPath);
        console.log("-- ERC20 --");
        for (uint256 i = 0; i < 5; i++) {
            console.log(specs20[i].symbol, address(tokens[i]));
        }
        console.log("-- ERC721 --");
        for (uint256 i = 0; i < 5; i++) {
            console.log(specs721[i].symbol, address(nfts[i]));
        }
    }
}
