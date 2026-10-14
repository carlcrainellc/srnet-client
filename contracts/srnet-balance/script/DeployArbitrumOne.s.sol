// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SRNetBalance} from "../src/SRNetBalance.sol";

/// @notice Deploy SRNetBalance. On Arbitrum One (42161) the USDC and Chainflip Vault addresses are pinned;
///         on any other chain they come from env and the constructor's token checks (code, decimals 6,
///         symbol "USDC") are the only guard.
///
///   Required env:
///     signer                `--keystore FILE --password-file FILE` (preferred), or DEPLOYER_PRIVATE_KEY.
///                           Pays gas only; holds no powers after deploy.
///     OWNER                 owner address (use a multisig)
///     FEE_RECIPIENT         fee wallet
///     USDC, CF_VAULT        other chains only. On 42161, USDC must be unset or equal the pinned address;
///                           CF_VAULT defaults to the pinned Vault and must report the pinned KeyManager.
///   Optional env (defaults): MAX_PER_LEASE=20e6, MAX_LEASE_HOURS=168, FEE_BPS=300, MAX_RELAY_FEE=1e6
///
///   The Vault is immutable in SRNetBalance. If Chainflip replaces it, deploy a new contract.
///
///   Dry run:  forge script script/DeployArbitrumOne.s.sol --rpc-url $ARB_RPC
///   Broadcast only after review: add --broadcast --verify
contract DeployArbitrumOne is Script {
    uint256 internal constant ARB_ONE = 42161;
    /// Circle native USDC on Arbitrum One (developers.circle.com/stablecoins/usdc-contract-addresses).
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    /// Chainflip Vault and KeyManager on Arbitrum One, from
    /// https://docs.chainflip.io/protocol/supported-chains-assets/mainnet-addresses (checked 2026-10-12;
    /// on-chain Vault.getKeyManager() returned ARB_CF_KEY_MANAGER).
    address internal constant ARB_CF_VAULT = 0x79001a5e762f3bEFC8e5871b42F6734e00498920;
    address internal constant ARB_CF_KEY_MANAGER = 0xBFe612c77C2807Ac5a6A41F84436287578000275;

    function run() external returns (SRNetBalance b) {
        uint256 key = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address owner_ = vm.envAddress("OWNER");
        address feeRecipient_ = vm.envAddress("FEE_RECIPIENT");
        uint256 maxPerLease = vm.envOr("MAX_PER_LEASE", uint256(20e6));
        uint256 maxLeaseHours = vm.envOr("MAX_LEASE_HOURS", uint256(168));
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(300));
        uint256 maxRelayFee = vm.envOr("MAX_RELAY_FEE", uint256(1e6));
        require(owner_ != address(0) && feeRecipient_ != address(0), "set OWNER and FEE_RECIPIENT");

        address usdc_;
        address cfVault_;
        if (block.chainid == ARB_ONE) {
            usdc_ = vm.envOr("USDC", ARB_USDC);
            require(usdc_ == ARB_USDC, "USDC on Arbitrum One must be Circle native USDC");
            cfVault_ = vm.envOr("CF_VAULT", ARB_CF_VAULT);
            (bool ok, bytes memory km) = cfVault_.staticcall(abi.encodeWithSignature("getKeyManager()"));
            require(ok && km.length == 32, "CF_VAULT is not a Chainflip Vault");
            require(abi.decode(km, (address)) == ARB_CF_KEY_MANAGER, "CF_VAULT key manager mismatch");
            if (cfVault_ != ARB_CF_VAULT) console2.log("WARNING: CF_VAULT overrides the documented vault");
        } else {
            usdc_ = vm.envAddress("USDC");
            cfVault_ = vm.envAddress("CF_VAULT");
        }
        require(usdc_.code.length > 0, "USDC has no code on this chain");
        require(cfVault_.code.length > 0, "CF_VAULT has no code");

        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        b = new SRNetBalance(usdc_, feeRecipient_, owner_, maxPerLease, maxLeaseHours, feeBps, cfVault_, maxRelayFee);
        vm.stopBroadcast();

        require(address(b.usdc()) == usdc_ && b.owner() == owner_ && b.feeBps() == feeBps, "post-deploy check");
        require(b.cfVault() == cfVault_, "post-deploy vault check");
        console2.log("SRNetBalance", address(b));
    }
}
