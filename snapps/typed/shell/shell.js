// Trusted shell.  Talks to the core API (X-Core header) and relays verified views into the
// sandboxed template frame.  Messages from the frame are untrusted requests: only "ready",
// "draft", "action", "delete", "pay", "download" and (test mode) "report" are understood, and
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
function sheet(title, sub, lines, buttons) {
  $("sheet-title").textContent = title; $("sheet-sub").textContent = sub || "";
  $("sheet-body").textContent = lines.join("\n");
  const b = $("sheet-buttons"); b.replaceChildren();
  buttons.forEach(([label, fn]) => { const x = el("button", label); x.addEventListener("click", async () => { $("sheet").hidden = true; await fn(); }); b.appendChild(x); });
  $("sheet").hidden = false;
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
      const s = r.sheet; return sheet("Payment details (" + s.network + ")", s.note, ["item: " + s.item, "seller: " + s.seller, "amount: " + s.amount + " " + s.currency, "to: " + s.to, "chain id: " + s.chain_id], [["Close", async () => {}]]); }
    if (m.type === "download" && /^[0-9a-f]{64}$/.test(m.sha256)) {
      return sheet("Download file?", "verified by hash before saving", ["sha256: " + m.sha256], [["Download", async () => {
        const r = await fetch("/api/blob/" + encodeURIComponent(cur.name) + "/" + m.sha256, {headers: {"X-Core": "1"}});
        if (!r.ok) { $("status").textContent = "blob unavailable"; return; }
        const url = URL.createObjectURL(await r.blob()); const a = el("a"); a.href = url; a.download = m.sha256.slice(0, 12) + ".bin"; a.click(); URL.revokeObjectURL(url); }], ["Cancel", async () => {}]]); }
    if (m.type === "report" && S.test) { $("report").hidden = false; $("report").textContent += JSON.stringify(m.data) + "\n"; return; }
  } catch (e) { $("status").textContent = "error: " + e; }
});
document.addEventListener("DOMContentLoaded", async () => {
  frame = $("tpl"); S = await api("collections");
  S.collections.forEach((c) => { const b = el("button", c.name + " (" + c.kind + ")"); b.dataset.name = c.name; b.addEventListener("click", () => open(c)); $("tabs").appendChild(b); });
  $("modtoggle").addEventListener("click", async () => { const on = $("modtoggle").dataset.on === "1"; await api("moderation", {mode: on ? "honour" : "ignore"}); $("modtoggle").dataset.on = on ? "0" : "1"; $("modtoggle").textContent = on ? "Show host-hidden" : "Honour host hides"; push(); });
  $("send-file").addEventListener("click", async () => { const f = $("file").files[0]; if (!f) return;
    const q = "upload?c=" + encodeURIComponent(cur.name) + "&name=" + encodeURIComponent(f.name) + "&mime=" + encodeURIComponent(f.type || "application/octet-stream") + "&note=" + encodeURIComponent($("note").value);
    const d = await api(q, await f.arrayBuffer(), true);
    if (d.token) sheet("Sign and share this file?", d.collection, d.lines, [["Sign & post", async () => { await api("confirm", {token: d.token}); push(); }], ["Cancel", async () => api("cancel", {token: d.token})]]);
    else $("status").textContent = "upload failed: " + (d.error || "?"); });
  const want = new URLSearchParams(location.search).get("c");
  const first = S.collections.find((c) => c.name === want) || S.collections[0];
  if (first) open(first);
});
