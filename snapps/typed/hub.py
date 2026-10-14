"""Hub: one service hosting many typed collections (rooms, wiki, store, drop, profiles),
each with its own log, checkpoints, delegation (signed by the hub's collection root key)
and policy.  Routes /c/<collection>/v1/... ; GET /v1/collections lists them.

Run:  python3 -m typed.hub --data DIR --port 48810 \\
          --coll room:lobby --coll room:dev --coll wiki:wiki --coll shop:store \\
          --coll drop:files --coll id:people
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import threading
import time

import mbfmt as F
from .host import Host, load_policy
from .node import serve, url_of
from .record import codec_for
from .views import host_rules

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
KIND_POLICY = {  # lighter limits for rooms; heavier for wiki/shop; 
    "room": {"rate": [[60, 600], [600, 86400]], "pow_bits": 12, "new_key_pow_bits": 14},
    "wiki": {"rate": [[20, 3600]], "pow_bits": 14, "new_key_pow_bits": 16},
    "shop": {"rate": [[20, 3600]], "pow_bits": 14, "new_key_pow_bits": 16},
    "drop": {"rate": [[10, 3600]], "pow_bits": 14, "new_key_pow_bits": 16},
    "id": {"rate": [[10, 3600]], "pow_bits": 12, "new_key_pow_bits": 14},
}


class BlobStore:
    """Content-addressed blobs for file drops: stored and served by SHA-256 only."""
    max_bytes = 2 * 1024 * 1024

    def __init__(self, d):
        self.d = d
        os.makedirs(d, exist_ok=True)

    def put(self, b: bytes):
        h = hashlib.sha256(b).hexdigest()
        p = os.path.join(self.d, h)
        if not os.path.exists(p):
            with open(p + ".tmp", "wb") as f:
                f.write(b)
            os.replace(p + ".tmp", p)
        return 200, {"ok": True, "sha256": h, "size": len(b)}

    def get(self, h):
        if not re.fullmatch(r"[0-9a-f]{64}", h or ""):
            return None
        p = os.path.join(self.d, h)
        if not os.path.exists(p):
            return None
        with open(p, "rb") as f:
            return f.read()


class Hub:
    def __init__(self, data_dir, root_key, host_key, colls: list[tuple[str, str]],
                 policy_extra: dict | None = None, clock=time.time, pol_override=None,
                 delegations: dict | None = None):
        self.nodes, self.kinds = {}, {}
        for kind, name in colls:
            if not NAME_RE.match(name) or kind not in KIND_POLICY:
                raise SystemExit(f"bad collection {kind}:{name}")
            if delegations is not None:
                d = delegations[name]
            else:
                d = F.make_delegation(root_key, name, F.pub_hex(host_key),
                                      int(clock()) + F.MAX_DELEGATION_S)
            pol = dict(KIND_POLICY[kind], kind=kind, **(policy_extra or {}))
            pol.update((pol_override or {}).get(kind, {}))
            h = Host(os.path.join(data_dir, name), name, host_key, d, load_policy(None, name, pol),
                     clock=clock, codec=codec_for(kind), rules=host_rules)
            if kind == "drop":
                h.blobs = BlobStore(os.path.join(data_dir, name, "blobs"))
            self.nodes[name], self.kinds[name] = h, kind

    def __call__(self, path):
        parts = path.split("/", 3)
        if len(parts) >= 4 and parts[1] == "c" and parts[2] in self.nodes:
            return self.nodes[parts[2]], "/" + parts[3]
        return None, None

    def collections(self):
        return {"collections": [{"name": n, "kind": self.kinds[n]} for n in self.nodes]}


def main():
    from .host import load_or_make_keys
    ap = argparse.ArgumentParser(description="typed-SNApp hub")
    ap.add_argument("--data", required=True)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=48810)
    ap.add_argument("--coll", action="append", required=True, help="kind:name")
    ap.add_argument("--admin", action="append", default=[], help="admin key hex")
    ap.add_argument("--seller", action="append", default=[], help="seller key hex")
    ap.add_argument("--delegation-dir",
                    help="dir of <collection>.json delegations signed by an offline root")
    a = ap.parse_args()
    colls = [tuple(c.split(":", 1)) for c in a.coll]
    if a.delegation_dir:
        from .host import load_host_key, load_signed_delegation
        hk, root = load_host_key(a.data), None
        dels = {n: load_signed_delegation(os.path.join(a.delegation_dir, n + ".json"), n, hk)
                for _, n in colls}
        pins = {e["delegation"]["root"] for e in dels.values()}
        if len(pins) != 1:
            raise SystemExit("all collections must share one root")
        root_pin = pins.pop()
    else:
        root, hk, _ = load_or_make_keys(a.data, "hub")
        dels, root_pin = None, F.pub_hex(root)
    hub = Hub(a.data, root, hk, colls, {"admins": a.admin, "sellers": a.seller},
              delegations=dels)
    srv = serve(hub, a.bind, a.port)
    print(json.dumps({"url": url_of(srv), "root_pin": root_pin,
                      "collections": hub.collections()["collections"]}), flush=True)
    threading.Event().wait()


if __name__ == "__main__":
    main()
