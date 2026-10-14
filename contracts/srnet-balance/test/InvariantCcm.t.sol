// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SRNetBalance} from "../src/SRNetBalance.sol";
import {MockCfVault} from "./MockCfVault.sol";
import {BlacklistUSDC} from "./CcmMocks.sol";

/// @dev Random walk: CCM top-ups (valid, malformed, paused, float, blacklisted), signed
///      start/renew/withdraw via a relayer, direct actions, held claims and every owner action.
contract CcmHandler is Test {
    SRNetBalance public b;
    BlacklistUSDC public usdc;
    MockCfVault public vault;
    address public owner;
    address public relayer = makeAddr("relayer");
    address[3] public buyers;
    uint256[3] internal keys;
    address[2] public sellers;
    bytes32[2] public vids;
    uint256 internal nonce;

    constructor(SRNetBalance b_, BlacklistUSDC usdc_, MockCfVault vault_, address owner_) {
        b = b_;
        usdc = usdc_;
        vault = vault_;
        owner = owner_;
        for (uint256 i; i < 3; ++i) {
            (buyers[i], keys[i]) = makeAddrAndKey(string(abi.encodePacked("buyer", i)));
        }
        for (uint256 i; i < 2; ++i) {
            sellers[i] = makeAddr(string(abi.encodePacked("seller", i)));
            vids[i] = keccak256(abi.encodePacked(sellers[i], bytes32(i)));
            vm.prank(sellers[i]);
            b.configureVendor(vids[i], bytes32(i));
        }
        usdc.mint(address(vault), type(uint128).max);
    }

    function ccm(uint256 s, uint256 amt, uint64 fl, uint8 kind) external {
        bytes memory m;
        address who = buyers[s % 3];
        kind = kind % 4;
        if (kind == 0) m = abi.encodePacked(uint8(1), who);
        else if (kind == 1) m = abi.encodePacked(uint8(1), who, fl);
        else if (kind == 2) m = abi.encodePacked(uint8(9), who);
        else m = hex"c0ffee";
        amt = bound(amt, 0, 100e6);
        // unreadable messages: half arrive from a deposit channel (empty src), half from an EVM sender
        bytes memory src = (kind >= 2 && s % 2 == 1) ? abi.encodePacked(who) : bytes("");
        if (kind >= 2) {
            if (src.length == 0) ghostUnattributed += amt;
            else ghostHeldFromSrc += amt;
        }
        vault.executexSwapAndCall(MockCfVault.TransferParams(address(usdc), address(b), amt), 3, src, m);
    }

    uint256 public ghostUnattributed;
    uint256 public ghostHeldFromSrc;

    /// @dev Vault reports an amount that was never transferred: must book nothing.
    function ccmFakeAmount(uint256 s, uint256 amt) external {
        vm.prank(address(vault));
        b.cfReceive(3, "", abi.encodePacked(uint8(1), buyers[s % 3]), address(usdc), bound(amt, 1, 1e12));
    }

    function toggleBlacklist(uint256 s) external {
        address w = buyers[s % 3];
        usdc.setBlocked(w, !usdc.blocked(w));
    }

    function claimHeld(uint256 s) external {
        vm.prank(buyers[s % 3]);
        b.claimHeld(address(usdc));
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(key, b.hashTypedData(structHash));
        return abi.encodePacked(r, sg, v);
    }

    function signedStart(uint256 s, uint256 v, uint256 rate, uint256 hrs, uint256 fee) external {
        uint256 i = s % 3;
        hrs = bound(hrs, 1, 168);
        SRNetBalance.StartLeaseAuth memory a = SRNetBalance.StartLeaseAuth(
            buyers[i],
            vids[v % 2],
            bound(rate, 1, 20e6 / hrs == 0 ? 1 : 20e6 / hrs),
            hrs,
            bound(fee, 0, 1e6),
            address(0),
            ++nonce,
            block.timestamp + 1 hours
        );
        bytes32 h = keccak256(
            abi.encode(
                b.START_LEASE_TYPEHASH(),
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
        bytes memory sig = _sign(keys[i], h);
        vm.prank(relayer);
        b.startLeaseFor(a, sig);
    }

    function signedRenew(uint256 s, uint256 hrs, uint256 fee) external {
        uint256 n = b.nextLeaseId();
        if (n == 0) return;
        uint256 id = 1 + (s % n);
        (address buyer,,,,,,,) = b.leaseInfo(id);
        uint256 i = buyer == buyers[0] ? 0 : buyer == buyers[1] ? 1 : 2;
        SRNetBalance.RenewAuth memory c = SRNetBalance.RenewAuth(
            buyer, id, bound(hrs, 1, 3), bound(fee, 0, 1e6), address(0), ++nonce, block.timestamp + 1 hours
        );
        bytes32 h = keccak256(
            abi.encode(
                b.RENEW_TYPEHASH(), c.buyer, c.prevLeaseId, c.hoursBought, c.relayFee, c.relayer, c.nonce, c.deadline
            )
        );
        bytes memory sig = _sign(keys[i], h);
        vm.prank(relayer);
        b.renewFor(c, sig);
    }

    function signedCashOut(uint256 s, uint256 amt, uint256 fee) external {
        uint256 i = s % 3;
        uint256 avail = b.availableOf(buyers[i]);
        if (avail < 2) return;
        fee = bound(fee, 0, avail / 2 > 1e6 ? 1e6 : avail / 2);
        SRNetBalance.WithdrawAuth memory o = SRNetBalance.WithdrawAuth(
            buyers[i], bound(amt, 1, avail - fee), buyers[i], fee, address(0), ++nonce, block.timestamp + 1 hours
        );
        bytes32 h = keccak256(
            abi.encode(b.WITHDRAW_TYPEHASH(), o.user, o.amount, o.to, o.relayFee, o.relayer, o.nonce, o.deadline)
        );
        bytes memory sig = _sign(keys[i], h);
        vm.prank(relayer);
        b.withdrawFor(o, sig);
    }

    function sellerCancel(uint256 s) external {
        uint256 n = b.nextLeaseId();
        if (n == 0) return;
        uint256 id = 1 + (s % n);
        (, address seller,,,,,,) = b.leaseInfo(id);
        vm.prank(seller);
        b.cancel(id);
    }

    function finalize(uint256 s) external {
        uint256 n = b.nextLeaseId();
        if (n == 0) return;
        b.finalize(1 + (s % n));
    }

    function withdrawPayable(uint256 s) external {
        address w = s % 3 == 2 ? relayer : sellers[s % 2];
        vm.prank(w);
        b.withdrawVendor();
    }

    function withdrawFees() external {
        b.withdrawFees();
    }

    function ownerPause(bool p) external {
        vm.prank(owner);
        b.setPaused(p);
    }

    function ownerRescueUsdc(uint256 amt) external {
        vm.prank(owner);
        b.rescueToken(address(usdc), owner, bound(amt, 1, 1e12));
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }
}

contract CcmInvariantTest is Test {
    SRNetBalance internal b;
    BlacklistUSDC internal usdc;
    MockCfVault internal vault;
    CcmHandler internal h;
    address internal owner = makeAddr("owner");

    function setUp() public {
        usdc = new BlacklistUSDC();
        vault = new MockCfVault();
        b = new SRNetBalance(address(usdc), makeAddr("fee0"), owner, 20e6, 168, 300, address(vault), 1e6);
        h = new CcmHandler(b, usdc, vault, owner);
        targetContract(address(h));
    }

    /// @notice USDC held == available + locked + payable (sellers + relayer) + fees + held, exactly.
    function invariant_solvency_exact() public view {
        uint256 sum =
            b.accruedFees() + b.heldTotal(address(usdc)) + b.unattributedUsdc() + b.payableOf(h.relayer());
        uint256 held;
        for (uint256 i; i < 3; ++i) {
            sum += b.availableOf(h.buyers(i)) + b.lockedOf(h.buyers(i));
            held += b.heldOf(address(usdc), h.buyers(i));
        }
        for (uint256 i; i < 2; ++i) {
            sum += b.payableOf(h.sellers(i));
        }
        assertEq(usdc.balanceOf(address(b)), sum);
        assertEq(b.totalLiabilities(), sum);
        assertEq(held, b.heldTotal(address(usdc)));
    }

    /// @notice Unreadable-message USDC is never booked as fees and the locked bucket never shrinks.
    function invariant_unattributed_held_not_fees() public view {
        assertEq(b.unattributedUsdc(), h.ghostUnattributed());
    }

    function invariant_owner_never_gets_usdc() public view {
        assertEq(usdc.balanceOf(owner), 0);
    }

    function invariant_lease_accounting() public view {
        uint256 open;
        uint256 n = b.nextLeaseId();
        for (uint256 id = 1; id <= n; ++id) {
            (,, uint256 amount,,, uint256 credited,, bool closed) = b.leaseInfo(id);
            if (!closed) open += amount - credited;
        }
        uint256 locked;
        for (uint256 i; i < 3; ++i) {
            locked += b.lockedOf(h.buyers(i));
        }
        assertEq(open, locked);
    }
}
