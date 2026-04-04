// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForgePoolErrors} from "./ForgePoolTypes.sol";

/// @title ForgePoolAccess - 权限管理（Owner、Relayer、Pause）
abstract contract ForgePoolAccess {
    address public owner;
    address public pendingOwner;
    bool public paused;

    mapping(address => bool) public isRelayer;
    mapping(address => bool) public isMinter;

    // ---- Events ----
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    // ---- Modifiers ----
    modifier onlyOwner() {
        if (msg.sender != owner) revert ForgePoolErrors.NotOwner(msg.sender);
        _;
    }

    modifier onlyRelayer() {
        if (!isRelayer[msg.sender]) revert ForgePoolErrors.NotRelayer(msg.sender);
        _;
    }

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert ForgePoolErrors.NotMinter(msg.sender);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ForgePoolErrors.ContractPaused();
        _;
    }

    // ---- Ownership (2-step) ----

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ForgePoolErrors.ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert ForgePoolErrors.NotPendingOwner(msg.sender);
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ---- Relayer Management ----

    function addRelayer(address relayer) external onlyOwner {
        if (relayer == address(0)) revert ForgePoolErrors.ZeroAddress();
        isRelayer[relayer] = true;
        emit RelayerAdded(relayer);
    }

    function removeRelayer(address relayer) external onlyOwner {
        isRelayer[relayer] = false;
        emit RelayerRemoved(relayer);
    }

    // ---- Minter Management ----

    function addMinter(address minter) external onlyOwner {
        if (minter == address(0)) revert ForgePoolErrors.ZeroAddress();
        isMinter[minter] = true;
        emit MinterAdded(minter);
    }

    function removeMinter(address minter) external onlyOwner {
        isMinter[minter] = false;
        emit MinterRemoved(minter);
    }

    // ---- Pause ----

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }
}
