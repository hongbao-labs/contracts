// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ForgePool} from "../src/Agora/ForgePool.sol";
import {DepositInfo, RelayerWithdrawParams, ForgePoolErrors} from "../src/Agora/ForgePoolTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ForgePoolTest is Test {
    ForgePool public pool;
    MockERC20 public token;

    address deployer = address(this);
    address initiator = address(0xA);
    address relayer = address(0xBBB);
    address feeReceiver = address(0xFEE);

    uint256 cardPk = 0xBEEF;
    address cardAddr;

    uint256 constant FEE_BPS = 200; // 2% — 用户签名时承诺的手续费

    function setUp() public {
        token = new MockERC20("TestToken", "TT", 18);
        pool = new ForgePool(address(token), feeReceiver);
        cardAddr = vm.addr(cardPk);

        // 授权 relayer + minter
        pool.addRelayer(relayer);
        pool.addMinter(initiator);

        // 给 initiator 铸币并 approve
        token.mint(initiator, 10000 ether);
        vm.prank(initiator);
        token.approve(address(pool), type(uint256).max);
    }

    // ---- helpers ----

    function _deposit(uint256 amount, uint256 lockTime) internal {
        vm.prank(initiator);
        pool.deposit(cardAddr, amount, lockTime);
    }

    function _deposit100() internal {
        _deposit(100 ether, 180 days);
    }

    /// @dev 用卡片私钥签名 Withdraw(unlockAddress, to, feeBps)
    function _sign(address to, uint256 feeBps) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = pool.getWithdrawDigest(cardAddr, to, feeBps);
        (v, r, s) = vm.sign(cardPk, digest);
    }

    // ================================================================
    //                          DEPOSIT
    // ================================================================

    function test_deposit() public {
        _deposit100();

        DepositInfo memory info = pool.getDepositInfo(cardAddr);
        assertEq(info.initiator, initiator);
        assertEq(info.unlockAddress, cardAddr);
        assertEq(info.token, address(token));
        assertEq(info.amount, 100 ether);
        assertEq(info.lockTime, 180 days);
        assertEq(info.expire, block.timestamp + 180 days);
        assertEq(info.unlockedAt, 0);
        assertEq(token.balanceOf(address(pool)), 100 ether);
        assertTrue(pool.isLocked(cardAddr));
    }

    function test_deposit_revert_zero_amount() public {
        vm.prank(initiator);
        vm.expectRevert(ForgePoolErrors.ZeroAmount.selector);
        pool.deposit(cardAddr, 0, 180 days);
    }

    function test_deposit_revert_already_locked() public {
        _deposit100();
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolErrors.AlreadyLocked.selector, cardAddr));
        pool.deposit(cardAddr, 50 ether, 180 days);
    }

    function test_deposit_revert_lock_time_too_short() public {
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolErrors.LockTimeTooShort.selector, 1 days, 180 days));
        pool.deposit(cardAddr, 100 ether, 1 days);
    }

    function test_deposit_revert_zero_address() public {
        vm.prank(initiator);
        vm.expectRevert(ForgePoolErrors.ZeroAddress.selector);
        pool.deposit(address(0), 100 ether, 180 days);
    }

    function test_deposit_revert_not_minter() public {
        address stranger = address(0xBAD);
        token.mint(stranger, 100 ether);
        vm.prank(stranger);
        token.approve(address(pool), type(uint256).max);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolErrors.NotMinter.selector, stranger));
        pool.deposit(cardAddr, 100 ether, 180 days);
    }

    // ================================================================
    //                        BATCH DEPOSIT
    // ================================================================

    function test_batchDeposit() public {
        address[] memory addrs = new address[](3);
        addrs[0] = vm.addr(0xBEEF);
        addrs[1] = vm.addr(0xCAFE);
        addrs[2] = vm.addr(0xFACE);

        vm.prank(initiator);
        pool.batchDeposit(addrs, 50 ether, 180 days);

        assertEq(token.balanceOf(address(pool)), 150 ether);
        for (uint256 i = 0; i < 3; i++) {
            DepositInfo memory info = pool.getDepositInfo(addrs[i]);
            assertEq(info.initiator, initiator);
            assertEq(info.amount, 50 ether);
            assertEq(info.token, address(token));
            assertTrue(pool.isLocked(addrs[i]));
        }
    }

    function test_batchDeposit_revert_empty_array() public {
        address[] memory addrs = new address[](0);
        vm.prank(initiator);
        vm.expectRevert(ForgePoolErrors.EmptyArray.selector);
        pool.batchDeposit(addrs, 50 ether, 180 days);
    }

    function test_batchDeposit_revert_zero_amount() public {
        address[] memory addrs = new address[](1);
        addrs[0] = vm.addr(0xBEEF);
        vm.prank(initiator);
        vm.expectRevert(ForgePoolErrors.ZeroAmount.selector);
        pool.batchDeposit(addrs, 0, 180 days);
    }

    function test_batchDeposit_revert_duplicate_address() public {
        address addr = vm.addr(0xBEEF);
        address[] memory addrs = new address[](2);
        addrs[0] = addr;
        addrs[1] = addr;

        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolErrors.AlreadyLocked.selector, addr));
        pool.batchDeposit(addrs, 50 ether, 180 days);
    }

    function test_batchDeposit_revert_not_minter() public {
        address stranger = address(0xBAD);
        address[] memory addrs = new address[](1);
        addrs[0] = vm.addr(0xBEEF);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolErrors.NotMinter.selector, stranger));
        pool.batchDeposit(addrs, 50 ether, 180 days);
    }

    // ================================================================
    //                    WITHDRAW FROM CARD (无手续费)
    // ================================================================

    function test_withdrawFromCard_full_amount() public {
        _deposit100();

        address recipient = address(0xCAFE);
        (uint8 v, bytes32 r, bytes32 s) = _sign(recipient, FEE_BPS);

        pool.withdrawFromCard(cardAddr, recipient, FEE_BPS, v, r, s);

        // 全额到账，不扣费
        assertEq(token.balanceOf(recipient), 100 ether);
        assertEq(token.balanceOf(feeReceiver), 0);
        assertFalse(pool.isLocked(cardAddr));
    }

    function test_withdrawFromCard_revert_invalid_sig() public {
        _deposit100();

        address recipient = address(0xCAFE);
        uint256 wrongPk = 0xDEAD;
        bytes32 digest = pool.getWithdrawDigest(cardAddr, recipient, FEE_BPS);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);

        vm.expectRevert(ForgePoolErrors.InvalidSignature.selector);
        pool.withdrawFromCard(cardAddr, recipient, FEE_BPS, v, r, s);
    }

    function test_withdrawFromCard_revert_already_unlocked() public {
        _deposit100();

        address recipient = address(0xCAFE);
        (uint8 v, bytes32 r, bytes32 s) = _sign(recipient, FEE_BPS);
        pool.withdrawFromCard(cardAddr, recipient, FEE_BPS, v, r, s);

        vm.expectRevert(abi.encodeWithSelector(ForgePoolErrors.AlreadyUnlocked.selector, cardAddr));
        pool.withdrawFromCard(cardAddr, recipient, FEE_BPS, v, r, s);
    }

    function test_withdrawFromCard_revert_no_deposit() public {
        address nobody = address(0x999);
        (uint8 v, bytes32 r, bytes32 s) = _sign(nobody, 0);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolErrors.NoDeposit.selector, cardAddr));
        pool.withdrawFromCard(cardAddr, nobody, 0, v, r, s);
    }

    function test_withdrawFromCard_revert_zero_to() public {
        _deposit100();
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(0), FEE_BPS);
        vm.expectRevert(ForgePoolErrors.ZeroAddress.selector);
        pool.withdrawFromCard(cardAddr, address(0), FEE_BPS, v, r, s);
    }

    // ================================================================
    //                 WITHDRAW BY RELAYER (扣手续费)
    // ================================================================

    function test_withdrawByRelayer_deducts_fee() public {
        _deposit100();

        address recipient = address(0xCAFE);
        (uint8 v, bytes32 r, bytes32 s) = _sign(recipient, FEE_BPS);

        vm.prank(relayer);
        pool.withdrawFromCardByRelayer(cardAddr, recipient, FEE_BPS, v, r, s);

        // 2% fee = 2 ether
        assertEq(token.balanceOf(recipient), 98 ether);
        assertEq(token.balanceOf(feeReceiver), 2 ether);
    }

    function test_withdrawByRelayer_same_sig_as_direct() public {
        // 证明两条路径用同一个签名
        _deposit100();

        address recipient = address(0xCAFE);
        (uint8 v, bytes32 r, bytes32 s) = _sign(recipient, FEE_BPS);

        // 用 relayer 路径（如果先用直接路径就提走了，不能再用）
        vm.prank(relayer);
        pool.withdrawFromCardByRelayer(cardAddr, recipient, FEE_BPS, v, r, s);

        assertEq(token.balanceOf(recipient), 98 ether);
    }

    function test_withdrawByRelayer_fee_clamped_to_min() public {
        _deposit100();

        // 用户签了 feeBps=0，但合约 minFeeBps=50 (0.5%)
        address recipient = address(0xCAFE);
        (uint8 v, bytes32 r, bytes32 s) = _sign(recipient, 0);

        vm.prank(relayer);
        pool.withdrawFromCardByRelayer(cardAddr, recipient, 0, v, r, s);

        // 实际扣 0.5% = 0.5 ether
        assertEq(token.balanceOf(recipient), 99.5 ether);
        assertEq(token.balanceOf(feeReceiver), 0.5 ether);
    }

    function test_withdrawByRelayer_fee_clamped_to_max() public {
        _deposit100();

        // 用户签了 feeBps=5000 (50%)，但合约 maxFeeBps=1000 (10%)
        address recipient = address(0xCAFE);
        (uint8 v, bytes32 r, bytes32 s) = _sign(recipient, 5000);

        vm.prank(relayer);
        pool.withdrawFromCardByRelayer(cardAddr, recipient, 5000, v, r, s);

        // 实际扣 10% = 10 ether
        assertEq(token.balanceOf(recipient), 90 ether);
        assertEq(token.balanceOf(feeReceiver), 10 ether);
    }

    function test_withdrawByRelayer_revert_not_relayer() public {
        _deposit100();

        address recipient = address(0xCAFE);
        (uint8 v, bytes32 r, bytes32 s) = _sign(recipient, FEE_BPS);

        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolErrors.NotRelayer.selector, stranger));
        pool.withdrawFromCardByRelayer(cardAddr, recipient, FEE_BPS, v, r, s);
    }

    // ================================================================
    //                  BATCH WITHDRAW BY RELAYER
    // ================================================================

    function test_batchWithdrawByRelayer() public {
        uint256[3] memory pks = [uint256(0xBEEF), uint256(0xCAFE), uint256(0xFACE)];
        address[3] memory addrs;
        address[3] memory recipients;

        for (uint256 i = 0; i < 3; i++) {
            addrs[i] = vm.addr(pks[i]);
            recipients[i] = address(uint160(0x1000 + i));

            token.mint(initiator, 100 ether);
            vm.prank(initiator);
            token.approve(address(pool), type(uint256).max);
            vm.prank(initiator);
            pool.deposit(addrs[i], 100 ether, 180 days);
        }

        RelayerWithdrawParams[] memory params = new RelayerWithdrawParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            bytes32 digest = pool.getWithdrawDigest(addrs[i], recipients[i], FEE_BPS);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], digest);
            params[i] =
                RelayerWithdrawParams({unlockAddress: addrs[i], to: recipients[i], feeBps: FEE_BPS, v: v, r: r, s: s});
        }

        vm.prank(relayer);
        pool.batchWithdrawFromCardByRelayer(params);

        for (uint256 i = 0; i < 3; i++) {
            assertEq(token.balanceOf(recipients[i]), 98 ether);
        }
        assertEq(token.balanceOf(feeReceiver), 6 ether);
    }

    // ================================================================
    //                     WITHDRAW EXPIRED
    // ================================================================

    function test_withdrawExpired() public {
        _deposit100();
        vm.warp(block.timestamp + 180 days + 1);

        vm.prank(initiator);
        pool.withdrawExpired(cardAddr);

        assertEq(token.balanceOf(initiator), 10000 ether);
        assertFalse(pool.isLocked(cardAddr));
    }

    function test_withdrawExpired_revert_not_expired() public {
        _deposit100();
        vm.prank(initiator);
        vm.expectRevert(
            abi.encodeWithSelector(ForgePoolErrors.NotExpired.selector, cardAddr, block.timestamp + 180 days)
        );
        pool.withdrawExpired(cardAddr);
    }

    function test_withdrawExpired_revert_not_initiator() public {
        _deposit100();
        vm.warp(block.timestamp + 180 days + 1);

        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolErrors.NotInitiator.selector, stranger));
        pool.withdrawExpired(cardAddr);
    }

    // ================================================================
    //                  BATCH WITHDRAW EXPIRED
    // ================================================================

    function test_batchWithdrawExpired() public {
        uint256[3] memory pks = [uint256(0xBEEF), uint256(0xCAFE), uint256(0xFACE)];
        address[] memory addrs = new address[](3);

        for (uint256 i = 0; i < 3; i++) {
            addrs[i] = vm.addr(pks[i]);
            token.mint(initiator, 100 ether);
            vm.prank(initiator);
            token.approve(address(pool), type(uint256).max);
            vm.prank(initiator);
            pool.deposit(addrs[i], 100 ether, 180 days);
        }

        vm.warp(block.timestamp + 180 days + 1);

        uint256 balBefore = token.balanceOf(initiator);
        vm.prank(initiator);
        pool.batchWithdrawExpired(addrs);

        assertEq(token.balanceOf(initiator) - balBefore, 300 ether);
    }

    // ================================================================
    //                       VIEW FUNCTIONS
    // ================================================================

    function test_isLocked_and_isExpired() public {
        _deposit100();
        assertTrue(pool.isLocked(cardAddr));
        assertFalse(pool.isExpired(cardAddr));

        vm.warp(block.timestamp + 180 days);
        assertTrue(pool.isLocked(cardAddr));
        assertTrue(pool.isExpired(cardAddr));
    }

    function test_remainingLockTime() public {
        _deposit100();
        assertEq(pool.remainingLockTime(cardAddr), 180 days);

        vm.warp(block.timestamp + 10 days);
        assertEq(pool.remainingLockTime(cardAddr), 170 days);

        vm.warp(block.timestamp + 180 days);
        assertEq(pool.remainingLockTime(cardAddr), 0);
    }

    function test_getWithdrawDigest_deterministic() public view {
        address to = address(0xCAFE);
        bytes32 d1 = pool.getWithdrawDigest(cardAddr, to, FEE_BPS);
        bytes32 d2 = pool.getWithdrawDigest(cardAddr, to, FEE_BPS);
        assertEq(d1, d2);

        // 不同 feeBps 产生不同 digest
        bytes32 d3 = pool.getWithdrawDigest(cardAddr, to, 0);
        assertTrue(d1 != d3);
    }

    function test_lockedToken() public view {
        assertEq(pool.lockedToken(), address(token));
    }

    // ================================================================
    //                       ACCESS CONTROL
    // ================================================================

    function test_addRelayer_removeRelayer() public {
        address newRelayer = address(0xCCC);
        assertFalse(pool.isRelayer(newRelayer));

        pool.addRelayer(newRelayer);
        assertTrue(pool.isRelayer(newRelayer));

        pool.removeRelayer(newRelayer);
        assertFalse(pool.isRelayer(newRelayer));
    }

    function test_addMinter_removeMinter() public {
        address newMinter = address(0xDDD);
        assertFalse(pool.isMinter(newMinter));

        pool.addMinter(newMinter);
        assertTrue(pool.isMinter(newMinter));

        pool.removeMinter(newMinter);
        assertFalse(pool.isMinter(newMinter));
    }

    function test_transferOwnership() public {
        address newOwner = address(0xEE);
        pool.transferOwnership(newOwner);
        assertEq(pool.pendingOwner(), newOwner);

        vm.prank(newOwner);
        pool.acceptOwnership();
        assertEq(pool.owner(), newOwner);
    }

    function test_onlyOwner_revert() public {
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolErrors.NotOwner.selector, stranger));
        pool.setMinLockTime(1);
    }

    // ================================================================
    //                       ADMIN CONFIG
    // ================================================================

    function test_setMinLockTime() public {
        pool.setMinLockTime(365 days);
        assertEq(pool.minLockTime(), 365 days);
    }

    function test_setMinFeeBps() public {
        pool.setMinFeeBps(100);
        assertEq(pool.minFeeBps(), 100);
    }

    function test_setMaxFeeBps() public {
        pool.setMaxFeeBps(500);
        assertEq(pool.maxFeeBps(), 500);
    }

    function test_setFeeRecipient() public {
        address newFee = address(0xFEE2);
        pool.setFeeRecipient(newFee);
        assertEq(pool.feeRecipient(), newFee);
    }

    // ================================================================
    //                         PAUSE
    // ================================================================

    function test_pause_blocks_deposit() public {
        pool.pause();
        assertTrue(pool.paused());

        vm.prank(initiator);
        vm.expectRevert(ForgePoolErrors.ContractPaused.selector);
        pool.deposit(cardAddr, 100 ether, 180 days);

        pool.unpause();
        assertFalse(pool.paused());
    }

    function test_pause_blocks_withdraw() public {
        _deposit100();
        pool.pause();

        address recipient = address(0xCAFE);
        (uint8 v, bytes32 r, bytes32 s) = _sign(recipient, FEE_BPS);

        vm.expectRevert(ForgePoolErrors.ContractPaused.selector);
        pool.withdrawFromCard(cardAddr, recipient, FEE_BPS, v, r, s);
    }
}
