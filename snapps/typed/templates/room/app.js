"use strict";
let draftText = "";
function render(v) {
  const r = tk.root(); const w = v.view;
  r.appendChild(tk.el("h2", null, "#" + v.collection));
  r.appendChild(tk.el("div", "muted", w.topic ? "Topic: " + w.topic.text + " (set by " + w.topic.by + ")" : "No topic"));
  const log = tk.el("div");
  for (const l of w.lines || []) {
    const d = tk.el("div", "item"); d.appendChild(tk.el("span", "who", l.who)); d.appendChild(tk.el("span", "muted", " " + tk.when(l.ts) + " "));
    d.appendChild(tk.el("span", "body", l.text)); log.appendChild(d);
  }
  r.appendChild(log);
  const ta = tk.el("input"); ta.maxLength = 500; ta.placeholder = "Say something (signed by you)"; ta.value = draftText;
  ta.addEventListener("input", () => { draftText = ta.value; });
  ta.addEventListener("keydown", (e) => { if (e.key === "Enter" && ta.value.trim()) { tk.draft("room.msg", {text: ta.value}); draftText = ""; ta.value = ""; } });
  r.appendChild(ta);
  const nick = tk.el("input"); nick.maxLength = 24; nick.placeholder = "nick";
  r.appendChild(nick); r.appendChild(tk.btn("Set nick", () => nick.value && tk.draft("room.join", {nick: nick.value})));
  ta.focus();
}
tk.onView(render);
