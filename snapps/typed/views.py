"""Type semantics, computed identically by hosts (where cheap) and clients.

All functions take `items`: verified records in log order, each
{"id","seq","t","author","ts","body","refs"} — and the collection policy (for admins/sellers).
Templates only ever see the output of these functions."""
from __future__ import annotations

import hashlib

import mbfmt as F


def items_from_store(store, codec) -> list[dict]:
    out = []
    for e in store.since(0, 1 << 30):
        if "env" not in e:
            out.append({"id": e["id"], "seq": e["seq"], "t": "tombstone",
                        "by": e["tomb"].get("by")})
            continue
        m = codec.verify(e["env"], None)  # already verified on entry; re-derive fields
        out.append({"id": m.id, "seq": e["seq"], "t": m.t, "author": m.author, "ts": m.ts,
                    "body": m.body, "refs": m.refs})
    return out


def key_hash(pub_hex: str) -> str:
    """Commitment to a recovery key: SHA-256 of the hex public key string."""
    return hashlib.sha256(("srnet-typed/recovery/v1\n" + pub_hex).encode()).hexdigest()


# ---- identity --------------------------------------------------------------------------
def identities(items: list[dict]) -> dict:
    """Resolve profiles, rotations (with recovery override), links.

    Rules:
      * id.rotate signed by old_key itself moves old_key -> new_key (or retires it if null).
      * A recovery rotation is signed by key R with key_hash(R) == next_key_hash committed in
        old_key's latest profile *before* the rotation; it overrides any rotation the old key
        made after that commitment (a thief holding the old key can't keep control).
      * Handles are never unique: display is always "name·<first 6 hex of key>".
    Returns {"profiles": {key: {...}}, "current": {key: final_key|None}, "labels": {key: str},
             "links": {key: [other_keys]}}"""
    profiles, commit, rot, links = {}, {}, {}, {}
    for it in items:
        t, a, b = it.get("t"), it.get("author"), it.get("body", {})
        if t == "id.profile":
            profiles[a] = dict(b, key=a, ts=it["ts"], seq=it["seq"])
            if b.get("next_key_hash") and a not in commit:
                # first commitment is binding: a thief who later publishes a new profile
                # cannot swap in their own recovery key (to change it, rotate to a new key)
                commit[a] = (b["next_key_hash"], it["seq"])
        elif t == "id.rotate":
            old = b["old_key"]
            if a == old:
                cur = rot.get(old)
                if cur is None or not cur["recovery"]:
                    rot[old] = {"to": b.get("new_key"), "seq": it["seq"], "recovery": False}
            else:
                c = commit.get(old)
                if c and key_hash(a) == c[0] and c[1] < it["seq"]:
                    rot[old] = {"to": b.get("new_key"), "seq": it["seq"], "recovery": True}
        elif t == "id.link":
            links.setdefault(a, set()).add(b["other_key"])
    current = {}

    def final(k, depth=0):
        if k is None or depth > 20:
            return k
        r = rot.get(k)
        return final(r["to"], depth + 1) if r else k
    for k in set(profiles) | set(rot):
        current[k] = final(k)
    labels = {}
    for k in set(profiles) | set(rot):
        f = current.get(k, k)
        name = (profiles.get(f) or profiles.get(k) or {}).get("name") or "anon"
        labels[k] = f"{name}·{(f or k)[:6]}" + (" (retired)" if f is None else "")
    mutual = {a: sorted(x for x in s if a in links.get(x, set())) for a, s in links.items()}
    return {"profiles": profiles, "current": current, "labels": labels,
            "rotations": rot, "links": mutual}


def label(ids, key):
    return ids["labels"].get(key) or f"anon·{key[:6]}"


# ---- rooms -----------------------------------------------------------------------------
def room_view(items, policy) -> dict:
    admins = set(policy.get("admins", []))
    ids = identities(items)
    nicks, topic, lines = {}, None, []
    for it in items:
        t = it.get("t")
        if t == "room.join":
            nicks[it["author"]] = it["body"]["nick"]
        elif t == "room.topic" and it["author"] in admins:
            topic = {"text": it["body"]["text"], "by": label(ids, it["author"]), "ts": it["ts"]}
        elif t == "room.msg":
            a = it["author"]
            lines.append({"id": it["id"], "seq": it["seq"], "ts": it["ts"], "author": a,
                          "who": f"{nicks.get(a) or ids['profiles'].get(a, {}).get('name') or 'anon'}·{a[:6]}",
                          "text": it["body"]["text"], "reply_to": (it["refs"] or [None])[0]})
    return {"topic": topic, "lines": lines}


