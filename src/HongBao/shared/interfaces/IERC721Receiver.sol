// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Callback interface an NFT recipient contract must implement to
///         accept transfers via `safeTransferFrom`.
interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}
