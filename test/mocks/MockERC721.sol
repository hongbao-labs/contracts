// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @notice Minimal ERC721 mock for HongBao NFT pool tests.
/// @dev    Only the surface HongBaoNFTPool actually invokes is implemented:
///         `setApprovalForAll`, `transferFrom`, both `safeTransferFrom`
///         overloads, plus a test-only `mint`. Per-token `approve` is
///         intentionally absent — the pool gets blanket operator rights via
///         setApprovalForAll in setUp.
contract MockERC721 {
    string public name;
    string public symbol;

    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    // Test hook: mark specific tokenIds as transfer-cursed so we can exercise
    // failure paths like batchWithdrawExpired's per-entry catch.
    mapping(uint256 => bool) public cursed;

    uint256 internal _freeMintCursor;

    error NotOwner();
    error NotAuthorized();
    error AlreadyMinted();
    error TransferToZero();
    error NonReceiver();
    error Cursed();

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 tokenId) external {
        if (to == address(0)) revert TransferToZero();
        if (ownerOf[tokenId] != address(0)) revert AlreadyMinted();
        ownerOf[tokenId] = to;
    }

    /// @notice Permissionless self-mint. Anyone can call to receive a fresh
    ///         tokenId; the cursor skips slots already claimed via `mint`.
    function freeMint() external returns (uint256 tokenId) {
        tokenId = _freeMintCursor;
        while (ownerOf[tokenId] != address(0)) {
            unchecked {
                tokenId++;
            }
        }
        unchecked {
            _freeMintCursor = tokenId + 1;
        }
        ownerOf[tokenId] = msg.sender;
    }

    function curse(uint256 tokenId) external {
        cursed[tokenId] = true;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        _transfer(from, to, tokenId);
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 ret) {
                if (ret != IERC721Receiver.onERC721Received.selector) revert NonReceiver();
            } catch {
                revert NonReceiver();
            }
        }
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        if (cursed[tokenId]) revert Cursed();
        if (to == address(0)) revert TransferToZero();
        if (ownerOf[tokenId] != from) revert NotOwner();
        if (msg.sender != from && !isApprovedForAll[from][msg.sender]) revert NotAuthorized();
        ownerOf[tokenId] = to;
    }
}
