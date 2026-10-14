// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SRNetBalance} from "../src/SRNetBalance.sol";
import {CFV_STUB} from "./MockCfVault.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @notice Known-risk scenarios for prepaid hourly leases.
///         RISK = accepted by design (documented), CLOSED = fixed.
contract KnownRisksTest is Test {
    MockUSDC internal usdc;
    SRNetBalance internal balance;
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal owner = makeAddr("owner");
    bytes32 internal salt = keccak256("seller-salt");
    bytes32 internal vendorId;

    function setUp() public {
        vm.etch(CFV_STUB, hex"00");
        usdc = new MockUSDC();
        balance = new SRNetBalance(address(usdc), feeRecipient, owner, 20e6, 168, 300, CFV_STUB, 1e6);
        vendorId = keccak256(abi.encodePacked(seller, salt));
        vm.prank(seller);
        balance.configureVendor(vendorId, salt);
        usdc.mint(buyer, 100e6);
        vm.prank(buyer);
        usdc.approve(address(balance), type(uint256).max);
        vm.prank(buyer);
        balance.fund(50e6); // 48.5 available
    }

    /// CLOSED: a buyer who used the exit cannot get that time back. Payment is final at start: the buyer has no cancel at all; silence pays the whole lease.
    function test_CLOSED_seller_paid_for_time_used() public {
        vm.prank(buyer);
        uint256 id = balance.startLease(vendorId, 6e6, 1);
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(buyer);
        vm.expectRevert(SRNetBalance.NotLeaseSeller.selector);
        balance.cancel(id);
        vm.warp(block.timestamp + 30 minutes);
        balance.finalize(id);
        assertEq(balance.payableOf(seller), 6e6);
    }

    /// RISK (accepted, all on the buyer): a seller can take the money and never serve. The buyer loses
    /// what it prepaid; buying one hour at a time (client default) caps the loss at ~1 hour's price,
    /// and the per-lease cap at $20.
    function test_RISK_nondelivery_costs_buyer_prepaid_hour() public {
        vm.prank(buyer);
        uint256 id = balance.startLease(vendorId, 6e6, 1);
        vm.prank(seller);
        balance.claimEarned(id); // seller takes the hour immediately
        assertEq(balance.payableOf(seller), 6e6);
        assertEq(balance.availableOf(buyer), 48.5e6 - 6e6);
        // client notices non-delivery and simply does not renew: no further loss
        vm.prank(buyer);
        vm.expectRevert(SRNetBalance.LeaseTooLarge.selector);
        balance.startLease(vendorId, 20e6 + 1, 1);
    }

    /// CLOSED: a token address without code is rejected at construction.
    function test_CLOSED_token_without_code_rejected() public {
        vm.expectRevert(SRNetBalance.BadToken.selector);
        new SRNetBalance(makeAddr("typo"), feeRecipient, owner, 20e6, 168, 300, CFV_STUB, 1e6);
    }

    /// CLOSED: owner (two-step) and fee recipient are changeable.
    function test_CLOSED_owner_and_fee_recipient_changeable() public {
        address next = makeAddr("next");
        vm.prank(owner);
        balance.transferOwnership(next);
        vm.prank(next);
        balance.acceptOwnership();
        vm.prank(next);
        balance.setFeeRecipient(next);
        balance.withdrawFees();
        assertEq(usdc.balanceOf(next), 1.5e6);
    }

    /// CLOSED: pause blocks deposits as well as purchases.
    function test_CLOSED_fund_blocked_while_paused() public {
        vm.prank(owner);
        balance.setPaused(true);
        vm.prank(buyer);
        vm.expectRevert(SRNetBalance.Paused.selector);
        balance.fund(1e6);
    }

    /// RISK (accepted): the deposit fee is never refunded, even if nothing is leased.
    function test_RISK_fee_not_refunded_on_cashOut() public {
        vm.prank(buyer);
        balance.cashOut(48.5e6);
        assertEq(usdc.balanceOf(buyer), 98.5e6);
    }
}
