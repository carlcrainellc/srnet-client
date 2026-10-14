// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SRNetBalance} from "../src/SRNetBalance.sol";
import {CFV_STUB} from "./MockCfVault.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockToken} from "./Mocks.sol";

/// @notice Proves the owner cannot move any buyer's or seller's USDC: after any sequence of owner
///         calls (every owner function, plus arbitrary calldata), every buyer available balance, held and unattributed CCM USDC,
///         every seller payable, the contract's USDC, and every account's USDC are unchanged.
///         The only thing an owner call can change is WHERE future protocol fees are sent.
contract OwnerPowersTest is Test {
    MockUSDC internal usdc;
    SRNetBalance internal b;
    address internal owner = makeAddr("owner");
    address internal fee = makeAddr("fee");
    address[3] internal buyers;
    address[2] internal sellers;
    MockToken internal dai;

    function setUp() public {
        vm.etch(CFV_STUB, hex"00");
        usdc = new MockUSDC();
        b = new SRNetBalance(address(usdc), fee, owner, 20e6, 168, 300, CFV_STUB, 1e6);
        dai = new MockToken("DAI", 18);
        dai.mint(address(b), 1e18);
        for (uint256 i; i < 2; ++i) {
            sellers[i] = makeAddr(string(abi.encodePacked("seller", i)));
            vm.prank(sellers[i]);
            b.configureVendor(keccak256(abi.encodePacked(sellers[i], bytes32(i))), bytes32(i));
        }
        for (uint256 i; i < 3; ++i) {
            buyers[i] = makeAddr(string(abi.encodePacked("buyer", i)));
            usdc.mint(buyers[i], 100e6);
            vm.startPrank(buyers[i]);
            usdc.approve(address(b), type(uint256).max);
            b.fund(50e6);
            b.startLease(keccak256(abi.encodePacked(sellers[i % 2], bytes32(i % 2))), 5e6 + i, 1);
            vm.stopPrank();
        }
        // unreadable CCM USDC held for an EVM sender, and some locked in the unattributed bucket
        usdc.mint(address(b), 9e6);
        vm.startPrank(CFV_STUB);
        b.cfReceive(5, abi.encodePacked(buyers[0]), hex"00", address(usdc), 4e6);
        b.cfReceive(5, "", hex"00", address(usdc), 5e6);
        vm.stopPrank();
        assertEq(b.unattributedUsdc(), 5e6);
        assertEq(b.heldOf(address(usdc), buyers[0]), 4e6);
    }

    function _snapshot() internal view returns (uint256[] memory s) {
        s = new uint256[](18);
        uint256 k;
        for (uint256 i; i < 3; ++i) {
            s[k++] = b.availableOf(buyers[i]);
            s[k++] = usdc.balanceOf(buyers[i]);
            s[k++] = b.lockedOf(buyers[i]);
        }
        for (uint256 i; i < 2; ++i) {
            s[k++] = b.payableOf(sellers[i]);
            s[k++] = usdc.balanceOf(sellers[i]);
        }
        s[k++] = usdc.balanceOf(address(b));
        s[k++] = b.accruedFees();
        s[k++] = usdc.balanceOf(owner);
        s[k++] = b.unattributedUsdc();
        s[k++] = b.heldOf(address(usdc), buyers[0]);
    }

    function _assertSame(uint256[] memory a, uint256[] memory c) internal pure {
        for (uint256 i; i < a.length; ++i) {
            assertEq(a[i], c[i]);
        }
    }

    function test_every_owner_function_leaves_user_and_seller_usdc_untouched() public {
        uint256[] memory before = _snapshot();
        address next = makeAddr("nextOwner");
        vm.startPrank(owner);
        b.setPaused(true);
        b.setPaused(false);
        b.setFeeRecipient(owner);
        b.rescueToken(address(dai), owner, 1e18);
        vm.expectRevert(SRNetBalance.CannotRescueUsdc.selector);
        b.rescueToken(address(usdc), owner, 1);
        b.transferOwnership(next);
        vm.stopPrank();
        vm.prank(next);
        b.acceptOwnership();
        // The owner, acting as an ordinary address, has no balance to cash out or withdraw.
        vm.startPrank(owner);
        vm.expectRevert(SRNetBalance.InsufficientAvailable.selector);
        b.cashOut(1);
        vm.expectRevert(SRNetBalance.InsufficientPayable.selector);
        b.withdrawVendor();
        vm.expectRevert(SRNetBalance.NotLeaseSeller.selector);
        b.cancel(1);
        vm.expectRevert(SRNetBalance.NotLeaseSeller.selector);
        b.claimEarned(1);
        vm.stopPrank();
        _assertSame(before, _snapshot());
    }

    /// @dev Arbitrary calldata from the owner (any selector, any args) cannot change user/seller USDC.
    function testFuzz_owner_arbitrary_calls_cannot_move_user_usdc(bytes calldata data, uint8 pick, address to) public {
        uint256[] memory before = _snapshot();
        bytes memory call_;
        uint8 p = pick % 10;
        if (p == 0) call_ = abi.encodeCall(SRNetBalance.setPaused, (to != address(0)));
        else if (p == 1) call_ = abi.encodeCall(SRNetBalance.setFeeRecipient, (to));
        else if (p == 2) call_ = abi.encodeCall(SRNetBalance.transferOwnership, (to));
        else if (p == 3) call_ = abi.encodeCall(SRNetBalance.rescueToken, (address(usdc), to, 1));
        else if (p == 4) call_ = abi.encodeCall(SRNetBalance.rescueToken, (address(dai), to, 1));
        else if (p == 5) call_ = abi.encodeCall(SRNetBalance.cashOut, (1));
        else if (p == 6) call_ = abi.encodeCall(SRNetBalance.withdrawVendor, ());
        else if (p == 7) call_ = abi.encodeCall(SRNetBalance.cancel, (uint256(uint8(data.length % 4))));
        else if (p == 8) call_ = abi.encodeCall(SRNetBalance.claimEarned, (uint256(uint8(data.length % 4))));
        else call_ = data;
        vm.prank(owner);
        (bool ok,) = address(b).call(call_);
        ok; // success or revert, the balances must not move
        uint256[] memory afterS = _snapshot();
        // accruedFees and fee destination are the protocol's own; user/seller/contract USDC must match.
        for (uint256 i; i < 14; ++i) {
            assertEq(before[i], afterS[i]);
        }
        assertEq(before[14], afterS[14], "accrued fees not moved by owner call");
        assertEq(before[15], afterS[15], "owner gained no USDC");
        assertEq(before[16], afterS[16], "unattributed bucket untouched");
        assertEq(before[17], afterS[17], "held USDC untouched");
    }
}
