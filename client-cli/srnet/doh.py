"""Resolver hint file (informational only).

Exits never forward DNS (port 53), and the kill switch drops udp/53 and tcp/53 on
every interface except the tunnel. This module writes a small resolv.conf-style
hint to the client state directory (default ~/.srnet/resolv.conf). It does not
change system DNS and is not a DNS-over-HTTPS proxy. Plain DNS is blocked. Turn
on DNS-over-HTTPS in your browser, or names won't resolve; it travels over
tcp/443 through the exit.
"""
from __future__ import annotations

from pathlib import Path


def write_resolv(path: Path, nameserver: str = "1.1.1.1") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"# srnet client: resolver hint only (plain DNS is blocked; turn on DNS-over-HTTPS in your browser)\n"
        f"nameserver {nameserver}\n"
        f"options edns0 trust-ad\n"
    )
