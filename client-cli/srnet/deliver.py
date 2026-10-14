"""Deliver a buyer's signed lease claim to the seller over Session Router.

The address comes only from the seller's *signed* listing: http://<listing seller .sesh>:<claim_port>/v1/claim
(claim_port defaults to 8650). Delivery is retried with backoff; the seller's receiver is
idempotent, so re-sending is always safe. Returns the seller's acknowledgment:
  {"delivered": bool, "status": "queued"|"admitted"|"rejected"|"conflict"|"undelivered", "reason": ...}
If delivery fails the claim stays in the local spool and `srnet deliver` retries it later.
"""
from __future__ import annotations

import http.client
import json
import time
import urllib.parse

DEFAULT_CLAIM_PORT = 8650


def claim_url(listing: dict) -> str:
    seller = listing["seller"]
    port = int(listing.get("claim_port") or DEFAULT_CLAIM_PORT)
    if not (seller.endswith(".sesh") and 1 <= port <= 65535):
        raise ValueError("listing has no usable seller address")
    return f"http://{seller}:{port}/v1/claim"


def http_transport(url: str, body: bytes | None, timeout: float = 30, dns: str | None = None) -> tuple[int, dict]:
    """POST (body) or GET (None) over plain HTTP; .sesh names resolve via Session Router's DNS."""
    u = urllib.parse.urlparse(url)
    host = u.hostname or ""
    if host.endswith(".sesh"):
        import seshdns
        ip = seshdns.resolve(host, dns)
    elif host in ("127.0.0.1", "::1", "localhost"):
        ip = host
    else:
        raise ValueError("claims go only to .sesh sellers (or loopback for tests)")
    c = http.client.HTTPConnection(ip, u.port or 80, timeout=timeout)
    try:
        h = {"Host": u.netloc}
        if body is not None:
            h["Content-Type"] = "application/json"
        c.request("POST" if body is not None else "GET", u.path, body=body, headers=h)
        r = c.getresponse()
        data = r.read(4096)
    finally:
        c.close()
    try:
        return r.status, json.loads(data or b"{}")
    except ValueError:
        return r.status, {}


def deliver(claim: dict, listing: dict, *, transport=http_transport, attempts: int = 6,
            backoff: float = 2.0, wait_admit: float = 60, poll: float = 3, sleep=time.sleep,
            url: str | None = None, dns: str | None = None) -> dict:
    url = url or claim_url(listing)
    body = json.dumps(claim).encode()
    last = "no attempt"
    for i in range(attempts):
        if i:
            sleep(min(backoff * 2 ** (i - 1), 60))
        try:
            code, r = transport(url, body, dns=dns) if transport is http_transport else transport(url, body)
        except (OSError, ValueError) as e:
            last = f"{e.__class__.__name__}: {e}"
            if isinstance(e, ValueError) and "only to .sesh" in str(e):
                break
            continue
        if code == 429 or code >= 500:
            last = f"HTTP {code}"
            continue
        if code in (400, 409):
            return {"delivered": code == 409, "status": r.get("status", "invalid"), "reason": r.get("reason"),
                    "url": url}
        st = r.get("status")
        if st == "queued" and wait_admit > 0:
            end = time.monotonic() + wait_admit
            while time.monotonic() < end and st == "queued":
                sleep(poll)
                try:
                    _, g = (transport(f"{url}/{claim['hold_id']}", None, dns=dns) if transport is http_transport
                            else transport(f"{url}/{claim['hold_id']}", None))
                    st, r = g.get("status", st), g
                except (OSError, ValueError):
                    break
        return {"delivered": True, "status": st, "reason": r.get("reason"), "url": url}
    return {"delivered": False, "status": "undelivered", "reason": last, "url": url}
