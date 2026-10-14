// Template toolkit (bundled into every template, hashed in the registry entry).
// Rules every template follows: render record data with textContent only; never touch the
// network (the CSP forbids it anyway); talk to the core only through tk.send().
"use strict";
const tk = {
  view: null,
  send(msg) { parent.postMessage(msg, "*"); },
  draft(t, body, refs) { tk.send({type: "draft", t, body, refs: refs || []}); },
  act(name, target) { tk.send({type: "action", name, target}); },
  el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined && text !== null) e.textContent = String(text); return e; },
  btn(label, fn) { const b = tk.el("button", null, label); b.addEventListener("click", fn); return b; },
  when(ts) { return new Date(ts * 1000).toLocaleString(); },
  root() { const r = document.getElementById("root"); r.replaceChildren(); return r; },
  onView(fn) {
    window.addEventListener("message", (ev) => {
      if (ev.source !== parent) return;
      const m = ev.data; if (m && m.type === "view") { tk.view = m.data; fn(m.data); }
    });
    tk.send({type: "ready"});
  },
  status(v) { const s = tk.el("div", "muted", (v.rules ? "Rules: " + v.rules : "")); return s; },
};
