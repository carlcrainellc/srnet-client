"use strict";
function render(v) {
  const r = tk.root(); r.appendChild(tk.el("h2", null, "File drop · " + v.collection));
  r.appendChild(tk.el("div", "muted", "Use the core's upload bar above to share a file. Files are fetched by hash and checked before saving."));
  for (const it of v.view.items || []) {
    const d = tk.el("div", "item"); d.appendChild(tk.el("strong", null, it.name));
    d.appendChild(tk.el("div", "muted", it.mime + " · " + it.size + " bytes · by " + it.by + " · sha256 " + it.sha256.slice(0, 16) + "…"));
    if (it.note) d.appendChild(tk.el("div", "body", it.note));
    d.appendChild(tk.btn("Download…", () => tk.send({type: "download", sha256: it.sha256})));
    r.appendChild(d);
  }
}
tk.onView(render);
