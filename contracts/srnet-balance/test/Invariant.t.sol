// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SRNetBalance} from "../src/SRNetBalance.sol";
import {CFV_STUB} from "./MockCfVault.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @dev Random walk over every action, including all owner actions.
contract Handler is Test {
    SRNetBalance public b;
    MockUSDC public usdc;
    address public owner;
    address[3] public buyers;
    address[2] public sellers;
    bytes32[2] public vids;
    address[2] public feeWallets;
    uint256 public ghostVendorWithdrawn;

    constructor(SRNetBalance b_, MockUSDC usdc_, address owner_, address fee0) {
        b = b_;
        usdc = usdc_;
        owner = owner_;
        feeWallets = [fee0, makeAddr("fee1")];
        for (uint256 i; i < 3; ++i) {
            buyers[i] = makeAddr(string(abi.encodePacked("buyer", i)));
            usdc.mint(buyers[i], 1_000_000e6);
            vm.prank(buyers[i]);
            usdc.approve(address(b), type(uint256).max);
        }
        for (uint256 i; i < 2; ++i) {
            sellers[i] = makeAddr(string(abi.encodePacked("seller", i)));
            vids[i] = keccak256(abi.encodePacked(sellers[i], bytes32(i)));
            vm.prank(sellers[i]);
            b.configureVendor(vids[i], bytes32(i));
        }
    }

    function fund(uint256 s, uint256 amt) external {
        vm.prank(buyers[s % 3]);
        b.fund(bound(amt, 1, 50e6));
    }

    function startLease(uint256 s, uint256 v, uint256 rate, uint256 hrs) external {
        hrs = bound(hrs, 1, 168);
        vm.prank(buyers[s % 3]);
        b.startLease(vids[v % 2], bound(rate, 1, 20e6 / hrs == 0 ? 1 : 20e6 / hrs), hrs);
    }

    function _lease(uint256 s) internal view returns (uint256) {
        uint256 n = b.nextLeaseId();
        return n == 0 ? 0 : 1 + (s % n);
    }

    function renew(uint256 s, uint256 hrs) external {
        uint256 id = _lease(s);
        (address buyer,,,,,,,) = b.leaseInfo(id);
        vm.prank(buyer);
        b.renewLease(id, bound(hrs, 1, 3));
    }

    function sellerCancel(uint256 s) external {
        uint256 id = _lease(s);
        (, address seller,,,,,,) = b.leaseInfo(id);
        vm.prank(seller);
        b.cancel(id);
    }

    function sellerClaim(uint256 s) external {
        uint256 id = _lease(s);
        (, address seller,,,,,,) = b.leaseInfo(id);
        vm.prank(seller);
        b.claimEarned(id);
    }

    function finalize(uint256 s) external {
        b.finalize(_lease(s));
    }

    function cashOut(uint256 s, uint256 amt) external {
        address u = buyers[s % 3];
        uint256 avail = b.availableOf(u);
        if (avail == 0) return;
        vm.prank(u);
        b.cashOut(bound(amt, 1, avail));
    }

    function withdrawVendor(uint256 v) external {
        address w = sellers[v % 2];
        uint256 p = b.payableOf(w);
        vm.prank(w);
        b.withdrawVendor();
        ghostVendorWithdrawn += p;
    }

    function withdrawFees() external {
        b.withdrawFees();
    }

    function ownerPause(bool p) external {
        vm.prank(owner);
        b.setPaused(p);
    }

    function ownerFeeRecipient(uint256 i) external {
        vm.prank(owner);
        b.setFeeRecipient(feeWallets[i % 2]);
    }

    function ownerRescueUsdc(uint256 amt) external {
        vm.prank(owner);
        b.rescueToken(address(usdc), owner, bound(amt, 1, 1e12));
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }
}

contract InvariantTest is Test {
    SRNetBalance internal b;
    MockUSDC internal usdc;
    Handler internal h;
    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.etch(CFV_STUB, hex"00");
        usdc = new MockUSDC();
        address fee0 = makeAddr("fee0");
        b = new SRNetBalance(address(usdc), fee0, owner, 20e6, 168, 300, CFV_STUB, 1e6);
        h = new Handler(b, usdc, owner, fee0);
        targetContract(address(h));
    }

    /// @notice Contract USDC == sum(available) + sum(locked) + sum(payable) + accruedFees, exactly.
    function invariant_solvency_exact() public view {
        uint256 sum = b.accruedFees();
        for (uint256 i; i < 3; ++i) {
            sum += b.availableOf(h.buyers(i)) + b.lockedOf(h.buyers(i));
        }
        for (uint256 i; i < 2; ++i) {
            sum += b.payableOf(h.sellers(i));
        }
        assertEq(usdc.balanceOf(address(b)), sum);
    }

    /// @notice Per lease: credited <= earned <= amount, and sum over open leases of (amount - credited)
    ///         equals sum(lockedOf).
    function invariant_lease_accounting() public view {
        uint256 open;
        uint256 n = b.nextLeaseId();
        for (uint256 id = 1; id <= n; ++id) {
            (,, uint256 amount,,, uint256 credited,, bool closed) = b.leaseInfo(id);
            uint256 e = b.earned(id);
            assertLe(credited, e);
            assertLe(e, amount);
            if (!closed) open += amount - credited;
        }
        uint256 locked;
        for (uint256 i; i < 3; ++i) {
            locked += b.lockedOf(h.buyers(i));
        }
        assertEq(open, locked);
    }

    /// @notice The owner never receives USDC.
    function invariant_owner_never_gets_usdc() public view {
        assertEq(usdc.balanceOf(owner), 0);
    }
}
