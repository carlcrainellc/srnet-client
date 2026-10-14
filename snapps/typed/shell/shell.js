// Trusted shell.  Talks to the core API (X-Core header) and relays verified views into the
// sandboxed template frame.  Messages from the frame are untrusted requests: only "ready",
// "draft", "action", "delete", "pay", "download", the file messages ("open", "link", "request",
// "access", "approve", "newver") and (test mode) "report" are understood. Keys and links stay here and in the core; and
// drafts are shown in this trusted sheet before the core signs anything.
"use strict";
let S = null, cur = null, frame = null, timer = null;
const $ = (id) => document.getElementById(id);
async function api(path, body, raw) {
  const opt = {headers: {"X-Core": "1"}};
  if (body !== undefined) { opt.method = "POST"; opt.headers["Content-Type"] = raw ? "application/octet-stream" : "application/json"; opt.body = raw ? body : JSON.stringify(body); }
  const r = await fetch("/api/" + path, opt);
  return r.json();
}
function el(t, txt) { const e = document.createElement(t); if (txt !== undefined) e.textContent = String(txt); return e; }
function sheet(title, sub, lines, buttons, pw) {
  $("sheet-pwl").hidden = !pw; $("sheet-pw").value = "";
  $("sheet-title").textContent = title; $("sheet-sub").textContent = sub || "";
  $("sheet-body").textContent = lines.join("\n");
  const b = $("sheet-buttons"); b.replaceChildren();
  buttons.forEach(([label, fn]) => { const x = el("button", label); x.addEventListener("click", async () => { $("sheet").hidden = true; await fn(); }); b.appendChild(x); });
  $("sheet").hidden = false;
}
async function saveFile(path, body) {
  const r = await fetch("/api/" + path, {method: "POST", headers: {"X-Core": "1", "Content-Type": "application/json"}, body: JSON.stringify(body)});
  if (!r.ok) { const e = await r.json().catch(() => ({})); $("status").textContent = "can't open: " + (e.error || r.status); return; }
  const cd = r.headers.get("Content-Disposition") || ""; const m = /filename="([^"]+)"/.exec(cd);
  const url = URL.createObjectURL(await r.blob()); const a = el("a"); a.href = url; a.download = m ? m[1] : "file"; a.click(); URL.revokeObjectURL(url);
}
function draftSheet(d, title) {
  if (d.error) { $("status").textContent = "refused: " + d.error; return; }
  if (d.result) { push(); return; }
  sheet(title || "Sign and post?", d.collection + " · " + d.t, d.lines, [["Sign & post", async () => { const r = await api("confirm", {token: d.token}); $("status").textContent = r.ok ? "posted" : (r.queued ? "queued in outbox" : "refused: " + r.error); push(); }], ["Cancel", async () => api("cancel", {token: d.token})]]);
}
async function onFile(m) {
  const id = String(m.id || ""), c = cur.name;
  if (m.type === "open") return sheet("Open file?", "fetched by hash, decrypted on this computer", ["file: " + id], [["Open", async () => saveFile("file/open", {c, id})], ["Cancel", async () => {}]]);
  if (m.type === "link") { const r = await api("file/link", {c, id}); if (r.error) { $("status").textContent = r.error; return; }
    return sheet("Public link", r.note, [r.link], [["Copy", async () => { try { await navigator.clipboard.writeText(r.link); } catch (e) {} }], ["Close", async () => {}]]); }
  if (m.type === "request") { const note = prompt("Note to the owner (optional)") || ""; return draftSheet(await api("file/request", {c, id, note}), "Ask the owner for access?"); }
  if (m.type === "approve") return draftSheet(await api("file/approve", {c, request: String(m.request || "")}), "Share this file with the requester?");
  if (m.type === "newver") { $("upload").dataset.prev = id; $("status").textContent = "pick the new file and press upload; revoked people won't get it"; return; }
  if (m.type === "access") { const r = await api("file/access", {c, id}); if (r.error) { $("status").textContent = r.error; return; }
    const lines = ["mode: " + r.mode, "shared with: " + (r.recipients.length ? "" : "nobody else")].concat(r.recipients.map((k) => "  " + k), r.revoked.length ? ["revoked: " + r.revoked.length] : [], [r.note]);
    const btns = [["Share with…", async () => { const to = (prompt("Their key (profile key or encryption key)") || "").trim(); if (to) draftSheet(await api("file/grant", {c, id, to}), "Share this file?"); }]];
    r.recipients.forEach((k) => btns.push(["Revoke " + k.slice(0, 8) + "…", async () => draftSheet(await api("file/revoke", {c, id, to: k}), "Revoke for future versions?")]));
    btns.push(["Close", async () => {}]);
    return sheet("Who can open this file", "", lines, btns); }
}
function post(msg) { if (frame && frame.contentWindow) frame.contentWindow.postMessage(msg, "*"); }
async function push() { if (!cur) return; const v = await api("view/" + encodeURIComponent(cur.name)); post({type: "view", data: v});
  const st = v.status || {}; $("status").textContent = cur.name + " · " + (st.error ? "STALE: " + st.error : "verified via " + (st.host || "-")) + (v.hidden ? " · " + v.hidden + " hidden by host" : ""); }
