// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeERC20} from "./SafeERC20.sol";
import {ForgePoolAccess} from "./ForgePoolAccess.sol";
import {DepositInfo, RelayerWithdrawParams, ForgePoolEvents, ForgePoolErrors} from "./ForgePoolTypes.sol";

/// @title ForgePool - 一次性礼品卡锁仓合约
/// @notice 用户存入 ERC20 锁定到卡片公钥地址，持卡人签名解锁
/// @dev 设备只签名一次：Withdraw(unlockAddress, to, feeBps)
///      - withdrawFromCard: 验签，全额转出（忽略 feeBps）
///      - withdrawFromCardByRelayer: 验签，按 feeBps 扣费
contract ForgePool is ForgePoolAccess {
    using SafeERC20 for IERC20;

    // ---- Constants ----
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @dev 唯一的签名格式，设备只签一次
    bytes32 public constant WITHDRAW_TYPEHASH = keccak256("Withdraw(address unlockAddress,address to,uint256 feeBps)");

    // ---- Config ----
    uint256 public minLockTime; // 默认 180 天
    uint256 public minFeeBps; // 默认 50 = 0.5%
    uint256 public maxFeeBps; // 默认 1000 = 10%
    address public feeRecipient;

    // ---- EIP-712 ----
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ---- Storage ----
    mapping(address => DepositInfo) public depositRecord;

    // ================================================================
    //                         CONSTRUCTOR
    // ================================================================

    constructor(address _feeRecipient) {
        owner = msg.sender;
        feeRecipient = _feeRecipient == address(0) ? msg.sender : _feeRecipient;
        minLockTime = 180 days;
        minFeeBps = 50; // 0.5%
        maxFeeBps = 1000; // 10%

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ForgePool"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ================================================================
    //                           DEPOSIT
    // ================================================================

    /// @notice 存入 ERC20，锁定到卡片公钥地址
    function deposit(address unlockAddress, address token, uint256 amount, uint256 lockTime) external whenNotPaused {
        if (amount == 0) revert ForgePoolErrors.ZeroAmount();
        if (unlockAddress == address(0)) revert ForgePoolErrors.ZeroAddress();
        if (token == address(0)) revert ForgePoolErrors.ZeroAddress();
        if (depositRecord[unlockAddress].amount != 0) revert ForgePoolErrors.AlreadyLocked(unlockAddress);
        if (lockTime < minLockTime) revert ForgePoolErrors.LockTimeTooShort(lockTime, minLockTime);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        depositRecord[unlockAddress] = DepositInfo({
            initiator: msg.sender,
            unlockAddress: unlockAddress,
            token: token,
            amount: amount,
            lockTime: lockTime,
            mintTimeStamp: block.timestamp,
            expire: block.timestamp + lockTime,
            unlockedAt: 0
        });

        emit ForgePoolEvents.Deposited(msg.sender, unlockAddress, token, amount, block.timestamp + lockTime);
    }

    // ================================================================
    //                    WITHDRAW (持卡人直接提取)
    // ================================================================

    /// @notice 持卡人直接提取，全额转出，不扣手续费
    /// @param feeBps 签名中包含的手续费比例（仅用于验签，不实际扣费）
    function withdrawFromCard(address unlockAddress, address to, uint256 feeBps, uint8 v, bytes32 r, bytes32 s)
        external
        whenNotPaused
    {
        if (to == address(0)) revert ForgePoolErrors.ZeroAddress();

        DepositInfo storage info = depositRecord[unlockAddress];
        if (info.amount == 0) revert ForgePoolErrors.NoDeposit(unlockAddress);
        if (info.unlockedAt != 0) revert ForgePoolErrors.AlreadyUnlocked(unlockAddress);

        _verifySignature(unlockAddress, to, feeBps, v, r, s);

        info.unlockedAt = block.timestamp;
        IERC20(info.token).safeTransfer(to, info.amount);

        emit ForgePoolEvents.WithdrawnByCard(unlockAddress, to, info.token, info.amount);
    }

    // ================================================================
    //              WITHDRAW BY RELAYER (特权 relayer 代执行)
    // ================================================================

    /// @notice Relayer 代执行单笔卡片签名提款，按签名中的 feeBps 扣费
    function withdrawFromCardByRelayer(address unlockAddress, address to, uint256 feeBps, uint8 v, bytes32 r, bytes32 s)
        external
        onlyRelayer
        whenNotPaused
    {
        _withdrawByRelayer(unlockAddress, to, feeBps, v, r, s);
    }

    /// @notice Relayer 批量执行卡片签名提款
    function batchWithdrawFromCardByRelayer(RelayerWithdrawParams[] calldata params)
        external
        onlyRelayer
        whenNotPaused
    {
        for (uint256 i = 0; i < params.length; i++) {
            RelayerWithdrawParams calldata p = params[i];
            _withdrawByRelayer(p.unlockAddress, p.to, p.feeBps, p.v, p.r, p.s);
        }
    }

    // ================================================================
    //                   WITHDRAW EXPIRED (发起人取回)
    // ================================================================

    /// @notice 锁定到期后，initiator 取回资产
    function withdrawExpired(address unlockAddress) external whenNotPaused {
        _withdrawExpired(unlockAddress);
    }

    /// @notice Initiator 批量取回过期资产
    function batchWithdrawExpired(address[] calldata unlockAddresses) external whenNotPaused {
        for (uint256 i = 0; i < unlockAddresses.length; i++) {
            _withdrawExpired(unlockAddresses[i]);
        }
    }

    // ================================================================
    //                        VIEW FUNCTIONS
    // ================================================================

    function getDepositInfo(address unlockAddress) external view returns (DepositInfo memory) {
        return depositRecord[unlockAddress];
    }

    function isLocked(address unlockAddress) external view returns (bool) {
        DepositInfo storage info = depositRecord[unlockAddress];
        return info.amount > 0 && info.unlockedAt == 0;
    }

    function isExpired(address unlockAddress) external view returns (bool) {
        DepositInfo storage info = depositRecord[unlockAddress];
        return info.amount > 0 && info.unlockedAt == 0 && block.timestamp >= info.expire;
    }

    function remainingLockTime(address unlockAddress) external view returns (uint256) {
        DepositInfo storage info = depositRecord[unlockAddress];
        if (info.amount == 0 || info.unlockedAt != 0 || block.timestamp >= info.expire) return 0;
        return info.expire - block.timestamp;
    }

    /// @notice 计算签名 digest（设备端签名用，两种提取路径共用）
    function getWithdrawDigest(address unlockAddress, address to, uint256 feeBps) external view returns (bytes32) {
        return _getDigest(unlockAddress, to, feeBps);
    }

    // ================================================================
    //                       ADMIN CONFIG
    // ================================================================

    function setMinLockTime(uint256 _minLockTime) external onlyOwner {
        minLockTime = _minLockTime;
    }

    function setMinFeeBps(uint256 _minFeeBps) external onlyOwner {
        if (_minFeeBps > maxFeeBps) revert ForgePoolErrors.FeeTooHigh(_minFeeBps, maxFeeBps);
        minFeeBps = _minFeeBps;
    }

    function setMaxFeeBps(uint256 _maxFeeBps) external onlyOwner {
        if (_maxFeeBps > BPS_DENOMINATOR) revert ForgePoolErrors.FeeTooHigh(_maxFeeBps, BPS_DENOMINATOR);
        maxFeeBps = _maxFeeBps;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert ForgePoolErrors.ZeroAddress();
        feeRecipient = _feeRecipient;
    }

    // ================================================================
    //                      INTERNAL FUNCTIONS
    // ================================================================

    function _getDigest(address unlockAddress, address to, uint256 feeBps) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, unlockAddress, to, feeBps));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _verifySignature(address unlockAddress, address to, uint256 feeBps, uint8 v, bytes32 r, bytes32 s)
        internal
        view
    {
        bytes32 digest = _getDigest(unlockAddress, to, feeBps);
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != unlockAddress) revert ForgePoolErrors.InvalidSignature();
    }

    function _withdrawByRelayer(address unlockAddress, address to, uint256 feeBps, uint8 v, bytes32 r, bytes32 s)
        internal
    {
        if (to == address(0)) revert ForgePoolErrors.ZeroAddress();

        DepositInfo storage info = depositRecord[unlockAddress];
        if (info.amount == 0) revert ForgePoolErrors.NoDeposit(unlockAddress);
        if (info.unlockedAt != 0) revert ForgePoolErrors.AlreadyUnlocked(unlockAddress);

        _verifySignature(unlockAddress, to, feeBps, v, r, s);

        // 实际扣费: 用户签的 feeBps 夹到 [minFeeBps, maxFeeBps]
        uint256 actualFeeBps = feeBps;
        if (actualFeeBps < minFeeBps) actualFeeBps = minFeeBps;
        if (actualFeeBps > maxFeeBps) actualFeeBps = maxFeeBps;

        info.unlockedAt = block.timestamp;
        uint256 amount = info.amount;
        address token = info.token;

        uint256 fee = (amount * actualFeeBps) / BPS_DENOMINATOR;
        uint256 payout = amount - fee;

        IERC20(token).safeTransfer(to, payout);
        if (fee > 0) {
            IERC20(token).safeTransfer(feeRecipient, fee);
        }

        emit ForgePoolEvents.WithdrawnByRelayer(unlockAddress, to, msg.sender, token, payout, fee);
    }

    function _withdrawExpired(address unlockAddress) internal {
        DepositInfo storage info = depositRecord[unlockAddress];
        if (info.amount == 0) revert ForgePoolErrors.NoDeposit(unlockAddress);
        if (info.unlockedAt != 0) revert ForgePoolErrors.AlreadyUnlocked(unlockAddress);
        if (block.timestamp < info.expire) revert ForgePoolErrors.NotExpired(unlockAddress, info.expire);
        if (msg.sender != info.initiator) revert ForgePoolErrors.NotInitiator(msg.sender);

        info.unlockedAt = block.timestamp;
        IERC20(info.token).safeTransfer(info.initiator, info.amount);

        emit ForgePoolEvents.WithdrawnExpired(info.initiator, unlockAddress, info.token, info.amount);
    }
}
