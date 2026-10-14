"""Typed-SNApp client core.

The core is the only trusted part of the client.  It
  * pins collection root keys and the template registry key,
  * syncs and verifies every record (typed/sync.py) and computes views (typed/views.py),
  * runs each template in a sandboxed iframe with no network, sending it only verified views
    by postMessage (via the trusted shell page),
  * accepts *drafts* from templates, validates them, shows them in its own confirmation sheet,
    and only then signs (with the author key the template never sees) and submits,
  * shows payment targets in its own payment sheet (testnet only; never sends anything),
  * serves plain-HTML .sesh pages only through the locked-down viewer (typed/htmlview.py).

Run:  python3 -m typed.core --config client.json --data DIR [--port 48920]
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import mbfmt as F
from . import adapters, htmlview, views
from .record import BOARD, KIND_TYPES, TESTNET_CHAINS, codec_for, make_record
from .registry import RegistryError, TemplateManager
from .store import Store
from .sync import SyncError, http_json, submit, sync_once

HERE = Path(__file__).resolve().parent
TEMPLATES = HERE / "templates"
SHELL = HERE / "shell"
KIND_TEMPLATE = {"board": "board", "room": "room", "wiki": "wiki", "shop": "shop",
                 "drop": "drop", "id": "profile", "exit": "exit", "card": "card"}
SHELL_CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; "
             "frame-src 'self'; img-src 'none'; base-uri 'none'; form-action 'none'; "
             "frame-ancestors 'none'")
ACTIONS = {"follow", "unfollow", "mute", "unmute", "reveal", "unreveal"}


def _b64(b):
    return base64.b64encode(b).decode()


class Coll:
    def __init__(self, core, cfg):
        self.name, self.kind = cfg["name"], cfg["kind"]
        self.cfg, self.core = cfg, core
        self.hosts = list(cfg.get("hosts", []))
        self.policy, self.last, self.view_cache = {}, {"host": None, "error": None}, None
        if self.kind in ("exit", "card"):
            self.store = None
            return
        self.root_pin = cfg["root_pin"]
        self.codec = codec_for(self.kind)
        d = Path(core.dir) / "c" / self.name
        d.mkdir(parents=True, exist_ok=True)
        self.store = Store(str(d / "cache.sqlite3"))
        self.pin = F.CheckpointPin(*self.store.head())

    def sync(self):
        if self.kind == "exit":
            try:
                v = adapters.exit_view(self.hosts[0], self.cfg["pin_sesh"],
                                       seen=self.core.prefs["exit_seen"].get(self.name))
                self.core.prefs["exit_seen"][self.name] = v.pop("seen")
                self.view_cache, self.last = v, {"host": self.hosts[0], "error": None}
            except Exception as e:  # stale cache stays visible, marked
                self.last = {"host": None, "error": f"{type(e).__name__}: {e}"}
            return self.last
        if self.kind == "card":
            try:
                src = self.cfg.get("url")
                card = json.loads(urllib.request.urlopen(src, timeout=8).read(1 << 16)) if src \
                    else json.loads(Path(self.cfg["path"]).read_text())
                self.view_cache = adapters.card_view(card, self.cfg.get("expect_pubkey"))
                self.last = {"host": src or "file", "error": None}
            except Exception as e:
                self.last = {"host": None, "error": f"{type(e).__name__}: {e}"}
            return self.last
        order = sorted(self.hosts, key=lambda h: h != self.last.get("host"))
        try:
            r = sync_once(self.store, order, self.root_pin, self.name, self.pin, codec=self.codec)
            self.policy = r.get("policy") or {}
            self.last = {"host": r["host"], "error": None, "added": r["added"]}
        except SyncError as e:
            self.last = dict(self.last, error=str(e))
        return self.last


class Core:
    def __init__(self, data_dir, config: dict, autoconfirm=False, clock=time.time):
        self.dir = Path(data_dir)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.clock, self.autoconfirm = clock, autoconfirm
        kp = self.dir / "author.key"  # posting key: NOT the Session Router transport key
        if not kp.exists():
            with open(os.open(kp, os.O_WRONLY | os.O_CREAT, 0o600), "wb") as f:
                f.write(os.urandom(32))
        self.key = F.key_from_seed(kp.read_bytes())
        self.me = F.pub_hex(self.key)
        self.prefs_p = self.dir / "prefs.json"
        self.prefs = {"follows": [], "mutes": [], "moderation": "honour", "revealed": [],
                      "exit_seen": {}, "outbox": []}
        if self.prefs_p.exists():
            self.prefs.update(json.loads(self.prefs_p.read_text()))
        reg = config.get("registry") or json.loads((TEMPLATES / "registry.json").read_text())
        self.templates = TemplateManager(self.dir, reg["pin"], TEMPLATES, reg["entries"], clock)
        self.colls = {c["name"]: Coll(self, c) for c in config.get("collections", [])}
        self.sites = config.get("html_sites", {})
        self.drafts, self.lock = {}, threading.RLock()
        self.blob_cache = self.dir / "blobs"
        self.blob_cache.mkdir(exist_ok=True)

    def save(self):
        tmp = self.prefs_p.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.prefs))
        os.replace(tmp, self.prefs_p)

    # ---- sync ----
    def sync(self, name=None):
        out = {}
        for c in ([self.colls[name]] if name else self.colls.values()):
            out[c.name] = c.sync()
        self.save()
        if self.prefs["outbox"]:
            self.flush_outbox()
        return out

    # ---- moderation filter (host-signed records, user override) ----
    def _hidden(self, c):
        hp, ha = {}, {}
        for r in c.store.records_since(0, 1 << 30):
            if r["kind"] == "mod":
                m = r["rec"]["mod"]
                (hp if m["target_type"] == "post" else ha)[m["target"]] = m["action"] == "hide"
        return {k for k, v in hp.items() if v}, {k for k, v in ha.items() if v}

    def _items(self, c):
        items = views.items_from_store(c.store, c.codec)
        hp, ha = self._hidden(c)
        mutes = set(self.prefs["mutes"])
        out, hidden = [], 0
        for it in items:
            if it["t"] == "tombstone":
                out.append(it)
                continue
            if it["author"] in mutes:
                continue
            if self.prefs["moderation"] != "ignore" and it["id"] not in self.prefs["revealed"] \
                    and (it["id"] in hp or it["author"] in ha):
                hidden += 1
                continue
            out.append(it)
        return out, hidden

    def view(self, name):
        c = self.colls[name]
        base = {"collection": name, "kind": c.kind, "me": self.me[:6], "me_key": self.me,
                "status": c.last, "rules": (c.policy or {}).get("rules", ""),
                "template": KIND_TEMPLATE[c.kind]}
        if c.kind in ("exit", "card"):
            return dict(base, view=c.view_cache or {}, hidden=0)
        items, hidden = self._items(c)
        if c.kind == "board":
            ids = views.identities(items)
            posts = [it for it in items if it["t"] == "board.post"]
            replies = {}
            for p in posts:
                if p["body"]["reply_to"]:
                    replies[p["body"]["reply_to"]] = replies.get(p["body"]["reply_to"], 0) + 1
            v = {"posts": [{"id": p["id"], "seq": p["seq"], "ts": p["ts"], "author": p["author"],
                            "who": views.label(ids, p["author"]), "text": p["body"]["text"],
                            "reply_to": p["body"]["reply_to"], "replies": replies.get(p["id"], 0),
                            "mine": p["author"] == self.me,
                            "followed": p["author"] in self.prefs["follows"]}
                           for p in reversed(posts)]}
        elif c.kind == "id":
            ids = views.identities(items)
            v = {"people": [{"key": k, "label": ids["labels"][k], "name": p.get("name"),
                             "bio": p.get("bio") or "", "current": ids["current"].get(k, k),
                             "recovery_committed": bool(p.get("next_key_hash")),
                             "rotation": ids["rotations"].get(k)}
                            for k, p in ids["profiles"].items()],
                 "rotations": [{"from": k, **r} for k, r in ids["rotations"].items()]}
        else:
            v = views.VIEWS[c.kind](items, c.policy or {})
        return dict(base, view=v, hidden=hidden)

    # ---- drafts: template proposes, core validates, user confirms, core signs ----
    def draft(self, name, t, body, refs):
        c = self.colls.get(name)
        if not c or c.kind in ("exit", "card"):
            raise F.FormatError("read-only collection")
        if not isinstance(body, dict) or not isinstance(refs, list):
            raise F.FormatError("bad draft")
        if c.kind == "board":
            if t != "board.post":
                raise F.FormatError("board only accepts board.post")
            rt = body.get("reply_to") or (refs[0] if refs else None)
            F.make_post(self.key, name, str(body.get("text", "")), rt)  # validation only
            body = {"text": body.get("text"), "reply_to": rt}
        else:
            spec = KIND_TYPES[c.kind].get(t, 1)
            spec.check_body({k: v for k, v in body.items() if v is not None}, refs)
            if t == "id.profile" and body.get("next_key_hash") is None:
                pass
        tok = secrets.token_hex(12)
        with self.lock:
            self.drafts[tok] = {"collection": name, "t": t, "body": body, "refs": refs,
                                "at": self.clock()}
        prev = {"token": tok, "collection": name, "t": t,
                "lines": [f"{k}: {v}" for k, v in body.items() if v not in (None, "")],
                "refs": refs}
        if self.autoconfirm:
            return dict(prev, result=self.confirm(tok))
        return prev

    def _pow(self, c):
        pol = c.policy or {}
        mine = c.store.db.execute("SELECT MIN(ts) FROM log WHERE author=?", (self.me,)).fetchone()[0]
        new = mine is None or self.clock() - mine < pol.get("new_key_age_s", 86400)
        return pol.get("new_key_pow_bits" if new else "pow_bits")

    def _sign_submit(self, d):
        c = self.colls[d["collection"]]
        if not c.policy:
            c.sync()
        bits = self._pow(c)
        if bits is None:
            return {"ok": False, "unreachable": True, "error": "no host reachable"}
        if c.kind == "board":
            env = F.make_post(self.key, c.name, d["body"]["text"], d["body"]["reply_to"],
                              pow_bits=bits)
        else:
            env = make_record(self.key, KIND_TYPES[c.kind], c.name, d["t"], d["body"], d["refs"],
                              pow_bits=bits)
        r = submit(c.hosts, env)
        if r.get("ok"):
            c.sync()
        return r

    def confirm(self, tok):
        with self.lock:
            d = self.drafts.pop(tok, None)
        if not d:
            return {"ok": False, "error": "unknown or already used draft"}
        r = self._sign_submit(d)
        if r.get("unreachable"):
            self.prefs["outbox"].append(d)
            self.save()
            r = dict(r, queued=True)
        return r

    def cancel(self, tok):
        with self.lock:
            self.drafts.pop(tok, None)
        return {"ok": True}

    def flush_outbox(self):
        keep = []
        for d in self.prefs["outbox"]:
            r = self._sign_submit(d)
            if r.get("unreachable"):
                keep.append(d)
        self.prefs["outbox"] = keep
        self.save()

    def delete(self, name, rid):
        c = self.colls[name]
        if c.store.author_of(rid) != self.me:
            return {"ok": False, "error": "not your record"}
        r = submit(c.hosts, F.make_delete(self.key, name, [rid]), "/v1/delete")
        if r.get("ok"):
            c.sync()
        return r

    def action(self, name, args):
        if name not in ACTIONS:
            raise F.FormatError("unknown action")
        target = str(args.get("target", ""))
        kind = {"follow": "follows", "unfollow": "follows", "mute": "mutes", "unmute": "mutes",
                "reveal": "revealed", "unreveal": "revealed"}[name]
        if kind != "revealed":
            F.load_pub(target)
        s = set(self.prefs[kind])
        (s.discard if name.startswith("un") else s.add)(target)
        self.prefs[kind] = sorted(s)
        self.save()
        return {"ok": True}

    # ---- payments: core-owned sheet, testnet only, never sends ----
    def pay_draft(self, name, listing_id):
        c = self.colls[name]
        if c.kind != "shop":
            raise F.FormatError("not a store")
        l = next((x for x in views.shop_view(self._items(c)[0], c.policy or {})["listings"]
                  if x["id"] == listing_id), None)
        if not l or not l["active"]:
            raise F.FormatError("no such active listing")
        if l["chain_id"] not in TESTNET_CHAINS:
            raise F.FormatError("mainnet payments are disabled in this build")
        return {"ok": True, "sheet": {
            "network": TESTNET_CHAINS[l["chain_id"]], "chain_id": l["chain_id"],
            "to": l["pay_to"], "amount": l["price"], "currency": l["currency"],
            "item": l["title"], "seller": l["seller_label"], "listing": l["id"],
            "note": "Testnet only. Shown for the user's wallet; this client never sends funds."}}

    # ---- file drop blobs ----
    def upload(self, name, data: bytes, filename: str, mime: str, note: str = ""):
        c = self.colls[name]
        if c.kind != "drop":
            raise F.FormatError("not a drop")
        h = hashlib.sha256(data).hexdigest()
        ok = False
        for host in c.hosts:
            try:
                req = urllib.request.Request(host + "/v1/blob", data=data,
                                             headers={"Content-Type": "application/octet-stream"})
                with urllib.request.urlopen(req, timeout=15) as r:
                    ok = json.loads(r.read()).get("sha256") == h
                if ok:
                    break
            except OSError:
                continue
        if not ok:
            return {"ok": False, "error": "no host took the blob"}
        return self.draft(name, "drop.item", {"sha256": h, "size": len(data), "mime": mime,
                                              "name": filename, "note": note or None}, [])

    def blob(self, name, sha):
        if not re.fullmatch(r"[0-9a-f]{64}", sha):
            raise F.FormatError("bad hash")
        p = self.blob_cache / sha
        if p.exists():
            return p.read_bytes()
        for host in self.colls[name].hosts:
            try:
                b = urllib.request.urlopen(f"{host}/v1/blob/{sha}", timeout=15).read(3 << 20)
            except OSError:
                continue
            if hashlib.sha256(b).hexdigest() == sha:  # fetched by hash and checked
                p.write_bytes(b)
                return b
        return None

    # ---- template frames ----
    def frame(self, template):
        t = self.templates.load(template)
        if not t:
            return None, None
        f = t["files"]
        scripts = [f[n].decode() for n in ("tk.js", "app.js") if n in f]
        style = f.get("app.css", b"").decode()
        html = f["index.html"].decode()
        html = html.replace("<!--STYLE-->", f"<style>{style}</style>")
        html = html.replace("<!--SCRIPTS-->", "".join(f"<script>{s}</script>" for s in scripts))

        def h(s):
            return "'sha256-" + _b64(hashlib.sha256(s.encode()).digest()) + "'"
        csp = ("default-src 'none'; script-src " + " ".join(h(s) for s in scripts) +
               "; style-src " + h(style) + "; img-src 'none'; connect-src 'none'; "
               "font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; "
               "worker-src 'none'; form-action 'none'; base-uri 'none'; "
               "frame-ancestors 'self'; sandbox allow-scripts")
        return html.encode(), csp

    def viewer(self, name_path):
        name, _, path = name_path.partition("/")
        base = self.sites.get(name)
        if not base:
            return htmlview.render("<p>No route to this .sesh name in this prototype.</p>", name)
        u = urlparse(base)
        if u.hostname not in ("127.0.0.1", "localhost", "::1") and \
                not (u.hostname or "").endswith(".sesh"):
            return htmlview.render("<p>Clearnet requests are always blocked.</p>", name)
        try:
            with urllib.request.urlopen(base.rstrip("/") + "/" + path, timeout=10) as r:
                src = r.read(2_000_000).decode("utf-8", "replace")
        except OSError as e:
            src = f"<p>Could not load page: {type(e).__name__}</p>"
        return htmlview.render(src, name)


def make_handler(core: Core, test_mode=False):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, body, ctype, csp=SHELL_CSP, extra=()):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Security-Policy", csp)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Cache-Control", "no-store")
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _json(self, code, obj):
            self._send(code, json.dumps(obj).encode(), "application/json; charset=utf-8")

        def _api_ok(self):
            """Only the trusted shell may call the API: same loopback host, no foreign Origin,
            and the X-Core header (which navigations, forms and sandboxed frames can't add)."""
            hosthdr = (self.headers.get("Host") or "").rsplit(":", 1)[0]
            origin = self.headers.get("Origin")
            if hosthdr not in ("127.0.0.1", "localhost", "[::1]"):
                return False
            if origin is not None and urlparse(origin).hostname not in ("127.0.0.1", "localhost"):
                return False
            return self.headers.get("X-Core") == "1"

        def do_GET(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            static = {"/": ("shell.html", "text/html; charset=utf-8"),
                      "/shell.js": ("shell.js", "text/javascript; charset=utf-8"),
                      "/shell.css": ("shell.css", "text/css; charset=utf-8")}
            if u.path in static:
                n, ct = static[u.path]
                return self._send(200, (SHELL / n).read_bytes(), ct)
            if u.path.startswith("/frame/"):
                body, csp = core.frame(u.path.split("/")[2])
                if body is None:
                    return self._send(404, b"template unavailable", "text/plain", "default-src 'none'")
                return self._send(200, body, "text/html; charset=utf-8", csp)
            if u.path == "/viewer":
                page = core.viewer(q.get("name", [""])[0]).encode()
                return self._send(200, page, "text/html; charset=utf-8", htmlview.CSP)
            if not u.path.startswith("/api/") or not self._api_ok():
                return self._json(403, {"error": "core API: trusted shell only"})
            p = u.path[5:]
            try:
                if p == "collections":
                    return self._json(200, {"collections": [
                        {"name": c.name, "kind": c.kind, "template": KIND_TEMPLATE[c.kind]}
                        for c in core.colls.values()], "me": core.me,
                        "templates": core.templates.status(), "test": test_mode,
                        "outbox": len(core.prefs["outbox"])})
                if p.startswith("view/"):
                    return self._json(200, core.view(p[5:]))
                if p.startswith("blob/"):
                    _, name, sha = p.split("/")
                    b = core.blob(name, sha)
                    if b is None:
                        return self._json(404, {"error": "blob unavailable"})
                    return self._send(200, b, "application/octet-stream", "default-src 'none'; sandbox",
                                      [("Content-Disposition", f'attachment; filename="{sha[:12]}.bin"')])
            except (KeyError, ValueError, F.FormatError) as e:
                return self._json(400, {"error": str(e)})
            self._json(404, {"error": "not found"})

        def do_POST(self):
            u = urlparse(self.path)
            if not u.path.startswith("/api/") or not self._api_ok():
                return self._json(403, {"error": "core API: trusted shell only"})
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(min(n, 3 << 20))
            p = u.path[5:]
            try:
                if p == "upload":
                    q = parse_qs(u.query)
                    return self._json(200, core.upload(q["c"][0], raw, q.get("name", ["file"])[0][:128],
                                                       q.get("mime", ["application/octet-stream"])[0],
                                                       q.get("note", [""])[0]))
                a = json.loads(raw or b"{}")
                if p == "sync":
                    return self._json(200, core.sync(a.get("c")))
                if p == "draft":
                    return self._json(200, core.draft(a["c"], a["t"], a.get("body", {}),
                                                      a.get("refs", [])))
                if p == "confirm":
                    return self._json(200, core.confirm(a["token"]))
                if p == "cancel":
                    return self._json(200, core.cancel(a["token"]))
                if p == "delete":
                    return self._json(200, core.delete(a["c"], a["id"]))
                if p == "action":
                    return self._json(200, core.action(a["name"], a.get("args", {})))
                if p == "moderation":
                    if a.get("mode") not in ("honour", "ignore"):
                        raise ValueError("mode")
                    core.prefs["moderation"] = a["mode"]
                    core.save()
                    return self._json(200, {"ok": True})
                if p == "pay":
                    return self._json(200, core.pay_draft(a["c"], a["listing"]))
                if p == "registry/offer":
                    files = {k: base64.b64decode(v) for k, v in a["files"].items()}
                    return self._json(200, core.templates.offer(a["entry"], files))
                if p == "registry/approve":
                    return self._json(200, core.templates.approve(a["template"], a["ver"]))
                if p == "registry/withdraw":
                    return self._json(200, core.templates.apply_withdraw(a["withdraw"]))
            except (KeyError, ValueError, TypeError, F.FormatError, RegistryError) as e:
                return self._json(400, {"ok": False, "error": f"{type(e).__name__}: {e}"})
            self._json(404, {"error": "not found"})
    return H


def serve(core, port=0, test_mode=False, sync_every=2.0):
    srv = ThreadingHTTPServer(("127.0.0.1", port), make_handler(core, test_mode))
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    if sync_every:
        def loop():
            while True:
                time.sleep(sync_every)
                try:
                    core.sync()
                except Exception:
                    pass
        threading.Thread(target=loop, daemon=True).start()
    return srv


def main():
    ap = argparse.ArgumentParser(description="typed-SNApp client core")
    ap.add_argument("--config", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--port", type=int, default=48920)
    a = ap.parse_args()
    core = Core(a.data, json.loads(Path(a.config).read_text()))
    core.sync()
    srv = serve(core, a.port)
    print(f"typed client: http://127.0.0.1:{srv.server_address[1]}/  (author {core.me[:12]}…)",
          flush=True)
    threading.Event().wait()


if __name__ == "__main__":
    main()
