// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SRNetBalance} from "../src/SRNetBalance.sol";
import {CFV_STUB} from "./MockCfVault.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockToken, NoSymbolToken, ReentrantUSDC, FeeOnTransferUSDC} from "./Mocks.sol";

/// @dev Prepaid hourly leases. Test params: $20 per lease, 7-day max lease, 3% fee.
contract SRNetBalanceTest is Test {
    uint256 internal constant FUND = 100e6;
    uint256 internal constant FEE = 3e6;
    uint256 internal constant NET = 97e6;
    uint256 internal constant MAX_BUY = 20e6;
    uint256 internal constant MAX_HOURS = 168;
    uint256 internal constant HOUR = 1 hours;

    MockUSDC internal usdc;
    SRNetBalance internal balance;

    address internal user = makeAddr("user");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal owner = makeAddr("owner");
    address internal vendor = makeAddr("vendor");
    address internal vendor2 = makeAddr("vendor2");
    address internal anyone = makeAddr("anyone");
    bytes32 internal salt = keccak256("public-vendor-salt");
    bytes32 internal vendorId;

    function setUp() public {
        vm.etch(CFV_STUB, hex"00");
        usdc = new MockUSDC();
        balance = _deploy(address(usdc), 300);
        vendorId = keccak256(abi.encodePacked(vendor, salt));
        vm.prank(vendor);
        balance.configureVendor(vendorId, salt);
        usdc.mint(user, 1_000_000e6);
        vm.prank(user);
        usdc.approve(address(balance), type(uint256).max);
    }

    function _deploy(address t, uint256 bps) internal returns (SRNetBalance) {
        return new SRNetBalance(t, feeRecipient, owner, MAX_BUY, MAX_HOURS, bps, CFV_STUB, 1e6);
    }

    function _fund(uint256 amount) internal {
        vm.prank(user);
        balance.fund(amount);
    }

    /// @dev Lease `hrs` whole hours at `rate` USDC base units per hour.
    function _buy(uint256 rate, uint256 hrs) internal returns (uint256 id) {
        vm.prank(user);
        id = balance.startLease(vendorId, rate, hrs);
    }

    function _finalize(uint256 id) internal {
        (,,, uint256 start, uint256 dur,,,) = balance.leaseInfo(id);
        if (block.timestamp < start + dur) vm.warp(start + dur);
        balance.finalize(id);
    }

    // ── fund / fee ─────────────────────────────────────────────────────────

    function test_fund_fee_accrues_then_withdrawFees() public {
        _fund(FUND);
        assertEq(balance.accruedFees(), FEE);
        assertEq(balance.availableOf(user), NET);
        assertEq(usdc.balanceOf(address(balance)), FUND);
        vm.prank(anyone);
        balance.withdrawFees();
        assertEq(usdc.balanceOf(feeRecipient), FEE);
        assertEq(balance.accruedFees(), 0);
        vm.expectRevert(SRNetBalance.ZeroAmount.selector);
        balance.withdrawFees();
    }

    function test_fee_fixed_at_deploy() public {
        vm.expectRevert(SRNetBalance.FeeBpsTooHigh.selector);
        _deploy(address(usdc), 301);
        SRNetBalance free = _deploy(address(usdc), 0);
        vm.prank(user);
        usdc.approve(address(free), type(uint256).max);
        vm.prank(user);
        free.fund(10e6);
        assertEq(free.availableOf(user), 10e6);
        assertEq(balance.feeBps(), 300);
    }

    // ── leases ─────────────────────────────────────────────────────────────

    function test_full_run_pays_seller_whole_amount() public {
        _fund(FUND);
        uint256 id = _buy(5e6, 1);
        assertEq(balance.availableOf(user), NET - 5e6);
        assertEq(balance.lockedOf(user), 5e6);
        assertEq(balance.payableOf(vendor), 0);
        vm.expectRevert(SRNetBalance.LeaseNotOver.selector);
        balance.finalize(id);
        vm.warp(block.timestamp + HOUR);
        vm.prank(anyone);
        balance.finalize(id);
        assertEq(balance.payableOf(vendor), 5e6);
        assertEq(balance.lockedOf(user), 0);
        vm.expectRevert(SRNetBalance.LeaseNotOpen.selector);
        balance.finalize(id);
        vm.prank(vendor);
        balance.withdrawVendor();
        assertEq(usdc.balanceOf(vendor), 5e6);
    }

    function test_payment_final_buyer_cannot_cancel() public {
        _fund(FUND);
        uint256 id = _buy(6e6, 1);
        vm.prank(user);
        vm.expectRevert(SRNetBalance.NotLeaseSeller.selector);
        balance.cancel(id);
        vm.prank(anyone);
        vm.expectRevert(SRNetBalance.NotLeaseSeller.selector);
        balance.cancel(id);
        vm.prank(owner);
        vm.expectRevert(SRNetBalance.NotLeaseSeller.selector);
        balance.cancel(id);
        vm.expectRevert(SRNetBalance.LeaseNotOpen.selector);
        balance.cancel(999);
        // no cancelFor / buyer refund entry point exists
        (bool ok,) = address(balance).call(abi.encodeWithSignature("cancelFor((address,uint256,uint256,address,uint256,uint256),bytes)"));
        assertFalse(ok);
    }

    function test_one_hour_lease_seller_can_claim_immediately() public {
        _fund(FUND);
        uint256 id = _buy(6e6, 1);
        assertEq(balance.earned(id), 6e6, "the hour is earned when it begins");
        vm.prank(vendor);
        assertEq(balance.claimEarned(id), 6e6);
        vm.prank(vendor);
        balance.withdrawVendor();
        assertEq(usdc.balanceOf(vendor), 6e6);
        vm.warp(block.timestamp + HOUR);
        balance.finalize(id);
        assertEq(balance.lockedOf(user), 0);
        assertEq(balance.availableOf(user), NET - 6e6);
    }

    function test_whole_hour_accrual() public {
        _fund(FUND);
        uint256 t0 = block.timestamp;
        uint256 id = _buy(1e6, 5);
        assertEq(balance.earned(id), 1e6);
        vm.warp(t0 + HOUR - 1);
        assertEq(balance.earned(id), 1e6);
        vm.warp(t0 + HOUR);
        assertEq(balance.earned(id), 2e6);
        vm.warp(t0 + 4 * HOUR + 59 minutes);
        assertEq(balance.earned(id), 5e6);
        vm.warp(t0 + 9 * HOUR);
        assertEq(balance.earned(id), 5e6);
    }

    function test_seller_cancel_refunds_unused_whole_hours() public {
        _fund(FUND);
        uint256 t0 = block.timestamp;
        uint256 id = _buy(2e6, 5); // $10
        vm.warp(t0 + 90 minutes); // hours 1 and 2 begun
        vm.prank(vendor);
        balance.cancel(id);
        assertEq(balance.payableOf(vendor), 4e6);
        assertEq(balance.availableOf(user), NET - 4e6);
        assertEq(balance.lockedOf(user), 0);
        (,,,,,, uint256 endedAt, bool closed) = balance.leaseInfo(id);
        assertTrue(closed);
        assertEq(endedAt, t0 + 2 * HOUR, "paid through end of hour 2");
        (, bool stopped, uint256 paidUntil) = balance.leaseExtra(id);
        assertTrue(stopped);
        assertEq(paidUntil, t0 + 2 * HOUR);
        vm.prank(vendor);
        vm.expectRevert(SRNetBalance.LeaseNotOpen.selector);
        balance.cancel(id);
        vm.prank(user);
        vm.expectRevert(SRNetBalance.RenewNotAllowed.selector);
        balance.renewLease(id, 1);
    }

    function test_seller_cancel_after_end_equals_finalize() public {
        _fund(FUND);
        uint256 id = _buy(6e6, 1);
        vm.warp(block.timestamp + 2 * HOUR);
        vm.prank(vendor);
        balance.cancel(id);
        assertEq(balance.payableOf(vendor), 6e6);
        assertEq(balance.availableOf(user), NET - 6e6);
        (,,,,,, uint256 endedAt,) = balance.leaseInfo(id);
        assertEq(endedAt, block.timestamp - HOUR, "endedAt = scheduled end");
        (, bool stopped,) = balance.leaseExtra(id);
        assertFalse(stopped);
    }

    function test_seller_claims_mid_lease_then_close_settles_rest() public {
        _fund(FUND);
        uint256 t0 = block.timestamp;
        uint256 id = _buy(1e6, 6);
        vm.warp(t0 + 10 minutes);
        vm.prank(anyone);
        vm.expectRevert(SRNetBalance.NotLeaseSeller.selector);
        balance.claimEarned(id);
        vm.prank(vendor);
        assertEq(balance.claimEarned(id), 1e6);
        vm.prank(vendor);
        assertEq(balance.claimEarned(id), 0);
        vm.warp(t0 + 2 * HOUR + 5);
        assertEq(balance.earned(id), 3e6);
        vm.prank(vendor);
        balance.cancel(id);
        assertEq(balance.payableOf(vendor), 3e6);
        assertEq(balance.availableOf(user), NET - 3e6);
        assertEq(balance.earned(id), 3e6);
    }

    function test_renew_continues_at_prev_end_same_rate() public {
        _fund(FUND);
        uint256 t0 = block.timestamp;
        uint256 id = _buy(0.5e6, 1);
        vm.prank(user);
        vm.expectRevert(SRNetBalance.ZeroHours.selector);
        balance.renewLease(id, 0);
        vm.warp(t0 + 50 minutes);
        vm.prank(anyone);
        vm.expectRevert(SRNetBalance.NotLeaseBuyer.selector);
        balance.renewLease(id, 1);
        vm.prank(user);
        vm.expectRevert(SRNetBalance.LeaseNotOpen.selector);
        balance.renewLease(999, 1);
        vm.expectEmit(true, true, false, true, address(balance));
        emit SRNetBalance.LeaseRenewed(2, id, t0 + HOUR);
        vm.prank(user);
        uint256 id2 = balance.renewLease(id, 2);
        (uint256 rate, uint256 hrs) = balance.leaseTerms(id2);
        assertEq(rate, 0.5e6);
        assertEq(hrs, 2);
        (,, uint256 amt, uint256 start, uint256 dur,,,) = balance.leaseInfo(id2);
        assertEq(amt, 1e6);
        assertEq(start, t0 + HOUR);
        assertEq(dur, 2 * HOUR);
        assertEq(balance.earned(id2), 0, "nothing earned before it starts");
        (,,,, bool active) = balance.holdInfo(id2);
        assertTrue(active);
        // renewal of the renewal is too early (prev ends > 1h from now)
        vm.prank(user);
        vm.expectRevert(SRNetBalance.RenewTooEarly.selector);
        balance.renewLease(id2, 1);
        // seller stops the not-yet-started renewal: full refund, it was never served
        vm.prank(vendor);
        balance.cancel(id2);
        assertEq(balance.lockedOf(user), 0.5e6);
        (,,,,,, uint256 endedAt,) = balance.leaseInfo(id2);
        assertEq(endedAt, t0 + HOUR);
        assertEq(balance.payableOf(vendor), 0);
    }

    function test_renew_after_gap_starts_now_and_uses_current_wallet() public {
        _fund(FUND);
        uint256 id = _buy(1e6, 1);
        vm.warp(block.timestamp + 3 * HOUR);
        balance.finalize(id);
        // vendor rotates its payout wallet: the renewal pays the new wallet
        vm.prank(vendor);
        balance.changeVendorWallet(vendorId, vendor2);
        vm.prank(user);
        uint256 id2 = balance.renewLease(id, 1);
        (, address w,, uint256 start,,,,) = balance.leaseInfo(id2);
        assertEq(start, block.timestamp);
        assertEq(w, vendor2);
    }

    function test_holdInfo_view_tracks_lease() public {
        _fund(FUND);
        uint256 id = _buy(1e6, 1);
        (address u, uint256 amt, address w, uint256 deadline, bool active) = balance.holdInfo(id);
        assertEq(u, user);
        assertEq(amt, 1e6);
        assertEq(w, vendor);
        assertEq(deadline, block.timestamp + HOUR);
        assertTrue(active);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(vendor);
        balance.cancel(id);
        (,,, deadline, active) = balance.holdInfo(id);
        assertFalse(active);
        assertEq(deadline, block.timestamp - 10 minutes + HOUR, "paid through the begun hour");
        uint256 id2 = _buy(1e6, 1);
        vm.warp(block.timestamp + HOUR);
        (,,,, active) = balance.holdInfo(id2);
        assertFalse(active, "inactive after scheduled end even before finalize");
        (,,, deadline, active) = balance.holdInfo(999);
        assertEq(deadline, 0);
        assertFalse(active);
    }

    function test_hourly_pricing_amount_and_terms() public {
        _fund(FUND);
        vm.expectEmit(true, true, false, true, address(balance));
        emit SRNetBalance.LeaseStarted(1, user, 0.5e6, 6, 3e6);
        uint256 id = _buy(0.5e6, 6); // $0.50/h x 6 h = $3
        assertEq(balance.lockedOf(user), 3e6);
        (uint256 rate, uint256 hrs) = balance.leaseTerms(id);
        assertEq(rate, 0.5e6);
        assertEq(hrs, 6);
        (,,,, uint256 dur,,,) = balance.leaseInfo(id);
        assertEq(dur, 6 hours);
        vm.warp(block.timestamp + 90 minutes);
        assertEq(balance.earned(id), 1e6); // 2 hours begun x $0.50
        vm.prank(user);
        vm.expectRevert(SRNetBalance.LeaseTooLarge.selector);
        balance.startLease(vendorId, 5e6, 5); // $25 > $20 cap
        vm.prank(user);
        vm.expectRevert(SRNetBalance.LeaseTooLarge.selector);
        balance.startLease(vendorId, type(uint256).max, 2); // no overflow
    }

    function test_per_lease_cap_20_usd() public {
        _fund(FUND);
        vm.prank(user);
        vm.expectRevert(SRNetBalance.LeaseTooLarge.selector);
        balance.startLease(vendorId, MAX_BUY + 1, 1);
        _buy(MAX_BUY, 1);
        _buy(MAX_BUY, 1); // cap is per lease
        assertEq(balance.lockedOf(user), 2 * MAX_BUY);
    }

    function test_lease_input_checks() public {
        _fund(10e6);
        vm.startPrank(user);
        vm.expectRevert(SRNetBalance.ZeroRate.selector);
        balance.startLease(vendorId, 0, 1);
        vm.expectRevert(SRNetBalance.ZeroHours.selector);
        balance.startLease(vendorId, 1e6, 0);
        vm.expectRevert(SRNetBalance.ZeroRate.selector);
        balance.startLease(vendorId, 0, 1);
        vm.expectRevert(SRNetBalance.TooManyHours.selector);
        balance.startLease(vendorId, 1e6, MAX_HOURS + 1);
        vm.expectRevert(SRNetBalance.VendorNotConfigured.selector);
        balance.startLease(bytes32(uint256(1)), 1e6, 1);
        vm.expectRevert(SRNetBalance.InsufficientAvailable.selector);
        balance.startLease(vendorId, 10e6, 1);
        vm.stopPrank();
    }

    function test_seller_event_does_not_name_buyer() public {
        _fund(FUND);
        uint256 id = _buy(4e6, 1);
        vm.warp(block.timestamp + HOUR);
        vm.recordLogs();
        balance.finalize(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 credited = keccak256("PayableCredited(address,uint256,uint256)");
        bool saw;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == credited) {
                saw = true;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(vendor))));
                assertEq(logs[i].topics[2], bytes32(id));
                for (uint256 k; k < logs[i].topics.length; ++k) {
                    assertTrue(logs[i].topics[k] != bytes32(uint256(uint160(user))));
                }
            }
        }
        assertTrue(saw);
    }

    // ── vendors ────────────────────────────────────────────────────────────

    function test_vendor_config_rules() public {
        vm.prank(vendor2);
        vm.expectRevert(SRNetBalance.VendorIdMismatch.selector);
        balance.configureVendor(vendorId, salt);
        vm.prank(vendor);
        vm.expectRevert(SRNetBalance.VendorAlreadyConfigured.selector);
        balance.configureVendor(vendorId, salt);
        vm.prank(anyone);
        vm.expectRevert(SRNetBalance.NotVendorWallet.selector);
        balance.changeVendorWallet(vendorId, anyone);
        vm.prank(vendor);
        vm.expectRevert(SRNetBalance.SameWallet.selector);
        balance.changeVendorWallet(vendorId, vendor);
    }

    function test_vendor_rotate_affects_future_purchases_only() public {
        _fund(FUND);
        uint256 a = _buy(6e6, 1);
        vm.prank(vendor);
        balance.changeVendorWallet(vendorId, vendor2);
        uint256 c = _buy(2e6, 1);
        _finalize(a);
        _finalize(c);
        assertEq(balance.payableOf(vendor), 6e6);
        assertEq(balance.payableOf(vendor2), 2e6);
        vm.prank(vendor);
        balance.withdrawVendor();
        assertEq(usdc.balanceOf(vendor), 6e6);
    }

    function test_withdrawVendor_nothing_reverts() public {
        vm.prank(vendor);
        vm.expectRevert(SRNetBalance.InsufficientPayable.selector);
        balance.withdrawVendor();
    }

    // ── cash out ───────────────────────────────────────────────────────────

    function test_cashOut_unused_only() public {
        _fund(FUND);
        _finalize(_buy(7e6, 1));
        vm.startPrank(user);
        vm.expectRevert(SRNetBalance.ZeroAmount.selector);
        balance.cashOut(0);
        vm.expectRevert(SRNetBalance.InsufficientAvailable.selector);
        balance.cashOut(NET - 7e6 + 1);
        uint256 before = usdc.balanceOf(user);
        balance.cashOut(NET - 7e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(user) - before, NET - 7e6);
        assertEq(balance.payableOf(vendor), 7e6, "finished lease stays with seller");
    }

    // ── constructor / token ────────────────────────────────────────────────

    function test_ctor_validation() public {
        vm.expectRevert(SRNetBalance.ZeroAddress.selector);
        new SRNetBalance(address(0), feeRecipient, owner, MAX_BUY, MAX_HOURS, 300, CFV_STUB, 1e6);
        vm.expectRevert(SRNetBalance.ZeroAddress.selector);
        new SRNetBalance(address(usdc), address(0), owner, MAX_BUY, MAX_HOURS, 300, CFV_STUB, 1e6);
        vm.expectRevert(SRNetBalance.ZeroAddress.selector);
        new SRNetBalance(address(usdc), feeRecipient, address(0), MAX_BUY, MAX_HOURS, 300, CFV_STUB, 1e6);
        vm.expectRevert(SRNetBalance.BadToken.selector);
        _deploy(makeAddr("eoa"), 300);
        vm.expectRevert(SRNetBalance.BadToken.selector);
        _deploy(address(new MockToken("USDC", 18)), 300);
        vm.expectRevert(SRNetBalance.BadToken.selector);
        _deploy(address(new MockToken("DAI", 6)), 300);
        vm.expectRevert(SRNetBalance.BadToken.selector);
        _deploy(address(new NoSymbolToken()), 300);
        vm.expectRevert(SRNetBalance.BadDeployCap.selector);
        new SRNetBalance(address(usdc), feeRecipient, owner, 0, MAX_HOURS, 300, CFV_STUB, 1e6);
        vm.expectRevert(SRNetBalance.BadDeployCap.selector);
        new SRNetBalance(address(usdc), feeRecipient, owner, MAX_BUY, 0, 300, CFV_STUB, 1e6);
        vm.expectRevert(SRNetBalance.BadDeployCap.selector);
        new SRNetBalance(address(usdc), feeRecipient, owner, MAX_BUY, 721, 300, CFV_STUB, 1e6);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(SRNetBalance.FeeRecipientIsSelf.selector);
        new SRNetBalance(address(usdc), predicted, owner, MAX_BUY, MAX_HOURS, 300, CFV_STUB, 1e6);
        assertEq(balance.token(), address(usdc));
        assertEq(balance.maxPerLease(), MAX_BUY);
        assertEq(balance.maxLeaseHours(), MAX_HOURS);
    }

    function test_fee_on_transfer_token_rejected() public {
        FeeOnTransferUSDC fot = new FeeOnTransferUSDC();
        SRNetBalance b = _deploy(address(fot), 300);
        fot.mint(user, 10e6);
        vm.prank(user);
        fot.approve(address(b), type(uint256).max);
        vm.prank(user);
        vm.expectRevert(SRNetBalance.TransferAmountMismatch.selector);
        b.fund(10e6);
    }

    function test_eth_rejected() public {
        vm.deal(anyone, 1 ether);
        vm.prank(anyone);
        (bool ok,) = address(balance).call{value: 1}("");
        assertFalse(ok);
        vm.prank(anyone);
        (ok,) = address(balance).call(abi.encodeWithSignature("resolveDispute(uint256,bool)", 1, true));
        assertFalse(ok, "no judge entry point exists");
    }

    // ── pause ──────────────────────────────────────────────────────────────

    function test_pause_blocks_fund_and_new_leases_only() public {
        _fund(FUND);
        uint256 a = _buy(5e6, 1);
        uint256 c = _buy(5e6, 1);
        uint256 d = _buy(5e6, 1);
        vm.prank(owner);
        balance.setPaused(true);
        vm.prank(user);
        vm.expectRevert(SRNetBalance.Paused.selector);
        balance.fund(1e6);
        vm.prank(user);
        vm.expectRevert(SRNetBalance.Paused.selector);
        balance.startLease(vendorId, 1e6, 1);
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(user);
        vm.expectRevert(SRNetBalance.Paused.selector);
        balance.renewLease(a, 1);
        vm.prank(vendor);
        balance.cancel(a); // seller cancel while paused
        vm.prank(vendor);
        balance.claimEarned(c); // seller claim while paused
        vm.warp(block.timestamp + 30 minutes);
        balance.finalize(c);
        vm.prank(vendor);
        balance.cancel(d); // seller cancel (after end) while paused
        vm.prank(vendor);
        balance.withdrawVendor();
        uint256 avail = balance.availableOf(user);
        vm.prank(user);
        balance.cashOut(avail);
        balance.withdrawFees();
        assertEq(usdc.balanceOf(address(balance)), 0, "everything withdrawable while paused");
        vm.prank(owner);
        balance.setPaused(false);
        _fund(1e6);
    }

    // ── owner admin ────────────────────────────────────────────────────────

    function test_two_step_ownership() public {
        address next = makeAddr("next");
        vm.prank(anyone);
        vm.expectRevert(SRNetBalance.NotOwner.selector);
        balance.transferOwnership(next);
        vm.prank(owner);
        balance.transferOwnership(next);
        vm.prank(anyone);
        vm.expectRevert(SRNetBalance.NotPendingOwner.selector);
        balance.acceptOwnership();
        vm.prank(owner);
        balance.transferOwnership(address(0)); // cancel
        vm.prank(next);
        vm.expectRevert(SRNetBalance.NotPendingOwner.selector);
        balance.acceptOwnership();
        vm.prank(owner);
        balance.transferOwnership(next);
        vm.prank(next);
        balance.acceptOwnership();
        assertEq(balance.owner(), next);
        assertEq(balance.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(SRNetBalance.NotOwner.selector);
        balance.setPaused(true);
    }

    function test_fee_recipient_change() public {
        address nf = makeAddr("newFee");
        vm.prank(anyone);
        vm.expectRevert(SRNetBalance.NotOwner.selector);
        balance.setFeeRecipient(nf);
        vm.startPrank(owner);
        vm.expectRevert(SRNetBalance.ZeroAddress.selector);
        balance.setFeeRecipient(address(0));
        vm.expectRevert(SRNetBalance.FeeRecipientIsSelf.selector);
        balance.setFeeRecipient(address(balance));
        vm.expectEmit(true, true, false, false, address(balance));
        emit SRNetBalance.FeeRecipientUpdated(feeRecipient, nf);
        balance.setFeeRecipient(nf);
        vm.stopPrank();
        _fund(FUND);
        balance.withdrawFees();
        assertEq(usdc.balanceOf(nf), FEE);
    }

    function test_rescue_non_usdc_only() public {
        _fund(FUND);
        MockToken dai = new MockToken("DAI", 18);
        dai.mint(address(balance), 5e18);
        vm.prank(anyone);
        vm.expectRevert(SRNetBalance.NotOwner.selector);
        balance.rescueToken(address(dai), anyone, 5e18);
        vm.startPrank(owner);
        vm.expectRevert(SRNetBalance.CannotRescueUsdc.selector);
        balance.rescueToken(address(usdc), owner, 1);
        vm.expectRevert(SRNetBalance.ZeroAddress.selector);
        balance.rescueToken(address(dai), address(0), 1);
        balance.rescueToken(address(dai), anyone, 5e18);
        vm.stopPrank();
        assertEq(dai.balanceOf(anyone), 5e18);
        assertEq(usdc.balanceOf(address(balance)), FUND);
    }

    // ── reentrancy (malicious "USDC" calls back during transfer) ───────────

    function _reentrant() internal returns (ReentrantUSDC t, SRNetBalance b) {
        t = new ReentrantUSDC();
        b = _deploy(address(t), 300);
        t.mint(user, 100e6);
        vm.prank(user);
        t.approve(address(b), type(uint256).max);
    }

    function test_reentrancy_fund_into_cashOut_blocked() public {
        (ReentrantUSDC t, SRNetBalance b) = _reentrant();
        t.arm(address(b), abi.encodeCall(SRNetBalance.cashOut, (1)));
        vm.prank(user);
        vm.expectRevert(SRNetBalance.Reentered.selector);
        b.fund(10e6);
    }

    function test_reentrancy_cashOut_into_cashOut_blocked() public {
        (ReentrantUSDC t, SRNetBalance b) = _reentrant();
        vm.prank(user);
        b.fund(10e6);
        t.arm(address(b), abi.encodeCall(SRNetBalance.cashOut, (1)));
        vm.prank(user);
        vm.expectRevert(SRNetBalance.Reentered.selector);
        b.cashOut(1e6);
    }

    function test_reentrancy_withdrawFees_into_withdrawVendor_blocked() public {
        (ReentrantUSDC t, SRNetBalance b) = _reentrant();
        vm.prank(user);
        b.fund(10e6);
        t.arm(address(b), abi.encodeCall(SRNetBalance.withdrawVendor, ()));
        vm.expectRevert(SRNetBalance.Reentered.selector);
        b.withdrawFees();
    }

    // ── fuzz ───────────────────────────────────────────────────────────────

    function testFuzz_fund_fee_math(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);
        _fund(amount);
        uint256 fee = amount * 300 / 10_000;
        assertEq(balance.accruedFees(), fee);
        assertEq(balance.availableOf(user), amount - fee);
    }

    /// @dev Seller cancel at any time with mid-lease claims: shares add up exactly, seller keeps
    ///      rate * hours begun, buyer gets every unused whole hour.
    function testFuzz_seller_cancel_any_time_exact_split(
        uint256 amount,
        uint256 duration,
        uint256 claimAt,
        uint256 cancelAt
    ) public {
        uint256 hrs = bound(duration, 1, MAX_HOURS);
        uint256 rate = bound(amount, 1, MAX_BUY / hrs == 0 ? 1 : MAX_BUY / hrs);
        if (rate * hrs > MAX_BUY) hrs = 1;
        amount = rate * hrs;
        duration = hrs * 1 hours;
        cancelAt = bound(cancelAt, 0, duration * 2);
        claimAt = bound(claimAt, 0, cancelAt);
        _fund(FUND);
        uint256 t0 = block.timestamp;
        uint256 id = _buy(rate, hrs);
        vm.warp(t0 + claimAt);
        vm.prank(vendor);
        balance.claimEarned(id);
        vm.warp(t0 + cancelAt);
        vm.prank(vendor);
        balance.cancel(id);
        uint256 begun = cancelAt / 1 hours + 1;
        uint256 e = begun >= hrs ? amount : rate * begun;
        assertEq(balance.payableOf(vendor), e);
        assertEq(balance.availableOf(user), NET - e);
        assertEq(balance.lockedOf(user), 0);
        assertEq(usdc.balanceOf(address(balance)), balance.availableOf(user) + balance.payableOf(vendor) + FEE);
    }

    function testFuzz_earned_monotonic(uint256 amount, uint256 duration, uint256 t1, uint256 t2) public {
        uint256 hrs = bound(duration, 1, 20);
        uint256 rate = bound(amount, 1, MAX_BUY / hrs);
        amount = rate * hrs;
        duration = hrs * 1 hours;
        t1 = bound(t1, 0, duration * 2);
        t2 = bound(t2, t1, duration * 2);
        _fund(FUND);
        uint256 t0 = block.timestamp;
        uint256 id = _buy(rate, hrs);
        vm.warp(t0 + t1);
        uint256 e1 = balance.earned(id);
        vm.warp(t0 + t2);
        uint256 e2 = balance.earned(id);
        assertLe(e1, e2);
        assertLe(e2, amount);
    }
}
