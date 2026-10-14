// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SRNetBalance} from "../src/SRNetBalance.sol";
import {MockCfVault} from "./MockCfVault.sol";
import {MockToken} from "./Mocks.sol";
import {BlacklistUSDC, NastyToken, EthSink} from "./CcmMocks.sol";

/// @dev Chainflip CCM receive path. The MockCfVault mirrors Vault._executexSwapAndCall:
///      transfer first, then call cfReceive; a receiver revert bubbles (the real broadcast would fail
///      and funds would stay stuck in the Vault), so every Vault-originated path must NOT revert.
contract CcmTest is Test {
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint32 internal constant SRC_BTC = 3; // Chainflip ForeignChain::Bitcoin

    BlacklistUSDC internal usdc;
    MockCfVault internal vault;
    SRNetBalance internal b;
    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("fee");
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new BlacklistUSDC();
        vault = new MockCfVault();
        b = new SRNetBalance(address(usdc), feeRecipient, owner, 20e6, 168, 300, address(vault), 1e6);
        usdc.mint(address(vault), 1e15);
        vm.deal(address(vault), 1000 ether);
    }

    function _msg(address who) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), who);
    }

    function _msgF(address who, uint64 f) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), who, f);
    }

    function _ccm(address token, uint256 amount, bytes memory message) internal {
        vault.executexSwapAndCall(MockCfVault.TransferParams(token, address(b), amount), SRC_BTC, "", message);
    }

    function _accounted(address[] memory users) internal view returns (uint256 s) {
        s = b.accruedFees() + b.heldTotal(address(usdc)) + b.unattributedUsdc();
        for (uint256 i; i < users.length; ++i) {
            s += b.availableOf(users[i]) + b.lockedOf(users[i]) + b.payableOf(users[i]);
        }
    }

    // ── access control ────────────────────────────────────────────────────

    function test_wrong_caller_reverts_even_with_fake_amount() public {
        vm.prank(attacker);
        vm.expectRevert(SRNetBalance.NotCfVault.selector);
        b.cfReceive(SRC_BTC, "", _msg(attacker), address(usdc), 1_000_000e6);
        assertEq(b.availableOf(attacker), 0);
    }

    function testFuzz_only_vault_can_call(address caller, bytes calldata m, uint256 amt) public {
        vm.assume(caller != address(vault));
        vm.prank(caller);
        vm.expectRevert(SRNetBalance.NotCfVault.selector);
        b.cfReceive(1, "", m, address(usdc), amt);
    }

    function test_vault_is_immutable_and_validated() public {
        assertEq(b.cfVault(), address(vault));
        vm.expectRevert(SRNetBalance.BadVault.selector);
        new SRNetBalance(address(usdc), feeRecipient, owner, 20e6, 168, 300, address(0), 1e6);
        vm.expectRevert(SRNetBalance.BadVault.selector);
        new SRNetBalance(address(usdc), feeRecipient, owner, 20e6, 168, 300, makeAddr("eoaVault"), 1e6);
        vm.expectRevert(SRNetBalance.BadVault.selector);
        new SRNetBalance(address(usdc), feeRecipient, owner, 20e6, 168, 300, address(usdc), 1e6);
        vm.expectRevert(SRNetBalance.RelayFeeTooHigh.selector);
        new SRNetBalance(address(usdc), feeRecipient, owner, 20e6, 168, 300, address(vault), 5e6 + 1);
    }

    function test_vault_cannot_credit_more_than_delivered() public {
        _ccm(address(usdc), 10e6, _msg(alice)); // honest delivery
        // the Vault (e.g. compromised) reports 1,000 USDC without transferring anything
        vm.prank(address(vault));
        b.cfReceive(SRC_BTC, "", _msg(attacker), address(usdc), 1_000e6);
        assertEq(b.availableOf(attacker), 0);
        // partial: reports 5 but only 2 arrived
        usdc.mint(address(b), 2e6);
        vm.prank(address(vault));
        b.cfReceive(SRC_BTC, "", _msg(attacker), address(usdc), 5e6);
        assertEq(b.availableOf(attacker), 2e6 - 0.06e6);
        assertEq(b.totalLiabilities(), usdc.balanceOf(address(b)));
        // alice's funds untouched and fully withdrawable
        vm.prank(alice);
        b.cashOut(9.7e6);
        assertEq(usdc.balanceOf(alice), 9.7e6);
    }

    // ── USDC credit ───────────────────────────────────────────────────────

    function test_usdc_credit_one_step_with_fee() public {
        _ccm(address(usdc), 100e6, _msg(alice));
        assertEq(b.availableOf(alice), 97e6);
        assertEq(b.accruedFees(), 3e6);
        assertEq(usdc.balanceOf(address(b)), 100e6);
        // the credit is immediately usable for a lease
        bytes32 salt = bytes32(uint256(7));
        address seller = makeAddr("seller");
        bytes32 vid = keccak256(abi.encodePacked(seller, salt));
        vm.prank(seller);
        b.configureVendor(vid, salt);
        vm.prank(alice);
        b.startLease(vid, 1e6, 2);
        assertEq(b.lockedOf(alice), 2e6);
    }

    function test_encode_helper_matches_packed() public view {
        assertEq(b.encodeCcmMessage(alice, 0), _msg(alice));
        assertEq(b.encodeCcmMessage(alice, 2e6), _msgF(alice, 2e6));
        assertEq(_msg(alice).length, 21);
        assertEq(_msgF(alice, 1).length, 29);
    }

    function test_wallet_float_forwarded_fee_free_and_capped() public {
        _ccm(address(usdc), 50e6, _msgF(alice, 2e6));
        assertEq(usdc.balanceOf(alice), 2e6);
        assertEq(b.availableOf(alice), 48e6 - (48e6 * 300) / 10_000);
        // float above MAX_WALLET_FLOAT is capped at $5
        address bob = makeAddr("bob");
        _ccm(address(usdc), 50e6, _msgF(bob, 100e6));
        assertEq(usdc.balanceOf(bob), 5e6);
        // float above the amount is capped at the amount
        address carol = makeAddr("carol");
        _ccm(address(usdc), 1e6, _msgF(carol, 3e6));
        assertEq(usdc.balanceOf(carol), 1e6);
        assertEq(b.availableOf(carol), 0);
    }

    function test_wallet_float_push_fails_then_credited() public {
        usdc.setBlocked(alice, true);
        _ccm(address(usdc), 10e6, _msgF(alice, 2e6));
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(b.availableOf(alice), 10e6 - 0.3e6);
    }

    function test_zero_amount_noop() public {
        _ccm(address(usdc), 0, _msg(alice));
        assertEq(b.availableOf(alice), 0);
        assertEq(b.accruedFees(), 0);
    }

    function test_src_address_ignored_for_valid_message() public {
        vault.executexSwapAndCall(
            MockCfVault.TransferParams(address(usdc), address(b), 10e6), 5, abi.encodePacked(attacker), _msg(alice)
        );
        assertEq(b.availableOf(alice), 9.7e6);
        assertEq(b.availableOf(attacker), 0);
    }

    // ── malformed / unattributable ───────────────────────────────────────

    function _bad() internal view returns (bytes[6] memory) {
        return [
            bytes(""),
            hex"deadc0de",
            abi.encodePacked(uint8(2), alice),
            abi.encodePacked(uint8(1), address(0)),
            abi.encodePacked(uint8(1), address(b)),
            abi.encode(alice) // 32 bytes, wrong length
        ];
    }

    /// Unreadable message from a deposit channel (empty srcAddress): HELD in the locked
    /// unattributed bucket, never fees, never reverts, and nobody (owner included) can move it.
    function test_unreadable_usdc_deposit_channel_held_not_fees() public {
        bytes[6] memory bad = _bad();
        for (uint256 i; i < bad.length; ++i) {
            _ccm(address(usdc), 1e6, bad[i]);
        }
        assertEq(b.accruedFees(), 0, "never booked as fees");
        assertEq(b.unattributedUsdc(), 6e6);
        assertEq(b.totalLiabilities(), 6e6);
        assertEq(b.availableOf(alice), 0);
        assertEq(usdc.balanceOf(address(b)), 6e6);
        // the owner has no lever over it
        vm.startPrank(owner);
        vm.expectRevert(SRNetBalance.CannotRescueUsdc.selector);
        b.rescueToken(address(usdc), owner, 1);
        b.setPaused(true);
        b.setFeeRecipient(owner);
        vm.expectRevert(SRNetBalance.ZeroAmount.selector);
        b.withdrawFees();
        vm.expectRevert(SRNetBalance.NothingHeld.selector);
        b.claimHeld(address(usdc));
        vm.stopPrank();
        assertEq(usdc.balanceOf(owner), 0);
        assertEq(b.unattributedUsdc(), 6e6);
        assertEq(usdc.balanceOf(address(b)), 6e6);
    }

    /// Recovery path: an unreadable message from a Vault swap with a 20-byte EVM srcAddress is
    /// held for THAT address only, which reclaims it with claimHeld(usdc). Deterministic, no owner step.
    function test_unreadable_usdc_with_evm_src_held_for_sender_and_claimable() public {
        address sender = makeAddr("sender");
        vm.expectEmit(true, false, false, true, address(b));
        emit SRNetBalance.CcmUnattributed(5, abi.encodePacked(sender), hex"c0ffee", 7e6, sender);
        vault.executexSwapAndCall(
            MockCfVault.TransferParams(address(usdc), address(b), 7e6), 5, abi.encodePacked(sender), hex"c0ffee"
        );
        assertEq(b.heldOf(address(usdc), sender), 7e6);
        assertEq(b.heldTotal(address(usdc)), 7e6);
        assertEq(b.unattributedUsdc(), 0);
        assertEq(b.accruedFees(), 0);
        vm.prank(attacker);
        vm.expectRevert(SRNetBalance.NothingHeld.selector);
        b.claimHeld(address(usdc));
        vm.prank(owner);
        vm.expectRevert(SRNetBalance.NothingHeld.selector);
        b.claimHeld(address(usdc));
        vm.prank(sender);
        b.claimHeld(address(usdc));
        assertEq(usdc.balanceOf(sender), 7e6, "full amount back, no fee");
        assertEq(b.totalLiabilities(), 0);
    }

    /// srcAddress that is not exactly 20 bytes (e.g. a Solana/BTC source) or names a system address
    /// falls into the locked bucket.
    function test_unreadable_non_evm_or_system_src_goes_to_locked_bucket() public {
        bytes[4] memory srcs =
            [new bytes(32), new bytes(19), abi.encodePacked(address(b)), abi.encodePacked(address(vault))];
        for (uint256 i; i < srcs.length; ++i) {
            vault.executexSwapAndCall(
                MockCfVault.TransferParams(address(usdc), address(b), 1e6), 5, srcs[i], hex"00"
            );
        }
        assertEq(b.unattributedUsdc(), 4e6);
        assertEq(b.heldTotal(address(usdc)), 0);
    }

    function test_decodeCcmMessage_view_matches_cfReceive() public view {
        (bool ok, address who, uint256 fl) = b.decodeCcmMessage(_msgF(alice, 3e6));
        assertTrue(ok);
        assertEq(who, alice);
        assertEq(fl, 3e6);
        bytes[6] memory bad = _bad();
        for (uint256 i; i < bad.length; ++i) {
            (ok,,) = b.decodeCcmMessage(bad[i]);
            assertFalse(ok);
        }
    }

    function test_unreadable_other_token_with_evm_src_held() public {
        MockToken usdt = new MockToken("USDT", 6);
        usdt.mint(address(vault), 100e6);
        address sender = makeAddr("sender");
        vault.executexSwapAndCall(
            MockCfVault.TransferParams(address(usdt), address(b), 3e6), 5, abi.encodePacked(sender), hex"00"
        );
        assertEq(b.heldOf(address(usdt), sender), 3e6);
        vm.prank(owner);
        vm.expectRevert(SRNetBalance.ExceedsUntracked.selector);
        b.rescueToken(address(usdt), owner, 1);
        vm.prank(sender);
        b.claimHeld(address(usdt));
        assertEq(usdt.balanceOf(sender), 3e6);
    }

    function testFuzz_any_message_never_reverts_and_balances(bytes calldata m, uint256 amt, bool p) public {
        amt = bound(amt, 0, 1e12);
        if (p) {
            vm.prank(owner);
            b.setPaused(true);
        }
        _ccm(address(usdc), amt, m);
        address[] memory us = new address[](1);
        // the only possible beneficiary is whatever the message names
        us[0] = m.length >= 21 ? address(bytes20(m[1:21])) : address(0);
        assertEq(usdc.balanceOf(address(b)), _accounted(us));
    }

    function testFuzz_usdc_credit_exact(uint256 amt, uint64 f) public {
        amt = bound(amt, 1, 1e13);
        _ccm(address(usdc), amt, _msgF(alice, f));
        uint256 fl = f > 5e6 ? 5e6 : f;
        if (fl > amt) fl = amt;
        uint256 rest = amt - fl;
        uint256 fee = (rest * 300) / 10_000;
        assertEq(usdc.balanceOf(alice), fl);
        assertEq(b.availableOf(alice), rest - fee);
        assertEq(b.accruedFees(), fee);
        assertEq(usdc.balanceOf(address(b)), rest);
    }

    // ── pause ─────────────────────────────────────────────────────────────

    function test_paused_usdc_forwarded_to_wallet_fee_free() public {
        vm.prank(owner);
        b.setPaused(true);
        _ccm(address(usdc), 10e6, _msg(alice));
        assertEq(usdc.balanceOf(alice), 10e6);
        assertEq(b.availableOf(alice), 0);
        assertEq(b.accruedFees(), 0);
    }

    function test_paused_blacklisted_held_then_claimed() public {
        vm.prank(owner);
        b.setPaused(true);
        usdc.setBlocked(alice, true);
        _ccm(address(usdc), 10e6, _msg(alice));
        assertEq(b.heldOf(address(usdc), alice), 10e6);
        assertEq(b.heldTotal(address(usdc)), 10e6);
        // owner cannot touch it
        vm.prank(owner);
        vm.expectRevert(SRNetBalance.CannotRescueUsdc.selector);
        b.rescueToken(address(usdc), owner, 1);
        usdc.setBlocked(alice, false);
        vm.prank(alice);
        b.claimHeld(address(usdc));
        assertEq(usdc.balanceOf(alice), 10e6);
        assertEq(b.heldTotal(address(usdc)), 0);
        vm.prank(alice);
        vm.expectRevert(SRNetBalance.NothingHeld.selector);
        b.claimHeld(address(usdc));
    }

    // ── native and other tokens ───────────────────────────────────────────

    function test_native_forwarded_to_beneficiary() public {
        _ccm(NATIVE, 0.01 ether, _msg(alice));
        assertEq(alice.balance, 0.01 ether);
        assertEq(address(b).balance, 0);
    }

    function test_native_rejecting_or_gas_burning_receiver_is_held() public {
        EthSink sink = new EthSink();
        sink.setMode(1, address(0), "");
        _ccm(NATIVE, 1 ether, _msg(address(sink)));
        sink.setMode(2, address(0), "");
        _ccm(NATIVE, 1 ether, _msg(address(sink)));
        assertEq(b.heldOf(NATIVE, address(sink)), 2 ether);
        assertEq(address(b).balance, 2 ether);
        // owner may not rescue held native
        vm.prank(owner);
        vm.expectRevert(SRNetBalance.ExceedsUntracked.selector);
        b.rescueToken(NATIVE, owner, 1);
        sink.setMode(0, address(0), "");
        vm.prank(address(sink));
        b.claimHeld(NATIVE);
        assertEq(address(sink).balance, 2 ether);
    }

    function test_reentrant_receiver_cannot_reenter_guarded_paths() public {
        EthSink sink = new EthSink();
        sink.setMode(3, address(b), abi.encodeCall(SRNetBalance.claimHeld, (NATIVE)));
        _ccm(NATIVE, 1 ether, _msg(address(sink)));
        // push failed (re-entry into a nonReentrant function blocked) -> held, Vault call succeeded
        assertEq(b.heldOf(NATIVE, address(sink)), 1 ether);
        assertFalse(sink.reentryOk());
    }

    function test_native_unattributable_untracked_owner_rescuable() public {
        _ccm(NATIVE, 1 ether, hex"00");
        assertEq(address(b).balance, 1 ether);
        assertEq(b.heldTotal(NATIVE), 0);
        vm.prank(owner);
        b.rescueToken(NATIVE, owner, 1 ether);
        assertEq(owner.balance, 1 ether);
    }

    function test_other_token_forwarded_or_held() public {
        MockToken usdt = new MockToken("USDT", 6);
        usdt.mint(address(vault), 100e6);
        _ccm(address(usdt), 10e6, _msg(alice));
        assertEq(usdt.balanceOf(alice), 10e6);
        assertEq(b.availableOf(alice), 0, "non-USDC is never credited");

        NastyToken nasty = new NastyToken();
        nasty.mint(address(vault), 100e6);
        for (uint8 m = 1; m <= 4; ++m) {
            nasty.setMode(0); // the Vault's transfer in succeeds first
            vm.prank(address(vault));
            nasty.transfer(address(b), 1e6);
            nasty.setMode(m);
            vm.prank(address(vault));
            b.cfReceive(SRC_BTC, "", _msg(alice), address(nasty), 1e6);
        }
        assertEq(b.heldOf(address(nasty), alice), 4e6);
        // owner can rescue only the untracked part
        nasty.setMode(0);
        vm.prank(address(vault));
        nasty.transfer(address(b), 5e6); // stray, untracked
        vm.prank(owner);
        vm.expectRevert(SRNetBalance.ExceedsUntracked.selector);
        b.rescueToken(address(nasty), owner, 5e6 + 1);
        vm.prank(owner);
        b.rescueToken(address(nasty), owner, 5e6);
        vm.prank(alice);
        b.claimHeld(address(nasty));
        assertEq(nasty.balanceOf(alice), 4e6);
    }

    /// @dev Gas for gasBudget estimation: measured cfReceive executions (MockUSDC-like token).
    function test_gas_cfReceive_usdc_credit() public {
        _ccm(address(usdc), 1e6, _msg(makeAddr("warm"))); // warm accruedFees slot
        uint256 g = gasleft();
        vm.prank(address(vault));
        b.cfReceive(SRC_BTC, "", _msg(alice), address(usdc), 0); // amount 0 path
        uint256 g0 = g - gasleft();
        usdc.mint(address(b), 10e6);
        g = gasleft();
        vm.prank(address(vault));
        b.cfReceive(SRC_BTC, "", _msg(alice), address(usdc), 10e6);
        uint256 g1 = g - gasleft();
        usdc.mint(address(b), 10e6);
        g = gasleft();
        vm.prank(address(vault));
        b.cfReceive(SRC_BTC, "", _msgF(makeAddr("dave"), 1e6), address(usdc), 10e6);
        uint256 g2 = g - gasleft();
        emit log_named_uint("cfReceive amount=0", g0);
        emit log_named_uint("cfReceive USDC credit (new beneficiary)", g1);
        emit log_named_uint("cfReceive USDC credit + wallet float (new beneficiary)", g2);
        assertLt(g2, 120_000);
    }
}
