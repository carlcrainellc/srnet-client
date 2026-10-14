"use strict";
function render(v) {
  const r = tk.root(); r.appendChild(tk.el("h2", null, "Store · " + v.collection)); r.appendChild(tk.status(v));
  for (const l of v.view.listings || []) {
    if (!l.active) continue;
    const d = tk.el("div", "item"); d.appendChild(tk.el("h3", null, l.title));
    d.appendChild(tk.el("div", "body", l.desc || ""));
    d.appendChild(tk.el("div", "muted", "seller " + l.seller_label + " · " + (l.rating ? "★ " + l.rating + " (" + l.reviews.length + ")" : "no reviews")));
    // Price and payment target are shown by the core's own sheet, never assembled here.
    d.appendChild(tk.btn("Payment details…", () => tk.send({type: "pay", listing: l.id})));
    const rt = tk.el("input"); rt.placeholder = "rating 1-5"; const tx = tk.el("input"); tx.placeholder = "review";
    d.appendChild(rt); d.appendChild(tx);
    d.appendChild(tk.btn("Review", () => tk.draft("shop.review", {rating: parseInt(rt.value, 10), text: tx.value || null}, [l.id])));
    for (const rv of l.reviews) d.appendChild(tk.el("div", "muted", "★" + rv.rating + " " + rv.by + ": " + rv.text));
    r.appendChild(d);
  }
}
tk.onView(render);
