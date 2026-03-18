// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============ Structs ============

struct DepositInfo {
    address initiator; // 存款发起人
    address unlockAddress; // 卡片公钥地址（解锁凭证）
    address token; // ERC20 代币地址
    uint256 amount; // 锁定数量
    uint256 lockTime; // 锁定时长
    uint256 mintTimeStamp; // 存款时间戳
    uint256 expire; // 过期时间戳
    uint256 unlockedAt; // 解锁时间戳（0 = 未解锁）
}

struct RelayerWithdrawParams {
    address unlockAddress;
    address to;
    uint256 feeBps;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

// ============ Events ============

library ForgePoolEvents {
    event Deposited(
        address indexed initiator, address indexed unlockAddress, address token, uint256 amount, uint256 expire
    );

    event WithdrawnByCard(address indexed unlockAddress, address indexed to, address token, uint256 amount);

    event WithdrawnByRelayer(
        address indexed unlockAddress,
        address indexed to,
        address indexed relayer,
        address token,
        uint256 amount,
        uint256 fee
    );

    event WithdrawnExpired(address indexed initiator, address indexed unlockAddress, address token, uint256 amount);
}

// ============ Errors ============

library ForgePoolErrors {
    // ---- Deposit ----
    error ZeroAmount();
    error ZeroAddress();
    error AlreadyLocked(address unlockAddress);
    error LockTimeTooShort(uint256 provided, uint256 minimum);

    // ---- Withdraw ----
    error NoDeposit(address unlockAddress);
    error AlreadyUnlocked(address unlockAddress);
    error InvalidSignature();
    error NotExpired(address unlockAddress, uint256 expire);
    error NotInitiator(address caller);

    // ---- Relayer ----
    error NotRelayer(address caller);
    error FeeTooHigh(uint256 provided, uint256 maximum);

    // ---- Access ----
    error NotOwner(address caller);
    error NotPendingOwner(address caller);
    error ContractPaused();
}
