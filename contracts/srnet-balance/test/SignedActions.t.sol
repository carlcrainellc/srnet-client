// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SRNetBalance} from "../src/SRNetBalance.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {ReentrantUSDC} from "./Mocks.sol";
import {MockCfVault} from "./MockCfVault.sol";

/// @dev Gasless EIP-712 actions: the buyer never needs ETH. Anyone relays and is paid in USDC.
contract SignedActionsTest is Test {
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    MockUSDC internal usdc;
    MockCfVault internal vault;
    SRNetBalance internal b;
    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("fee");
    address internal buyer;
    uint256 internal buyerKey;
    address internal seller;
    uint256 internal sellerKey;
    address internal relayer = makeAddr("relayer");
    bytes32 internal vid;

    function setUp() public {
        (buyer, buyerKey) = makeAddrAndKey("buyer");
        (seller, sellerKey) = makeAddrAndKey("seller");
        usdc = new MockUSDC();
        vault = new MockCfVault();
        b = new SRNetBalance(address(usdc), feeRecipient, owner, 20e6, 168, 300, address(vault), 1e6);
        bytes32 salt = bytes32(uint256(1));
        vid = keccak256(abi.encodePacked(seller, salt));
        vm.prank(seller);
        b.configureVendor(vid, salt);
        // buyer is funded via CCM only: holds no ETH and no wallet USDC
        usdc.mint(address(vault), 1e12);
        vault.executexSwapAndCall(
            MockCfVault.TransferParams(address(usdc), address(b), 100e6), 3, "", abi.encodePacked(uint8(1), buyer)
        );
        assertEq(buyer.balance, 0);
        assertEq(b.availableOf(buyer), 97e6);
    }

    // ── signing helpers (independent EIP-712 implementation) ─────────────

    function _domain(address c) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SRNetBalance"),
                keccak256("1"),
                block.chainid,
                c
            )
        );
    }

    function _sign(uint256 key, address c, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(c), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _startAuth(uint256 rate, uint256 hrs, uint256 fee, address rel, uint256 nonce)
        internal
        view
        returns (SRNetBalance.StartLeaseAuth memory)
    {
        return SRNetBalance.StartLeaseAuth(buyer, vid, rate, hrs, fee, rel, nonce, block.timestamp + 10 minutes);
    }

    function _hStart(SRNetBalance.StartLeaseAuth memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "StartLease(address buyer,bytes32 vendorId,uint256 ratePerHour,uint256 hoursBought,uint256 relayFee,address relayer,uint256 nonce,uint256 deadline)"
                ),
                a.buyer,
                a.vendorId,
                a.ratePerHour,
                a.hoursBought,
                a.relayFee,
                a.relayer,
                a.nonce,
                a.deadline
            )
        );
    }

    function _hRenew(SRNetBalance.RenewAuth memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "Renew(address buyer,uint256 prevLeaseId,uint256 hoursBought,uint256 relayFee,address relayer,uint256 nonce,uint256 deadline)"
                ),
                a.buyer,
                a.prevLeaseId,
                a.hoursBought,
                a.relayFee,
                a.relayer,
                a.nonce,
                a.deadline
            )
        );
    }

    function _hCash(SRNetBalance.WithdrawAuth memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "Withdraw(address user,uint256 amount,address to,uint256 relayFee,address relayer,uint256 nonce,uint256 deadline)"
                ),
                a.user,
                a.amount,
                a.to,
                a.relayFee,
                a.relayer,
                a.nonce,
                a.deadline
            )
        );
    }

    function _relayStart(SRNetBalance.StartLeaseAuth memory a) internal returns (uint256 id) {
        bytes memory sig = _sign(buyerKey, address(b), _hStart(a));
        vm.prank(relayer);
        id = b.startLeaseFor(a, sig);
    }

    // ── tests ─────────────────────────────────────────────────────────────

    function test_domain_and_typehashes_match_spec() public view {
        assertEq(b.DOMAIN_SEPARATOR(), _domain(address(b)));
        SRNetBalance.StartLeaseAuth memory a = _startAuth(1e6, 2, 0.05e6, address(0), 1);
        assertEq(b.hashTypedData(_hStart(a)), keccak256(abi.encodePacked("\x19\x01", _domain(address(b)), _hStart(a))));
    }

    function test_start_renew_withdraw_all_gasless() public {
        uint256 t0 = block.timestamp;
        // start: relayer (could be the seller's watcher) earns 0.05 USDC
        uint256 id = _relayStart(_startAuth(1e6, 1, 0.05e6, address(0), 1));
        assertEq(b.lockedOf(buyer), 1e6);
        assertEq(b.availableOf(buyer), 97e6 - 1e6 - 0.05e6);
        assertEq(b.payableOf(relayer), 0.05e6);

        // renew hourly in the last 10 minutes, gasless
        vm.warp(t0 + 50 minutes);
        SRNetBalance.RenewAuth memory r =
            SRNetBalance.RenewAuth(buyer, id, 1, 0.03e6, address(0), 2, block.timestamp + 10 minutes);
        bytes memory rs = _sign(buyerKey, address(b), _hRenew(r));
        vm.prank(relayer);
        uint256 id2 = b.renewFor(r, rs);
        (,,, uint256 start,,,,) = b.leaseInfo(id2);
        assertEq(start, t0 + 1 hours);
        assertEq(b.lockedOf(buyer), 2e6);
        assertEq(b.availableOf(buyer), 97e6 - 2e6 - 0.05e6 - 0.03e6);
        vm.prank(relayer);
        vm.expectRevert(SRNetBalance.NonceAlreadyUsed.selector);
        b.renewFor(r, rs);

        vm.warp(t0 + 2 hours);
        b.finalize(id);
        b.finalize(id2);
        assertEq(b.payableOf(seller), 2e6);

        // withdraw to an exchange deposit address, fee on top
        address exch = makeAddr("exchange");
        uint256 avail = b.availableOf(buyer);
        SRNetBalance.WithdrawAuth memory o =
            SRNetBalance.WithdrawAuth(buyer, avail - 0.04e6, exch, 0.04e6, address(0), 3, block.timestamp + 10 minutes);
        bytes memory os = _sign(buyerKey, address(b), _hCash(o));
        vm.prank(relayer);
        b.withdrawFor(o, os);
        assertEq(usdc.balanceOf(exch), avail - 0.04e6);
        assertEq(b.availableOf(buyer), 0);
        assertEq(b.payableOf(relayer), 0.12e6);
        vm.prank(relayer);
        b.withdrawVendor();
        assertEq(usdc.balanceOf(relayer), 0.12e6);
        assertEq(buyer.balance, 0, "buyer never held ETH");
    }

    function test_no_cancelFor_exists() public {
        (bool ok,) = address(b).call(
            abi.encodeWithSignature("cancelFor((address,uint256,uint256,address,uint256,uint256),bytes)")
        );
        assertFalse(ok);
        (ok,) = address(b).call(abi.encodeWithSignature("CANCEL_TYPEHASH()"));
        assertFalse(ok);
    }

    function test_replay_blocked_same_nonce_any_action() public {
        SRNetBalance.StartLeaseAuth memory a = _startAuth(1e6, 1, 0, address(0), 7);
        bytes memory sig = _sign(buyerKey, address(b), _hStart(a));
        b.startLeaseFor(a, sig);
        vm.expectRevert(SRNetBalance.NonceAlreadyUsed.selector);
        b.startLeaseFor(a, sig);
        // a different action reusing nonce 7 is also dead
        SRNetBalance.WithdrawAuth memory o =
            SRNetBalance.WithdrawAuth(buyer, 1e6, buyer, 0, address(0), 7, block.timestamp + 1 hours);
        bytes memory os = _sign(buyerKey, address(b), _hCash(o));
        vm.expectRevert(SRNetBalance.NonceAlreadyUsed.selector);
        b.withdrawFor(o, os);
    }

    function test_unordered_nonces_work_out_of_order() public {
        SRNetBalance.StartLeaseAuth memory a5 = _startAuth(1e6, 1, 0, address(0), 5);
        SRNetBalance.StartLeaseAuth memory a2 = _startAuth(1e6, 1, 0, address(0), 2);
        b.startLeaseFor(a5, _sign(buyerKey, address(b), _hStart(a5)));
        b.startLeaseFor(a2, _sign(buyerKey, address(b), _hStart(a2)));
        assertEq(b.nextLeaseId(), 2);
    }

    function test_deadline_enforced() public {
        SRNetBalance.StartLeaseAuth memory a = _startAuth(1e6, 1, 0, address(0), 1);
        bytes memory sig = _sign(buyerKey, address(b), _hStart(a));
        vm.warp(a.deadline + 1);
        vm.expectRevert(SRNetBalance.SignatureExpired.selector);
        b.startLeaseFor(a, sig);
    }

    function test_relay_fee_cap_enforced() public {
        SRNetBalance.StartLeaseAuth memory a = _startAuth(1e6, 1, 1e6 + 1, address(0), 1);
        bytes memory sig = _sign(buyerKey, address(b), _hStart(a));
        vm.expectRevert(SRNetBalance.RelayFeeTooHigh.selector);
        b.startLeaseFor(a, sig);
    }

    function test_pinned_relayer() public {
        SRNetBalance.StartLeaseAuth memory a = _startAuth(1e6, 1, 0.1e6, seller, 1);
        bytes memory sig = _sign(buyerKey, address(b), _hStart(a));
        vm.prank(relayer);
        vm.expectRevert(SRNetBalance.WrongRelayer.selector);
        b.startLeaseFor(a, sig);
        vm.prank(seller);
        b.startLeaseFor(a, sig);
        assertEq(b.payableOf(seller), 0.1e6);
    }

    function test_tampered_fields_rejected() public {
        SRNetBalance.StartLeaseAuth memory a = _startAuth(1e6, 1, 0.05e6, address(0), 1);
        bytes memory sig = _sign(buyerKey, address(b), _hStart(a));
        a.hoursBought = 2;
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.startLeaseFor(a, sig);
        a.hoursBought = 1;
        a.relayFee = 0.06e6;
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.startLeaseFor(a, sig);
        a.relayFee = 0.05e6;
        a.buyer = seller; // claim someone else's balance
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.startLeaseFor(a, sig);
    }

    function test_wrong_key_rejected() public {
        SRNetBalance.WithdrawAuth memory o =
            SRNetBalance.WithdrawAuth(buyer, 10e6, relayer, 0, address(0), 1, block.timestamp + 1 hours);
        (, uint256 evilKey) = makeAddrAndKey("evil");
        bytes memory sig = _sign(evilKey, address(b), _hCash(o));
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.withdrawFor(o, sig);
    }

    function test_malleable_and_malformed_signatures_rejected() public {
        SRNetBalance.StartLeaseAuth memory a = _startAuth(1e6, 1, 0, address(0), 1);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(address(b)), _hStart(a)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerKey, digest);
        bytes memory high = abi.encodePacked(r, bytes32(N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.startLeaseFor(a, high);
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.startLeaseFor(a, abi.encodePacked(r, s, uint8(v - 27))); // v = 0/1
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.startLeaseFor(a, abi.encodePacked(r, s)); // 64 bytes
        b.startLeaseFor(a, abi.encodePacked(r, s, v)); // canonical works
    }

    function test_cross_contract_and_cross_chain_replay_blocked() public {
        SRNetBalance other = new SRNetBalance(address(usdc), feeRecipient, owner, 20e6, 168, 300, address(vault), 1e6);
        SRNetBalance.StartLeaseAuth memory a = _startAuth(1e6, 1, 0, address(0), 1);
        bytes memory sigOther = _sign(buyerKey, address(other), _hStart(a));
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.startLeaseFor(a, sigOther);
        bytes memory sig = _sign(buyerKey, address(b), _hStart(a));
        uint256 cid = block.chainid;
        vm.chainId(cid + 1);
        assertTrue(b.DOMAIN_SEPARATOR() != _domainAt(address(b), cid));
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.startLeaseFor(a, sig);
        vm.chainId(cid);
        b.startLeaseFor(a, sig);
    }

    function _domainAt(address c, uint256 cid) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SRNetBalance"),
                keccak256("1"),
                cid,
                c
            )
        );
    }

    function test_invalidate_nonce() public {
        SRNetBalance.StartLeaseAuth memory a = _startAuth(1e6, 1, 0, address(0), 9);
        bytes memory sig = _sign(buyerKey, address(b), _hStart(a));
        vm.prank(buyer);
        b.invalidateNonce(9);
        vm.expectRevert(SRNetBalance.NonceAlreadyUsed.selector);
        b.startLeaseFor(a, sig);
    }

    function test_renew_signed_only_by_buyer() public {
        uint256 id = _relayStart(_startAuth(1e6, 1, 0, address(0), 1));
        (address evil, uint256 evilKey) = makeAddrAndKey("evil");
        SRNetBalance.RenewAuth memory r =
            SRNetBalance.RenewAuth(evil, id, 1, 0, address(0), 2, block.timestamp + 1 hours);
        bytes memory es = _sign(evilKey, address(b), _hRenew(r));
        vm.expectRevert(SRNetBalance.NotLeaseBuyer.selector);
        b.renewFor(r, es);
        r.buyer = buyer; // evil's signature over buyer's fields
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.renewFor(r, _sign(evilKey, address(b), _hRenew(r)));
        b.renewFor(r, _sign(buyerKey, address(b), _hRenew(r)));
        assertEq(b.nextLeaseId(), 2);
    }

    function test_insufficient_for_fee_reverts_atomically() public {
        // lock almost everything, then try to pay a fee the buyer cannot cover
        SRNetBalance.WithdrawAuth memory o =
            SRNetBalance.WithdrawAuth(buyer, 97e6, buyer, 1, address(0), 1, block.timestamp + 1 hours);
        bytes memory os = _sign(buyerKey, address(b), _hCash(o));
        vm.expectRevert(SRNetBalance.InsufficientAvailable.selector);
        b.withdrawFor(o, os);
        assertEq(b.availableOf(buyer), 97e6);
        assertFalse(b.nonceUsed(buyer, 1), "nonce not burned on revert");
    }

    function test_pause_blocks_signed_start_and_renew_only() public {
        uint256 id = _relayStart(_startAuth(1e6, 2, 0, address(0), 1));
        vm.prank(owner);
        b.setPaused(true);
        SRNetBalance.StartLeaseAuth memory a = _startAuth(1e6, 1, 0, address(0), 2);
        bytes memory sig = _sign(buyerKey, address(b), _hStart(a));
        vm.expectRevert(SRNetBalance.Paused.selector);
        b.startLeaseFor(a, sig);
        SRNetBalance.RenewAuth memory c =
            SRNetBalance.RenewAuth(buyer, id, 1, 0, address(0), 3, block.timestamp + 1 hours);
        bytes memory rsig = _sign(buyerKey, address(b), _hRenew(c));
        vm.expectRevert(SRNetBalance.Paused.selector);
        b.renewFor(c, rsig);
        vm.prank(seller);
        b.cancel(id); // seller cancel still works
        SRNetBalance.WithdrawAuth memory o =
            SRNetBalance.WithdrawAuth(buyer, 1e6, buyer, 0, address(0), 4, block.timestamp + 1 hours);
        b.withdrawFor(o, _sign(buyerKey, address(b), _hCash(o)));
        assertEq(usdc.balanceOf(buyer), 1e6);
    }

    function test_owner_has_no_signed_power_over_users() public {
        // the owner key cannot sign for a user, and has no function that spends availableOf
        (, uint256 ownerKey) = makeAddrAndKey("owner");
        SRNetBalance.WithdrawAuth memory o =
            SRNetBalance.WithdrawAuth(buyer, 97e6, owner, 0, address(0), 1, block.timestamp + 1 hours);
        bytes memory sig = _sign(ownerKey, address(b), _hCash(o));
        vm.prank(owner);
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.withdrawFor(o, sig);
    }

    function testFuzz_signed_flow_conserves_usdc(uint256 rate, uint256 hrs, uint256 f1, uint256 f2, uint256 dt) public {
        hrs = bound(hrs, 1, 20);
        rate = bound(rate, 1, 20e6 / hrs);
        f1 = bound(f1, 0, 1e6);
        f2 = bound(f2, 0, 1e6);
        dt = bound(dt, hrs * 1 hours - 1 hours, hrs * 1 hours + 1 days);
        uint256 id = _relayStart(_startAuth(rate, hrs, f1, address(0), 1));
        vm.warp(block.timestamp + dt);
        SRNetBalance.RenewAuth memory c =
            SRNetBalance.RenewAuth(buyer, id, 1, f2, address(0), 2, block.timestamp + 1 hours);
        bytes memory cs = _sign(buyerKey, address(b), _hRenew(c));
        vm.prank(relayer);
        b.renewFor(c, cs);
        vm.prank(seller);
        b.cancel(id);
        uint256 sum =
            b.availableOf(buyer) + b.lockedOf(buyer) + b.payableOf(seller) + b.payableOf(relayer) + b.accruedFees();
        assertEq(usdc.balanceOf(address(b)), sum);
        assertEq(b.payableOf(relayer), f1 + f2);
    }

    function test_reentrancy_withdrawFor_blocked() public {
        ReentrantUSDC r = new ReentrantUSDC();
        SRNetBalance rb = new SRNetBalance(address(r), feeRecipient, owner, 20e6, 168, 300, address(vault), 1e6);
        r.mint(buyer, 10e6);
        vm.prank(buyer);
        r.approve(address(rb), type(uint256).max);
        vm.prank(buyer);
        rb.fund(10e6);
        SRNetBalance.WithdrawAuth memory o =
            SRNetBalance.WithdrawAuth(buyer, 1e6, buyer, 0, address(0), 1, block.timestamp + 1 hours);
        bytes memory sig = _sign(buyerKey, address(rb), _hCash(o));
        r.arm(address(rb), abi.encodeCall(SRNetBalance.cashOut, (1e6)));
        vm.expectRevert(SRNetBalance.Reentered.selector);
        rb.withdrawFor(o, sig);
    }

    function test_gas_signed_actions() public {
        SRNetBalance.StartLeaseAuth memory a = _startAuth(1e6, 2, 0.05e6, address(0), 1);
        bytes memory sig = _sign(buyerKey, address(b), _hStart(a));
        vm.prank(relayer);
        uint256 g = gasleft();
        uint256 id = b.startLeaseFor(a, sig);
        emit log_named_uint("startLeaseFor", g - gasleft());
        vm.warp(block.timestamp + 90 minutes);
        SRNetBalance.RenewAuth memory c =
            SRNetBalance.RenewAuth(buyer, id, 1, 0.03e6, address(0), 2, block.timestamp + 10 minutes);
        bytes memory cs = _sign(buyerKey, address(b), _hRenew(c));
        vm.prank(relayer);
        g = gasleft();
        b.renewFor(c, cs);
        emit log_named_uint("renewFor", g - gasleft());
        SRNetBalance.WithdrawAuth memory o =
            SRNetBalance.WithdrawAuth(buyer, 5e6, buyer, 0.04e6, address(0), 3, block.timestamp + 10 minutes);
        bytes memory os = _sign(buyerKey, address(b), _hCash(o));
        vm.prank(relayer);
        g = gasleft();
        b.withdrawFor(o, os);
        emit log_named_uint("withdrawFor", g - gasleft());
    }
}
