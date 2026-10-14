// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SRNetBalance} from "../src/SRNetBalance.sol";
import {MockUSDCPermit} from "./MockUSDCPermit.sol";
import {MockCfVault} from "./MockCfVault.sol";

/// @dev Gasless phone-wallet funding: user holds USDC (sent from any wallet) and zero ETH.
contract FundWithPermitTest is Test {
    MockUSDCPermit internal usdc;
    SRNetBalance internal b;
    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("fee");
    address internal user;
    uint256 internal userKey;
    address internal relayer = makeAddr("relayer");
    address internal attacker = makeAddr("attacker");
    uint256 internal constant AMT = 10e6;
    uint256 internal constant RFEE = 0.02e6;

    function setUp() public {
        (user, userKey) = makeAddrAndKey("user");
        usdc = new MockUSDCPermit();
        b = new SRNetBalance(address(usdc), feeRecipient, owner, 20e6, 168, 300, address(new MockCfVault()), 1e6);
        usdc.mint(user, AMT * 3); // plain transfer from a phone wallet
        assertEq(user.balance, 0);
    }

    function _intent(uint256 amount, uint256 fee, address rel, uint256 nonce, uint256 dl)
        internal
        view
        returns (SRNetBalance.FundAuth memory)
    {
        return SRNetBalance.FundAuth(user, user, amount, fee, rel, nonce, dl);
    }

    function _signIntent(uint256 key, SRNetBalance.FundAuth memory a) internal view returns (bytes memory) {
        bytes32 sh = keccak256(
            abi.encode(b.FUND_TYPEHASH(), a.owner, a.beneficiary, a.amount, a.relayFee, a.relayer, a.nonce, a.deadline)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, b.hashTypedData(sh));
        return abi.encodePacked(r, s, v);
    }

    function _permit(uint256 key, address o, uint256 value, uint256 dl)
        internal
        view
        returns (SRNetBalance.PermitSig memory)
    {
        bytes32 sh = keccak256(abi.encode(usdc.PERMIT_TYPEHASH(), o, address(b), value, usdc.nonces(o), dl));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), sh)));
        return SRNetBalance.PermitSig(value, dl, v, r, s);
    }

    function test_happyPath_noEth() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, address(0), 1, dl);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, dl);
        vm.prank(relayer);
        b.fundWithPermit(a, sig, p);
        uint256 fee = AMT * 300 / 10_000;
        assertEq(b.availableOf(user), AMT - fee - RFEE);
        assertEq(b.payableOf(relayer), RFEE);
        assertEq(b.accruedFees(), fee);
        assertEq(b.totalLiabilities(), AMT);
        assertEq(usdc.balanceOf(address(b)), AMT);
        assertEq(user.balance, 0);
    }

    function test_badIntentSig_reverts() public {
        (, uint256 otherKey) = makeAddrAndKey("other");
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, address(0), 1, dl);
        bytes memory sig = _signIntent(otherKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, dl);
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.fundWithPermit(a, sig, p);
    }

    function test_badPermitSig_noAllowance_reverts() public {
        (, uint256 otherKey) = makeAddrAndKey("other");
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, address(0), 1, dl);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(otherKey, user, AMT, dl);
        vm.expectRevert(SRNetBalance.InsufficientAllowance.selector);
        b.fundWithPermit(a, sig, p);
    }

    function test_expiredIntent_reverts() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, address(0), 1, dl);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, dl + 1 days);
        vm.warp(dl + 1);
        vm.expectRevert(SRNetBalance.SignatureExpired.selector);
        b.fundWithPermit(a, sig, p);
    }

    function test_expiredPermit_reverts() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, address(0), 1, dl + 1 days);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, dl);
        vm.warp(dl + 1);
        vm.expectRevert(SRNetBalance.InsufficientAllowance.selector);
        b.fundWithPermit(a, sig, p);
    }

    function test_replay_reverts() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, address(0), 1, dl);
        bytes memory sig = _signIntent(userKey, a);
        // permit for 2x so allowance would still cover a replay; the nonce must stop it
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT * 2, dl);
        b.fundWithPermit(a, sig, p);
        SRNetBalance.PermitSig memory none;
        vm.expectRevert(SRNetBalance.NonceAlreadyUsed.selector);
        b.fundWithPermit(a, sig, none);
    }

    function test_feeAboveCap_reverts() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, 1e6 + 1, address(0), 1, dl);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, dl);
        vm.expectRevert(SRNetBalance.RelayFeeTooHigh.selector);
        b.fundWithPermit(a, sig, p);
    }

    function test_feeAboveDeposit_reverts() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(0.5e6, 0.5e6, address(0), 1, dl);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, 0.5e6, dl);
        vm.expectRevert(SRNetBalance.RelayFeeTooHigh.selector);
        b.fundWithPermit(a, sig, p);
    }

    function test_relayerCannotRaiseFee_orRedirect() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, address(0), 1, dl);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, dl);
        SRNetBalance.FundAuth memory bad = a;
        bad.relayFee = 1e6;
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.fundWithPermit(bad, sig, p);
        bad = a;
        bad.beneficiary = attacker;
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.fundWithPermit(bad, sig, p);
        bad = a;
        bad.amount = AMT * 2;
        vm.expectRevert(SRNetBalance.BadSignature.selector);
        b.fundWithPermit(bad, sig, p);
    }

    function test_pinnedRelayer() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, relayer, 1, dl);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, dl);
        vm.prank(attacker);
        vm.expectRevert(SRNetBalance.WrongRelayer.selector);
        b.fundWithPermit(a, sig, p);
        vm.prank(relayer);
        b.fundWithPermit(a, sig, p);
        assertEq(b.payableOf(relayer), RFEE);
    }

    /// Griefer copies the permit from the mempool and submits it to USDC first. The permit nonce is
    /// consumed, our try/catch swallows the failure, and the allowance it created is used.
    function test_frontRunPermit_griefing_fallback() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, address(0), 1, dl);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, dl);
        vm.prank(attacker);
        usdc.permit(user, address(b), p.value, p.deadline, p.v, p.r, p.s);
        vm.prank(relayer);
        b.fundWithPermit(a, sig, p);
        assertEq(b.availableOf(user), AMT - AMT * 300 / 10_000 - RFEE);
    }

    /// Allowance from a permit alone cannot be spent by anyone else: no path pulls from `owner` without
    /// the owner's Fund signature.
    function test_permitAlone_doesNotLetOthersPull() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, dl);
        usdc.permit(user, address(b), p.value, p.deadline, p.v, p.r, p.s);
        vm.prank(attacker);
        vm.expectRevert(); // fund() pulls from msg.sender (attacker has nothing), never from `user`
        b.fund(AMT);
        assertEq(usdc.balanceOf(user), AMT * 3);
    }

    function test_frontRunWholeCall_sameOutcomeForUser() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, address(0), 1, dl);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, dl);
        vm.prank(attacker);
        b.fundWithPermit(a, sig, p);
        assertEq(b.availableOf(user), AMT - AMT * 300 / 10_000 - RFEE);
        assertEq(b.payableOf(attacker), RFEE); // attacker just did the relayer's job for the same fee
        vm.prank(relayer);
        vm.expectRevert(SRNetBalance.NonceAlreadyUsed.selector);
        b.fundWithPermit(a, sig, p);
    }

    function test_existingAllowance_noPermit() public {
        vm.prank(user);
        usdc.approve(address(b), AMT);
        SRNetBalance.FundAuth memory a = _intent(AMT, 0, address(0), 7, block.timestamp + 60);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory none;
        b.fundWithPermit(a, sig, none);
        assertEq(b.availableOf(user), AMT - AMT * 300 / 10_000);
    }

    function test_invalidatedNonce_blocks() public {
        uint256 dl = block.timestamp + 1 hours;
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, address(0), 9, dl);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, dl);
        vm.prank(user);
        b.invalidateNonce(9);
        vm.expectRevert(SRNetBalance.NonceAlreadyUsed.selector);
        b.fundWithPermit(a, sig, p);
    }

    function test_paused_reverts() public {
        vm.prank(owner);
        b.setPaused(true);
        SRNetBalance.FundAuth memory a = _intent(AMT, RFEE, address(0), 1, block.timestamp + 60);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, AMT, block.timestamp + 60);
        vm.expectRevert(SRNetBalance.Paused.selector);
        b.fundWithPermit(a, sig, p);
    }

    function test_plainFundStillWorks() public {
        vm.startPrank(user);
        usdc.approve(address(b), AMT);
        b.fund(AMT);
        vm.stopPrank();
        assertEq(b.availableOf(user), AMT - AMT * 300 / 10_000);
    }

    function testFuzz_accounting(uint256 amount, uint256 rfee) public {
        amount = bound(amount, 1, AMT * 3);
        rfee = bound(rfee, 0, 1e6);
        uint256 fee = amount * 300 / 10_000;
        vm.assume(rfee <= amount - fee);
        SRNetBalance.FundAuth memory a = _intent(amount, rfee, address(0), 1, block.timestamp + 60);
        bytes memory sig = _signIntent(userKey, a);
        SRNetBalance.PermitSig memory p = _permit(userKey, user, amount, block.timestamp + 60);
        vm.prank(relayer);
        b.fundWithPermit(a, sig, p);
        assertEq(b.availableOf(user) + b.payableOf(relayer) + b.accruedFees(), amount);
        assertEq(b.totalLiabilities(), usdc.balanceOf(address(b)));
    }
}