function open(c) {
  cur = c; document.querySelectorAll("#tabs button").forEach((b) => b.classList.toggle("on", b.dataset.name === c.name));
  $("upload").hidden = c.kind !== "drop";
  frame.src = "/frame/" + encodeURIComponent(c.template) + "?c=" + encodeURIComponent(c.name);
  clearInterval(timer); timer = setInterval(push, c.kind === "room" ? 1500 : 4000);
}
async function onDraft(m) {
  const d = await api("draft", {c: cur.name, t: String(m.t), body: m.body || {}, refs: Array.isArray(m.refs) ? m.refs : []});
  if (d.error) { $("status").textContent = "draft refused: " + d.error; return; }
  if (d.result) { push(); return; }
  sheet("Sign and post?", d.collection + " · " + d.t + (d.refs.length ? " · refs " + d.refs.join(",") : ""), d.lines,
    [["Sign & post", async () => { const r = await api("confirm", {token: d.token}); $("status").textContent = r.ok ? "posted" : (r.queued ? "queued in outbox" : "refused: " + r.error); push(); }],
     ["Cancel", async () => api("cancel", {token: d.token})]]);
}
window.addEventListener("message", async (ev) => {
  if (!frame || ev.source !== frame.contentWindow || ev.origin !== "null") return; // only our sandboxed frame
  const m = ev.data; if (!m || typeof m !== "object") return;
  try {
    if (m.type === "ready") return push();
    if (m.type === "draft") return onDraft(m);
    if (m.type === "action") { await api("action", {name: String(m.name), args: {target: String(m.target || "")}}); return push(); }
    if (m.type === "delete") { await api("delete", {c: cur.name, id: String(m.id)}); return push(); }
    if (m.type === "pay") { const r = await api("pay", {c: cur.name, listing: String(m.listing)});
      if (!r.ok) { $("status").textContent = "payment refused: " + r.error; return; }
      const s = r.sheet;
      if (r.srnet) return sheet(s.title, s.note, s.lines, [["Pay", async () => { const pr = await api("pay/confirm", {token: r.token, passphrase: $("sheet-pw").value}); $("sheet-pw").value = "";
        $("status").textContent = pr.ok ? "paid " + (pr.amount / 1e6).toFixed(2) + " USDC (lease " + pr.lease_id + ")" : "payment failed: " + pr.error; push(); }], ["Cancel", async () => {}]], true);
      return sheet("Payment details (" + s.network + ")", s.note, ["item: " + s.item, "seller: " + s.seller, "amount: " + s.amount + " " + s.currency, "to: " + s.to, "chain id: " + s.chain_id], [["Close", async () => {}]]); }
    if (m.type === "download" && /^[0-9a-f]{64}$/.test(m.sha256)) {
      return sheet("Download file?", "verified by hash before saving", ["sha256: " + m.sha256], [["Download", async () => {
        const r = await fetch("/api/blob/" + encodeURIComponent(cur.name) + "/" + m.sha256, {headers: {"X-Core": "1"}});
        if (!r.ok) { $("status").textContent = "blob unavailable"; return; }
        const url = URL.createObjectURL(await r.blob()); const a = el("a"); a.href = url; a.download = m.sha256.slice(0, 12) + ".bin"; a.click(); URL.revokeObjectURL(url); }], ["Cancel", async () => {}]]); }
    if (m.type === "verify") { const r = await api("pay/verify", {c: cur.name, order: String(m.order || "")}); $("status").textContent = r.ok ? (r.paid ? "order paid on-chain" : "NOT paid on-chain") : r.error; return; }
    if (["open", "link", "request", "approve", "newver", "access"].includes(m.type)) return onFile(m);
    if (m.type === "report" && S.test) { $("report").hidden = false; $("report").textContent += JSON.stringify(m.data) + "\n"; return; }
  } catch (e) { $("status").textContent = "error: " + e; }
});
document.addEventListener("DOMContentLoaded", async () => {
  frame = $("tpl"); S = await api("collections");
  S.collections.forEach((c) => { const b = el("button", c.name + " (" + c.kind + ")"); b.dataset.name = c.name; b.addEventListener("click", () => open(c)); $("tabs").appendChild(b); });
  $("modtoggle").addEventListener("click", async () => { const on = $("modtoggle").dataset.on === "1"; await api("moderation", {mode: on ? "honour" : "ignore"}); $("modtoggle").dataset.on = on ? "0" : "1"; $("modtoggle").textContent = on ? "Show host-hidden" : "Honour host hides"; push(); });
  $("send-file").addEventListener("click", async () => { const f = $("file").files[0]; if (!f) return;
    const prev = $("upload").dataset.prev || ""; delete $("upload").dataset.prev;
    const q = "upload?c=" + encodeURIComponent(cur.name) + "&name=" + encodeURIComponent(f.name) + "&mime=" + encodeURIComponent(f.type || "application/octet-stream") + "&note=" + encodeURIComponent($("note").value) + "&mode=" + encodeURIComponent($("mode").value) + "&to=" + encodeURIComponent($("to").value) + (prev ? "&prev=" + encodeURIComponent(prev) : "");
    if ($("mode").value === "plain" && !confirm("This file will be stored unencrypted and anyone can read it. Continue?")) return;
    const d = await api(q, await f.arrayBuffer(), true);
    if (d.token) sheet("Sign and share this file?", d.collection, d.lines, [["Sign & post", async () => { await api("confirm", {token: d.token}); push(); }], ["Cancel", async () => api("cancel", {token: d.token})]]);
    else $("status").textContent = "upload failed: " + (d.error || "?"); });
  $("openlink-go").addEventListener("click", async () => { const link = $("openlink").value.trim(); if (link) await saveFile("file/openlink", {link}); });
  const want = new URLSearchParams(location.search).get("c");
  const first = S.collections.find((c) => c.name === want) || S.collections[0];
  if (first) open(first);
});
