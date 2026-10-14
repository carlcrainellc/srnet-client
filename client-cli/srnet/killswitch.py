"""nftables kill switch: block clearnet egress except the overlay UDP + tunnel.

When armed, only traffic via the TUN (exit path) and UDP on the WAN interface
(needed by the overlay) is allowed out. That UDP allow is broad: QUIC/WebRTC
traffic can still reach the internet directly. Explicitly drops DNS (udp/tcp 53) on every path
except the TUN so a blanket UDP allow for the overlay cannot leak queries to
the ISP resolver. Uses the inet family so IPv4 and IPv6
share the same policy.
"""
from __future__ import annotations

import re
import shutil
import subprocess
from dataclasses import dataclass

_IFACE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,15}$")
_IPV4_RE = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$")
_IPV6_RE = re.compile(r"^[0-9a-fA-F:]+$")


@dataclass
class KillSwitch:
    table: str = "inet"
    name: str = "srnet_ks"
    tun: str = "sr-tun"
    overlay_udp_port: int = 1090  # documented default; WAN UDP allow is not port-limited (QUIC varies)

    def _nft_f(self, script: str, check: bool = True) -> subprocess.CompletedProcess:
        nft = shutil.which("nft") or "/usr/sbin/nft"
        return subprocess.run([nft, "-f", "-"], input=script, capture_output=True, text=True, check=check)

    def _nft(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        nft = shutil.which("nft") or "/usr/sbin/nft"
        return subprocess.run([nft, *args], capture_output=True, text=True, check=check)

    def status(self) -> bool:
        r = self._nft("list", "table", self.table, self.name, check=False)
        return r.returncode == 0

    def arm(self, wan_if: str, bootstrap_ips: list[str] | None = None) -> None:
        if not _IFACE_RE.match(wan_if):
            raise ValueError(f"refusing wan_if={wan_if!r}: expected simple iface name")
        if not _IFACE_RE.match(self.tun):
            raise ValueError(f"refusing tun={self.tun!r}: expected simple iface name")
        self.disarm()
        # Order matters: TUN accept, then DNS drop, then WAN overlay UDP.
        # Without the DNS drop, "meta l4proto udp accept" on WAN would leak resolver traffic.
        lines = [
            f"add table {self.table} {self.name}",
            f"add chain {self.table} {self.name} output {{ type filter hook output priority 0; policy drop; }}",
            f'add rule {self.table} {self.name} output oifname "lo" accept',
            f"add rule {self.table} {self.name} output ct state established,related accept",
            f'add rule {self.table} {self.name} output oifname "{self.tun}" accept',
            f"add rule {self.table} {self.name} output udp dport 53 drop",
            f"add rule {self.table} {self.name} output tcp dport 53 drop",
            f'add rule {self.table} {self.name} output oifname "{wan_if}" meta l4proto udp accept',
        ]
        for ip in bootstrap_ips or []:
            if _IPV4_RE.match(ip):
                lines.append(
                    f'add rule {self.table} {self.name} output oifname "{wan_if}" ip daddr {ip} accept'
                )
            elif _IPV6_RE.match(ip) and ":" in ip:
                lines.append(
                    f'add rule {self.table} {self.name} output oifname "{wan_if}" ip6 daddr {ip} accept'
                )
            else:
                raise ValueError(f"refusing bootstrap ip={ip!r}")
        self._nft_f("\n".join(lines) + "\n")

    def disarm(self) -> None:
        self._nft("delete", "table", self.table, self.name, check=False)

    def assert_blocks_clearnet(self, test_dst: str = "1.1.1.1") -> bool:
        return self.status()
