// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SRNetBalance} from "../src/SRNetBalance.sol";
import {CFV_STUB} from "./MockCfVault.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @notice Pre-release review tests: single renewal, fee math, lease accounting, buyer-refund paths.
contract AuditTest is Test {
    MockUSDC internal usdc;
    SRNetBalance internal b;
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal fees = makeAddr("fees");
    address internal owner = makeAddr("owner");
    bytes32 internal salt = keccak256("s");
    bytes32 internal vid;

    function setUp() public {
        vm.etch(CFV_STUB, hex"00");
        usdc = new MockUSDC();
        b = new SRNetBalance(address(usdc), fees, owner, 20e6, 168, 300, CFV_STUB, 1e6);
        vid = keccak256(abi.encodePacked(seller, salt));
        vm.prank(seller);
        b.configureVendor(vid, salt);
        usdc.mint(buyer, type(uint96).max);
        vm.prank(buyer);
        usdc.approve(address(b), type(uint256).max);
    }

    function _fund(uint256 a) internal {
        vm.prank(buyer);
        b.fund(a);
    }

    function test_renew_only_once_per_lease() public {
        _fund(100e6);
        vm.prank(buyer);
        uint256 id = b.startLease(vid, 1e6, 1);
        vm.warp(block.timestamp + 50 minutes);
        vm.prank(buyer);
        uint256 id2 = b.renewLease(id, 1);
        assertEq(b.renewedBy(id), id2);
        vm.prank(buyer);
        vm.expectRevert(SRNetBalance.AlreadyRenewed.selector);
        b.renewLease(id, 1);
        // the chain continues from the new lease
        vm.warp(block.timestamp + 1 hours);
        vm.prank(buyer);
        b.renewLease(id2, 1);
    }

    function test_buyer_cannot_cancel_or_finalize_early() public {
        _fund(10e6);
        vm.prank(buyer);
        uint256 id = b.startLease(vid, 2e6, 3);
        vm.prank(buyer);
        vm.expectRevert(SRNetBalance.NotLeaseSeller.selector);
        b.cancel(id);
        vm.prank(buyer);
        vm.expectRevert(SRNetBalance.LeaseNotOver.selector);
        b.finalize(id);
        vm.prank(buyer);
        vm.expectRevert(SRNetBalance.NotLeaseSeller.selector);
        b.claimEarned(id);
        // locked money is not available for cashOut
        uint256 avail = b.availableOf(buyer);
        vm.prank(buyer);
        vm.expectRevert(SRNetBalance.InsufficientAvailable.selector);
        b.cashOut(avail + 1);
    }

    function testFuzz_fee_math(uint256 amt) public {
        amt = bound(amt, 1, type(uint96).max);
        _fund(amt);
        uint256 fee = b.accruedFees();
        assertEq(fee + b.availableOf(buyer), amt);
        assertLe(fee * 10_000, amt * 300);
        assertEq(b.totalLiabilities(), usdc.balanceOf(address(b)));
    }

    /// Seller stop at any time: seller + buyer shares equal the lease amount, seller gets whole begun hours only.
    function testFuzz_cancel_split(uint256 rate, uint256 hrs, uint256 dt) public {
        hrs = bound(hrs, 1, 20);
        rate = bound(rate, 1, 20e6 / hrs);
        dt = bound(dt, 0, hrs * 3600 + 7200);
        _fund(30e6);
        uint256 avail0 = b.availableOf(buyer);
        vm.prank(buyer);
        uint256 id = b.startLease(vid, rate, hrs);
        vm.warp(block.timestamp + dt);
        vm.prank(seller);
        b.cancel(id);
        uint256 toSeller = b.payableOf(seller);
        uint256 begun = dt / 3600 + 1;
        if (begun > hrs) begun = hrs;
        assertEq(toSeller, rate * begun);
        assertEq(b.availableOf(buyer) + toSeller, avail0);
        assertEq(b.lockedOf(buyer), 0);
    }

    /// claimEarned is monotone and never exceeds the lease amount; finalize settles the rest exactly once.
    function testFuzz_claim_then_finalize(uint256 rate, uint256 hrs, uint256 t1, uint256 t2) public {
        hrs = bound(hrs, 1, 20);
        rate = bound(rate, 1, 20e6 / hrs);
        t1 = bound(t1, 0, hrs * 3600);
        t2 = bound(t2, t1, hrs * 3600 * 2);
        _fund(30e6);
        vm.prank(buyer);
        uint256 id = b.startLease(vid, rate, hrs);
        uint256 s = block.timestamp;
        vm.warp(s + t1);
        vm.prank(seller);
        uint256 c1 = b.claimEarned(id);
        vm.warp(s + t2);
        if (s + t2 < s + hrs * 3600) {
            vm.prank(seller);
            b.claimEarned(id);
        } else {
            b.finalize(id);
            vm.expectRevert(SRNetBalance.LeaseNotOpen.selector);
            b.finalize(id);
        }
        assertGe(b.payableOf(seller), c1);
        assertLe(b.payableOf(seller), rate * hrs);
        assertEq(b.payableOf(seller) + b.lockedOf(buyer), rate * hrs);
    }

    /// Changing the payout wallet does not redirect an open lease; new leases pay the new wallet.
    function test_wallet_change_scoping() public {
        _fund(10e6);
        vm.prank(buyer);
        uint256 id = b.startLease(vid, 1e6, 1);
        address w2 = makeAddr("w2");
        vm.prank(seller);
        b.changeVendorWallet(vid, w2);
        vm.prank(w2);
        vm.expectRevert(SRNetBalance.NotLeaseSeller.selector);
        b.cancel(id);
        vm.warp(block.timestamp + 3600);
        b.finalize(id);
        assertEq(b.payableOf(seller), 1e6);
        vm.prank(buyer);
        uint256 id2 = b.startLease(vid, 1e6, 1);
        (, address sw,,,,,,) = b.leaseInfo(id2);
        assertEq(sw, w2);
    }

    /// Owner cannot touch USDC or open leases.
    function test_owner_cannot_move_usdc() public {
        _fund(10e6);
        vm.prank(owner);
        vm.expectRevert(SRNetBalance.CannotRescueUsdc.selector);
        b.rescueToken(address(usdc), owner, 1);
        vm.prank(buyer);
        uint256 id = b.startLease(vid, 1e6, 2);
        vm.prank(owner);
        vm.expectRevert(SRNetBalance.NotLeaseSeller.selector);
        b.cancel(id);
        vm.prank(owner);
        b.setPaused(true);
        vm.prank(buyer);
        b.cashOut(1e6); // exits keep working while paused
    }
}
