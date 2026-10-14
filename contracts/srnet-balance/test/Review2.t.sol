// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SRNetBalance} from "../src/SRNetBalance.sol";
import {MockCfVault, CFV_STUB} from "./MockCfVault.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {ReentrantUSDC} from "./Mocks.sol";

/// @notice Second review round: surplus USDC, withdrawPayable, reentrancy guards on lease closing.
contract Review2Test is Test {
    MockUSDC internal usdc;
    MockCfVault internal vault;
    SRNetBalance internal b;
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal fees = makeAddr("fees");
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    bytes32 internal salt = keccak256("s");
    bytes32 internal vid;

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MockCfVault();
        b = new SRNetBalance(address(usdc), fees, owner, 20e6, 168, 300, address(vault), 1e6);
        vid = keccak256(abi.encodePacked(seller, salt));
        vm.prank(seller);
        b.configureVendor(vid, salt);
        usdc.mint(buyer, 1_000e6);
        usdc.mint(stranger, 1_000e6);
        usdc.mint(address(vault), 1_000e6);
        vm.prank(buyer);
        usdc.approve(address(b), type(uint256).max);
    }

    function _ccm(address who, uint256 amount) internal {
        vault.executexSwapAndCall(
            MockCfVault.TransferParams(address(usdc), address(b), amount), 4, "", b.encodeCcmMessage(who, 0)
        );
    }

    function _solvent() internal view {
        assertGe(usdc.balanceOf(address(b)), b.totalLiabilities());
    }

    function test_direct_transfer_not_absorbed_by_ccm() public {
        vm.prank(stranger);
        usdc.transfer(address(b), 5e6);
        assertEq(b.surplusUsdc(), 5e6);
        _ccm(buyer, 10e6);
        assertEq(b.availableOf(buyer), 10e6 - 0.3e6, "only the delivered CCM amount is credited");
        assertEq(b.surplusUsdc(), 5e6, "direct transfer stays surplus");
        _solvent();
    }

    function test_sweep_takes_only_surplus() public {
        vm.prank(buyer);
        b.fund(10e6);
        vm.prank(buyer);
        uint256 id = b.startLease(vid, 2e6, 2);
        _ccm(buyer, 4e6);
        vm.prank(stranger);
        usdc.transfer(address(b), 7e6);
        uint256 liab = b.totalLiabilities();

        vm.prank(stranger);
        vm.expectRevert(SRNetBalance.NotOwner.selector);
        b.sweepSurplus();

        vm.prank(owner);
        assertEq(b.sweepSurplus(), 7e6);
        assertEq(usdc.balanceOf(fees), 7e6);
        assertEq(b.totalLiabilities(), liab);
        assertEq(usdc.balanceOf(address(b)), liab);
        assertEq(b.surplusUsdc(), 0);
        vm.prank(owner);
        vm.expectRevert(SRNetBalance.ZeroAmount.selector);
        b.sweepSurplus();

        // everyone still gets paid in full afterwards
        vm.warp(block.timestamp + 2 hours);
        b.finalize(id);
        vm.prank(seller);
        assertEq(b.withdrawPayable(), 4e6);
        uint256 avail = b.availableOf(buyer);
        vm.prank(buyer);
        b.cashOut(avail);
        b.withdrawFees();
        assertEq(usdc.balanceOf(address(b)), 0);
        assertEq(b.totalLiabilities(), 0);
    }

    function testFuzz_sweep_never_touches_liabilities(uint96 funded, uint96 direct) public {
        uint256 f = bound(funded, 1, 500e6);
        uint256 d = bound(direct, 1, 500e6);
        vm.prank(buyer);
        b.fund(f);
        vm.prank(stranger);
        usdc.transfer(address(b), d);
        vm.prank(owner);
        b.sweepSurplus();
        assertEq(usdc.balanceOf(address(b)), b.totalLiabilities());
    }

    function test_withdrawPayable_and_withdrawVendor_same_balance() public {
        vm.prank(buyer);
        b.fund(10e6);
        vm.prank(buyer);
        uint256 id = b.startLease(vid, 1e6, 1);
        vm.prank(seller);
        b.claimEarned(id);
        assertEq(b.payableOf(seller), 1e6);
        vm.prank(seller);
        b.withdrawVendor();
        assertEq(usdc.balanceOf(seller), 1e6);
        vm.prank(seller);
        vm.expectRevert(SRNetBalance.InsufficientPayable.selector);
        b.withdrawPayable();
    }

    function test_renew_rate_exact() public {
        vm.prank(buyer);
        b.fund(100e6);
        vm.prank(buyer);
        uint256 id = b.startLease(vid, 333_333, 7);
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(buyer);
        uint256 id2 = b.renewLease(id, 3);
        (uint256 rate, uint256 hrs) = b.leaseTerms(id2);
        assertEq(rate, 333_333);
        assertEq(hrs, 3);
    }

    // ── reentrancy into lease closing ─────────────────────────────────────

    function _reentrant() internal returns (ReentrantUSDC t, SRNetBalance rb, uint256 id) {
        t = new ReentrantUSDC();
        vm.etch(CFV_STUB, hex"00");
        rb = new SRNetBalance(address(t), fees, owner, 20e6, 168, 300, CFV_STUB, 1e6);
        vm.prank(seller);
        rb.configureVendor(vid, salt);
        t.mint(buyer, 100e6);
        vm.startPrank(buyer);
        t.approve(address(rb), type(uint256).max);
        rb.fund(20e6);
        id = rb.startLease(vid, 1e6, 2);
        vm.stopPrank();
    }

    function test_reentrancy_into_cancel_finalize_claimEarned_blocked() public {
        bytes[3] memory calls;
        uint256 id0 = 1; // first lease id in each fresh deployment
        calls[0] = abi.encodeCall(SRNetBalance.cancel, (id0));
        calls[1] = abi.encodeCall(SRNetBalance.finalize, (id0));
        calls[2] = abi.encodeCall(SRNetBalance.claimEarned, (id0));
        for (uint256 i; i < 3; ++i) {
            (ReentrantUSDC t, SRNetBalance rb,) = _reentrant();
            t.arm(address(rb), calls[i]);
            vm.prank(buyer);
            vm.expectRevert(SRNetBalance.Reentered.selector);
            rb.cashOut(1e6);
        }
    }
}
