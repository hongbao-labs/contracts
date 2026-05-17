// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ReentrancyGuard
/// @notice Minimal single-slot reentrancy guard. Cheaper than OZ's version by
///         only setting the slot on the first entry; subsequent external calls
///         within the same transaction are rejected.
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status = _NOT_ENTERED;

    error ReentrantCall();

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrantCall();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}
