"use strict";
// Directory: hosts that opted in (each entry is signed by that collection's own root key).
// Join only asks the trusted shell to open its join sheet; nothing is joined from here.
function render(v) {
  const r = tk.root(); r.appendChild(tk.el("h2", null, "Directory · " + v.collection));
  r.appendChild(tk.el("div", "muted", "Each entry is signed by the root key of the collection it lists. Joining shows the host's signed info first."));
  const es = (v.view && v.view.entries) || [];
  if (!es.length) r.appendChild(tk.el("div", "muted", "No listings yet."));
  for (const e of es) {
    const d = tk.el("div", "item");
    d.appendChild(tk.el("span", "who", e.title));
    d.appendChild(tk.el("span", "muted", " · " + e.kind + " · " + e.name));
    if (e.desc) d.appendChild(tk.el("div", "body", e.desc));
    d.appendChild(tk.el("div", "muted", "host " + String(e.host).slice(0, 16) + "…"));
    d.appendChild(tk.btn("Join", () => tk.send({type: "join", link: e.link})));
    r.appendChild(d);
  }
  r.appendChild(tk.status(v));
}
tk.onView(render);
