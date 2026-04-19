// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../interfaces/IERC20.sol";

/// @title SafeERC20
/// @notice Minimal safe-transfer helpers that tolerate non-standard ERC20
///         implementations which return no data on success.
library SafeERC20 {
    error SafeTransferFailed();
    error SafeTransferFromFailed();

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert SafeTransferFailed();
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert SafeTransferFromFailed();
    }
}
