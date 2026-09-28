// Live activity feed – fetches /api/activity (same domain) every 30 s.
(function () {
  var list = document.getElementById("activity-list");
  var status = document.getElementById("activity-status");
  if (!list) return;

  var icons = { "Docker": "🐳", "Image registry": "📦", "Security scan": "🛡️",
                "Server": "🖥️", "Kubernetes": "☸️", "EKS cluster": "☸️" };

  function ago(iso) {
    var s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
    if (s < 60) return Math.floor(s) + "s ago";
    if (s < 3600) return Math.floor(s / 60) + "m ago";
    if (s < 86400) return Math.floor(s / 3600) + "h ago";
    return Math.floor(s / 86400) + "d ago";
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text) e.textContent = text;   // textContent: never injects HTML
    return e;
  }

  function render(data) {
    list.innerHTML = "";
    var events = (data && data.events) || [];
    if (!events.length) {
      list.appendChild(el("li", "act-empty", "No activity in the last 7 days — the demo servers are currently offline."));
    }
    events.forEach(function (ev) {
      var li = el("li", "act-item");
      li.appendChild(el("span", "act-icon", icons[ev.source] || "•"));
      var body = el("div", "act-body");
      var head = el("div", "act-head");
      head.appendChild(el("strong", "", ev.source));
      head.appendChild(el("span", "act-action", ev.action));
      if (ev.where) head.appendChild(el("span", "act-where", "on " + ev.where));
      body.appendChild(head);
      body.appendChild(el("div", "act-target", ev.target));
      li.appendChild(body);
      li.appendChild(el("time", "act-time", ev.time ? ago(ev.time) : ""));
      list.appendChild(li);
    });
    status.textContent = "Live · updated " + new Date().toLocaleTimeString();
  }

  function load() {
    fetch("/api/activity", { cache: "no-store" })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(render)
      .catch(function () { status.textContent = "Activity feed temporarily unavailable"; });
  }

  load();
  setInterval(load, 30000);
})();