# ---- wiki ------------------------------------------------------------------------------
def wiki_view(items, policy) -> dict:
    """Linear revision history per page.  A wiki.rev must name the current head as its parent
    (or no parent for the first revision); edits with a stale parent are kept as conflicts.
    Protected pages accept revisions/reverts only from admin keys (policy, hash-bound)."""
    admins = set(policy.get("admins", []))
    ids = identities(items)
    pages, revs = {}, {}
    for it in items:
        t, b = it.get("t"), it.get("body", {})
        if t not in ("wiki.page", "wiki.rev", "wiki.revert", "wiki.protect"):
            continue
        slug = b["slug"]
        p = pages.setdefault(slug, {"slug": slug, "title": slug, "head": None, "text": "",
                                    "protected": False, "history": [], "conflicts": []})
        a = it["author"]
        if t == "wiki.page":
            if not p["history"] and (not p["protected"] or a in admins):
                p["title"] = b["title"]
        elif t == "wiki.protect":
            if a in admins:
                p["protected"] = b["on"]
        else:
            if p["protected"] and a not in admins:
                p["conflicts"].append({"id": it["id"], "why": "page protected"})
                continue
            parent = (it["refs"] or [None])[0]
            if t == "wiki.rev":
                if parent != p["head"]:
                    p["conflicts"].append({"id": it["id"], "why": "stale parent"})
                    continue
                text = b["text"]
            else:  # revert: refs[0] is an earlier revision of this page
                tgt = revs.get(parent)
                if not tgt or tgt["slug"] != slug:
                    p["conflicts"].append({"id": it["id"], "why": "bad revert target"})
                    continue
                text = tgt["text"]
            revs[it["id"]] = {"slug": slug, "text": text}
            p["head"], p["text"] = it["id"], text
            p["history"].append({"id": it["id"], "t": t, "by": label(ids, a), "ts": it["ts"],
                                 "summary": b.get("summary") or ""})
    return {"pages": pages}


# ---- shop ------------------------------------------------------------------------------
def shop_view(items, policy) -> dict:
    """Listings only from policy sellers; prices and payment targets are passed through
    verbatim for the core's own payment sheet (templates never build payments)."""
    sellers = set(policy.get("sellers", []))
    ids = identities(items)
    listings, reviews = {}, {}
    for it in items:
        t, a, b = it.get("t"), it.get("author"), it.get("body", {})
        if t == "shop.listing" and a in sellers:
            listings[it["id"]] = dict(b, id=it["id"], seller=a, seller_label=label(ids, a),
                                      ts=it["ts"], active=True)
        elif t == "shop.withdraw":
            lid = (it["refs"] or [None])[0]
            if lid in listings and listings[lid]["seller"] == a:
                listings[lid]["active"] = False
        elif t == "shop.review":
            lid = (it["refs"] or [None])[0]
            if lid in listings and listings[lid]["seller"] != a:
                reviews.setdefault(lid, {})[a] = {"by": label(ids, a), "rating": b["rating"],
                                                  "text": b.get("text") or ""}
    for lid, l in listings.items():
        rs = list(reviews.get(lid, {}).values())
        l["reviews"] = rs
        l["rating"] = round(sum(r["rating"] for r in rs) / len(rs), 2) if rs else None
    return {"listings": list(listings.values())}


# ---- drop ------------------------------------------------------------------------------
def drop_view(items, policy) -> dict:
    ids = identities(items)
    return {"items": [dict(it["body"], id=it["id"], by=label(ids, it["author"]), ts=it["ts"])
                      for it in items if it.get("t") == "drop.item"]}


VIEWS = {"room": room_view, "wiki": wiki_view, "shop": shop_view, "drop": drop_view,
         "id": lambda items, policy: {}}


def host_rules(host, meta) -> str | None:
    """Host-side admission rules (clients apply the same rules in the views)."""
    pol = host.policy
    if meta.t in ("shop.listing", "shop.withdraw") and meta.author not in pol.get("sellers", []):
        return "only the store's seller keys may list or withdraw"
    if meta.t in ("wiki.protect", "room.topic") and meta.author not in pol.get("admins", []):
        return f"{meta.t} needs an admin key"
    if meta.t == "shop.listing":
        from .record import TESTNET_CHAINS
        if meta.body["chain_id"] not in TESTNET_CHAINS and not pol.get("allow_mainnet"):
            return "payments are testnet-only on this store"
    return None
