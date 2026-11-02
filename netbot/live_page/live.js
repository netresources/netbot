
function cosmosCssColor(name, fallbackParts) {
  try {
    var v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    if (v) return v;
  } catch (e) {}
  return "#" + fallbackParts;
}
/* Live page. Polls this server only. The seconds counter is outside the live region. */
(function () {
  "use strict";
  var sampleTs = null;
  var dishOn = true;
  var staleAfter = 1200;
  var pollS = 30;
  var state = "live";
  var announced = "";
  var fails = 0;
  var clockText = "";
  var pollTimer = 0;
  var fullLink = "";
  var linkShown = false;
  var plots = [];

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  }

  function byId(id) { return document.getElementById(id); }

  function token(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  }

  function fillFor(color) {
    var probe = document.createElement("span");
    probe.style.color = color;
    document.body.appendChild(probe);
    var got = getComputedStyle(probe).color;
    document.body.removeChild(probe);
    var open = got.indexOf("(");
    var close = got.indexOf(")");
    if (open < 0 || close < 0) return color;
    return "rgba(" + got.slice(open + 1, close) + ", 0.14)";
  }

  function setWord(word) {
    if (word !== announced) {
      announced = word;
      byId("live-word").textContent = word;
    }
  }

  function formatAge(sec) {
    if (sec < 120) return "last sample " + sec + " s ago";
    return "last sample " + Math.floor(sec / 60) + " min ago";
  }

  /* Same rules as format_throughput_mbps in make_dashboard.py. */
  function formatMbps(mbps) {
    if (mbps === 0) return "0";
    if (mbps > 0 && mbps < 0.05) return "<0.1";
    if (mbps < 10) return mbps.toFixed(1);
    return mbps.toFixed(0);
  }

  function throughputNumeral(value) {
    var text = String(value == null ? "" : value);
    if (!text || text.charAt(0) === "<") return text;
    var n = Number(text);
    if (!isFinite(n)) return text;
    return formatMbps(n);
  }

  function applyState(next) {
    var prev = state;
    state = next;
    document.body.setAttribute("data-live", next);
    var offline = byId("offline-banner");
    if (next === "offline") {
      if (offline) {
        offline.hidden = false;
        var when = byId("offline-when");
        if (when) when.textContent = clockText || "";
      }
      byId("lost-banner").hidden = true;
      byId("lastknown").hidden = true;
      byId("clock").textContent = clockText ? ("Snapshot " + clockText) : "Snapshot";
      byId("foot").textContent = "Offline copy · not live";
      return;
    }
    if (offline) offline.hidden = true;
    var word = next === "lost" ? "NOT CONNECTED" : next === "stale" ? "STALE" : "LIVE";
    setWord(word);
    var meta = byId("live-meta");
    var banner = byId("lost-banner");
    var last = byId("lastknown");
    if (next === "lost") {
      byId("live-age").textContent = "retrying every 10 s";
      meta.textContent = "Last values are dimmed until the connection is back.";
      if (prev !== "lost") {
        var when = clockText || "the last sample";
        byId("lost-sub").textContent = "Showing the last values received, from " + when + ". They are dimmed until the connection is back.";
        byId("lastknown-when").textContent = when;
      }
      banner.hidden = false;
      last.hidden = false;
      byId("foot").textContent = "Connection lost · showing last values";
      return;
    }
    banner.hidden = true;
    last.hidden = true;
    if (next === "stale") meta.textContent = "No new sample for 20+ min · page still refreshes every " + pollS + " s";
    else meta.textContent = "Page refreshes every " + pollS + " s · " + (dishOn ? "dish sampled" : "sampled") + " every 5 min";
  }

  function pill(tile) {
    var node = el("span", "nb-status nb-st-" + tile.cls);
    var light = el("span", "nb-light");
    light.setAttribute("aria-hidden", "true");
    node.appendChild(light);
    node.appendChild(document.createTextNode(tile.word));
    return node;
  }

  function srcMark(src) {
    var calc = src !== "DISH" && src !== "ROUTER";
    return el("span", calc ? "nb-src nb-src--calc" : "nb-src", src);
  }

  function readout(tile) {
    var cls = "nb-readout nb-st-" + tile.cls + (tile.metric ? " nb-m-" + tile.metric : "") + (tile.wide ? " nb-readout--wide-3" : "");
    var node = el("article", cls);
    var head = el("div", "nb-readout__head");
    var label = el("span", "nb-label");
    if (tile.metric) {
      var key = el("span", "nb-key");
      key.setAttribute("aria-hidden", "true");
      label.appendChild(key);
    }
    label.appendChild(document.createTextNode(tile.name));
    head.appendChild(label);
    head.appendChild(pill(tile));
    node.appendChild(head);
    var value = el("div", "nb-readout__value");
    if (tile.is_word) value.appendChild(el("span", "nb-num nb-num--word", tile.value));
    else {
      value.appendChild(el("span", "nb-num", tile.metric === "throughput" ? throughputNumeral(tile.value) : tile.value));
      value.appendChild(el("span", "nb-unit", tile.unit || ""));
    }
    node.appendChild(value);
    node.appendChild(el("p", "nb-readout__detail", tile.text));
    if (tile.watch && tile.watch.length) {
      var list = el("ul", "nb-watch");
      for (var i = 0; i < tile.watch.length; i++) {
        var item = tile.watch[i];
        var li = el("li", item.on ? "nb-watch--on" : "");
        li.appendChild(el("span", "", item.name));
        li.appendChild(el("em", "", item.word));
        list.appendChild(li);
      }
      node.appendChild(list);
    }
    var foot = el("div", "nb-readout__foot");
    foot.appendChild(srcMark(tile.source || ""));
    node.appendChild(foot);
    return node;
  }

  function systemTile(tile) {
    var node = el("div", "nb-system nb-st-" + tile.cls);
    node.appendChild(el("span", "nb-system__name", tile.name));
    node.appendChild(pill(tile));
    node.appendChild(el("span", "nb-system__text", tile.text));
    return node;
  }

  var CHART_H = 160;
  var resizeFrame = 0;
  var plotObserver = null;
  var resizeFallback = false;

  function clearPlots() {
    if (resizeFrame) {
      cancelAnimationFrame(resizeFrame);
      resizeFrame = 0;
    }
    if (plotObserver) plotObserver.disconnect();
    for (var i = 0; i < plots.length; i++) {
      try { plots[i].destroy(); } catch (e) { /* keep the page up if a chart is already gone */ }
    }
    plots = [];
  }

  /* Content box of the plot host, in CSS pixels. No fixed fallback: a short cell must stay a short cell. */
  function plotWidth(host) {
    var w = host.clientWidth;
    if (w > 0) return Math.floor(w);
    var rect = host.getBoundingClientRect();
    if (rect.width > 0) return Math.floor(rect.width);
    return 0;
  }

  function usablePoints(chart) {
    var pts = (chart && chart.points) || [];
    var rows = [];
    if (!pts || typeof pts.length !== "number") return rows;
    for (var i = 0; i < pts.length; i++) {
      var p = pts[i];
      if (!p || p.length < 2 || p[0] == null || p[1] == null) continue;
      var x = Number(p[0]);
      var y = Number(p[1]);
      if (!isFinite(x) || !isFinite(y)) continue;
      rows.push([x, y]);
    }
    rows.sort(function (a, b) { return a[0] - b[0]; });
    return rows;
  }

  /* Empty state only. Clears the host first so a plot and this tile never share a card. */
  function showEmpty(host) {
    host._pending = false;
    host.textContent = "";
    host.appendChild(el("p", "nb-chart__empty", "no data"));
  }

  function resizePlot(u) {
    if (!u || !u.root || !u.root.parentNode) return;
    var w = plotWidth(u.root.parentNode);
    if (w < 2) return;
    if (Math.abs(u.width - w) < 1 && u.height === CHART_H) return;
    u.setSize({width: w, height: CHART_H});
  }

  function scheduleResize() {
    if (resizeFrame) cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(function () {
      resizeFrame = 0;
      var hosts = document.querySelectorAll(".nb-plot");
      for (var i = 0; i < hosts.length; i++) {
        if (hosts[i]._pending) mountChart(hosts[i]);
      }
      for (var j = 0; j < plots.length; j++) resizePlot(plots[j]);
    });
  }

  function observeHost(host) {
    if (typeof ResizeObserver === "undefined") {
      if (!resizeFallback) {
        resizeFallback = true;
        window.addEventListener("resize", scheduleResize);
      }
      return;
    }
    if (!plotObserver) plotObserver = new ResizeObserver(function () { scheduleResize(); });
    plotObserver.observe(host);
  }

  function chartBox(chart, src) {
    var box = el("div", "nb-chart" + (chart.metric ? " nb-m-" + chart.metric : ""));
    box.setAttribute("role", "group");
    var head = el("div", "nb-chart__head");
    var title = el("span", "nb-chart__title");
    var key = el("span", "nb-key");
    key.setAttribute("aria-hidden", "true");
    title.appendChild(key);
    title.appendChild(document.createTextNode(chart.title));
    head.appendChild(title);
    head.appendChild(srcMark(src));
    box.appendChild(head);
    var host = el("div", "nb-plot");
    host._chart = chart;
    box.appendChild(host);
    return box;
  }

  function mountChart(host) {
    var chart = host._chart;
    var rows = usablePoints(chart);
    if (!window.uPlot || rows.length < 2) {
      showEmpty(host);
      return;
    }
    if (host.querySelector(".uplot")) {
      host._pending = false;
      return;
    }
    var width = plotWidth(host);
    if (width < 2) {
      host._pending = true;
      observeHost(host);
      return;
    }
    host.textContent = "";
    host._pending = false;
    var xs = [], ys = [];
    for (var i = 0; i < rows.length; i++) { xs.push(rows[i][0]); ys.push(rows[i][1]); }
    var stroke = token("--metric-" + chart.metric) || token("--nb-text");
    var axis = token("--nb-text-3") || token("--nb-line");
    var grid = token("--nb-grid") || axis;
    var xAxis = {stroke: axis, grid: {stroke: grid}, ticks: {stroke: grid}};
    if (chart.metric === "router-devices") {
      // Full width, so pin the same 4-hour step the other 24-hour charts use.
      xAxis.incrs = [4 * 3600];
    }
    try {
      plots.push(new window.uPlot({
        width: width,
        height: CHART_H,
        legend: {show: false},
        cursor: {show: false, drag: {x: false, y: false, setScale: false}},
        select: {show: false},
        scales: {x: {time: true}},
        axes: [
          xAxis,
          {stroke: axis, grid: {stroke: grid}, ticks: {stroke: grid}, size: 48}
        ],
        series: [{}, {stroke: stroke, fill: fillFor(stroke), width: 1.6, points: {show: false}}]
      }, [xs, ys], host));
      observeHost(host);
    } catch (e) {
      showEmpty(host);
    }
  }


  var KNOWN_ROUTER_COLORS = {
    "Linksys router": "#" + "3DB8F5",
    "Kit router": "#" + "7EC8FF",
    "UniFi Dream Machine SE": "#" + "4DA3FF",
    "Unknown": "#" + "C0A0FF"
  };

  function hashHue(name) {
    var h = 0;
    var i;
    for (i = 0; i < name.length; i++) h = ((h << 5) - h + name.charCodeAt(i)) | 0;
    return Math.abs(h) % 360;
  }

  function routerColor(name) {
    if (KNOWN_ROUTER_COLORS[name]) return KNOWN_ROUTER_COLORS[name];
    return "hsl(" + hashHue(name) + " 72% 68%)";
  }

  function applyActiveRouter(name) {
    var ar = byId("active-router");
    if (!ar) return;
    var label = name || "Unknown";
    ar.textContent = label;
    ar.setAttribute("data-router", label);
    ar.className = "nb-active-router__name";
    var color = routerColor(label);
    ar.style.color = color;
    ar.style.textShadow = "0 0 10px " + color;
  }

  function csrfToken() {
    var box = byId("monitor-controls");
    return box ? (box.getAttribute("data-csrf") || "") : "";
  }

  function setMonitorBtn(btn, selected) {
    if (!btn) return;
    btn.classList.remove("nb-btn--idle", "nb-btn--selected");
    btn.classList.add(selected ? "nb-btn--selected" : "nb-btn--idle");
    /* Keep both clickable; selected means "current state", not disabled. */
    btn.disabled = false;
  }

  function paintMonitor(state) {
    var box = byId("monitor-controls");
    if (!box) return;
    var status = byId("monitor-status");
    var word = byId("monitor-state");
    var start = byId("btn-monitor-start");
    var stop = byId("btn-monitor-stop");
    var err = byId("monitor-err");
    if (err) { err.hidden = true; err.textContent = ""; }
    var running = !!(state && state.running);
    var known = state && typeof state.running === "boolean";
    var label = !known ? "unknown" : (running ? "on" : "paused");
    var text = !known ? "UNKNOWN" : (running ? "ON" : "PAUSED");
    if (status) status.setAttribute("data-state", label);
    if (word) word.textContent = text;
    /* ON → Start selected; PAUSED → Stop selected. */
    setMonitorBtn(start, known && running);
    setMonitorBtn(stop, known && !running);
  }

  function flashMonitorBtn(btn, then) {
    if (!btn) { if (then) then(); return; }
    btn.classList.add("nb-btn--flash");
    setTimeout(function () {
      btn.classList.remove("nb-btn--flash");
      if (then) then();
    }, 400);
  }

  function refreshMonitor() {
    var box = byId("monitor-controls");
    if (!box) return;
    fetch("/api/monitor.json", {cache: "no-store"})
      .then(function (r) { if (!r.ok) throw new Error("monitor"); return r.json(); })
      .then(function (data) { paintMonitor(data); })
      .catch(function () { paintMonitor(null); });
  }

  function postMonitor(action, btn) {
    var box = byId("monitor-controls");
    if (!box) return;
    var err = byId("monitor-err");
    function send() {
      fetch("/api/monitor/" + action, {
        method: "POST",
        cache: "no-store",
        headers: {
          "X-CSRF-Token": csrfToken(),
          "Content-Type": "application/json"
        },
        body: "{}"
      }).then(function (r) {
        return r.json().then(function (data) {
          if (!r.ok) throw new Error((data && data.error) || ("HTTP " + r.status));
          paintMonitor(data);
        });
      }).catch(function (e) {
        if (err) {
          err.hidden = false;
          err.textContent = String((e && e.message) || e || "request failed");
        }
        refreshMonitor();
      });
    }
    flashMonitorBtn(btn, send);
  }

  function renderAccess(access) {
    var on = !!(access && access["lan"]);
    byId("wifi").className = on ? "nb-wifi" : "nb-wifi is-off";
    byId("wifi-state").textContent = on ? "ON" : "OFF";
    var off = byId("link-off");
    var panel = byId("link-on");
    var localOnly = byId("link-local-only");
    var noAddress = byId("link-no-address");
    off.hidden = true;
    panel.hidden = true;
    localOnly.hidden = true;
    noAddress.hidden = true;
    if (!on) {
      off.hidden = false;
      fullLink = "";
      return;
    }
    // reveal in a copied access.json is not proof this document is the local page.
    var host = String(location.hostname || "").toLowerCase();
    var parts = host.split(".");
    var loopback = parts.length === 4 && parts[0] === "127";
    var i;
    for (i = 0; loopback && i < 4; i++) {
      if (!/^\d{1,3}$/.test(parts[i]) || Number(parts[i]) > 255) loopback = false;
    }
    var localPage = host === "localhost" || host === "::1" || host === "[::1]" || loopback;
    if (localPage && access.reveal && access.link) {
      fullLink = String(access.link);
      panel.hidden = false;
      paintLink();
      return;
    }
    fullLink = "";
    if (access.note === "no-address" || (localPage && access.reveal)) {
      noAddress.hidden = false;
      return;
    }
    localOnly.hidden = false;
  }

  function maskLink(link) {
    var at = link.indexOf("key=");
    if (at < 0) return link;
    return link.slice(0, at + 4) + "••••••";
  }

  function paintLink() {
    var node = byId("link-url");
    node.textContent = linkShown ? fullLink : maskLink(fullLink);
    node.setAttribute("aria-label", linkShown ? "Private link, key visible" : "Private link, key hidden");
    var btn = byId("btn-show");
    btn.textContent = linkShown ? "Hide" : "Show";
    btn.setAttribute("aria-pressed", linkShown ? "true" : "false");
  }

  function render(status, history, access) {
    sampleTs = (typeof status.sample_ts === "number") ? status.sample_ts : null;
    dishOn = status.dish_on !== false;
    staleAfter = (typeof status.stale_after_s === "number") ? status.stale_after_s : 1200;
    var chosen = status.poll_s;
    pollS = (typeof chosen === "number" && chosen >= 30 && chosen <= 60) ? chosen : 30;
    clockText = status.clock || "";
    byId("clock").textContent = clockText ? ("Updated " + clockText + " (local time)") : "";
    var banner = byId("example");
    if (status.example) {
      banner.hidden = false;
      banner.textContent = status.example_text || "";
    } else {
      banner.hidden = true;
      banner.textContent = "";
    }
    var age = sampleTs == null ? null : Math.max(0, Math.floor(Date.now() / 1000 - sampleTs));
    if (age == null) {
      byId("live-age").textContent = "no sample yet";
      applyState("stale");
    } else {
      byId("live-age").textContent = formatAge(age);
      applyState(age >= staleAfter ? "stale" : "live");
    }
    renderAccess(access);
    applyActiveRouter(status.active_router || "Unknown");
    refreshMonitor();
    var chips = byId("chips");
    chips.textContent = "";
    (status.chips || []).forEach(function (chip) {
      chips.appendChild(el("span", chip.on ? "nb-chip nb-chip--on" : "nb-chip", chip.text));
    });
    var legend = byId("legend");
    legend.textContent = "";
    (status.legend || []).forEach(function (item) {
      var li = el("li");
      li.appendChild(srcMark(item.mark));
      li.appendChild(document.createTextNode(item.text));
      legend.appendChild(li);
    });
    var byName = {};
    (status.tiles || []).forEach(function (tile) { byName[tile.name] = tile; });
    var panels = byId("panels");
    panels.textContent = "";
    (status.sections || []).forEach(function (section) {
      var sec = el("section", "nb-section");
      sec.appendChild(el("h2", "nb-section__label", section.label));
      if (section.collector && status.collector) {
        var systems = el("div", "nb-systems");
        systems.appendChild(systemTile(status.collector));
        sec.appendChild(systems);
      }
      var row = el("div", "nb-readouts");
      (section.names || []).forEach(function (name) {
        if (byName[name]) row.appendChild(readout(byName[name]));
      });
      sec.appendChild(row);
      panels.appendChild(sec);
    });
    clearPlots();
    var charts = byId("charts");
    charts.textContent = "";
    (history.sections || []).forEach(function (section) {
      var count = (section.charts || []).length;
      var gridClass = "nb-charts" + (count === 1 ? " nb-charts--1" : count === 4 ? " nb-charts--4" : "");
      var grid = el("div", gridClass);
      (section.charts || []).forEach(function (chart) { grid.appendChild(chartBox(chart, section.source)); });
      var sec;
      if (section.addon) {
        sec = el("section", "nb-addon");
        var heading = el("h2", "nb-section__label", section.label + " ");
        heading.appendChild(el("span", "nb-tag", "ADD-ON"));
        sec.appendChild(heading);
        if (status.router) {
          var systems = el("div", "nb-systems");
          systems.appendChild(systemTile(status.router));
          sec.appendChild(systems);
        }
      } else {
        sec = el("section", "nb-section");
        sec.appendChild(el("h2", "nb-section__label", section.label));
      }
      sec.appendChild(grid);
      charts.appendChild(sec);
      var hosts = sec.querySelectorAll(".nb-plot");
      for (var h = 0; h < hosts.length; h++) mountChart(hosts[h]);
    });
    scheduleResize();
    if (state !== "lost") byId("foot").textContent = clockText ? ("Updated " + clockText + " (local time)") : "";
  }

  function schedule(ms) {
    clearTimeout(pollTimer);
    pollTimer = setTimeout(poll, ms);
  }

  function poll() {
    var ctrl = (typeof AbortController !== "undefined") ? new AbortController() : null;
    var timer = setTimeout(function () { if (ctrl) ctrl.abort(); }, 8000);
    var opts = {cache: "no-store"};
    if (ctrl) opts.signal = ctrl.signal;
    Promise.all([
      fetch("/api/status.json", opts),
      fetch("/api/history.json", opts),
      fetch("/api/access.json", opts)
    ]).then(function (responses) {
      if (!responses[0].ok || !responses[1].ok || !responses[2].ok) throw new Error("status");
      return Promise.all([responses[0].json(), responses[1].json(), responses[2].json()]);
    }).then(function (parts) {
      clearTimeout(timer);
      fails = 0;
      render(parts[0], parts[1], parts[2]);
      schedule(pollS * 1000);
    }).catch(function () {
      clearTimeout(timer);
      fails += 1;
      if (fails >= 2) applyState("lost");
      schedule(10000);
    });
  }


  /* Deep-space window: layered starfield + nebulae + rare satellite glints. */
  function preferReducedMotion() {
    return !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }

  function startCosmos() {
    var root = document.querySelector(".nb-cosmos");
    if (!root) return;
    var canvas = root.querySelector(".nb-cosmos__canvas");
    if (!canvas || !canvas.getContext) {
      root.classList.add("is-fallback");
      return;
    }
    var ctx = canvas.getContext("2d", { alpha: true });
    if (!ctx) {
      root.classList.add("is-fallback");
      return;
    }
    root.classList.add("is-canvas");
    var reduced = preferReducedMotion();
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    var stars = [];
    var nebulae = [];
    var galaxies = [];
    var glint = null;
    var nextGlintAt = 0; /* scheduled in build() */
    var raf = 0;
    var last = 0;
    var w = 0;
    var h = 0;

    function rand(a, b) { return a + Math.random() * (b - a); }

    function resize() {
      var rect = root.getBoundingClientRect();
      w = Math.max(2, Math.floor(rect.width));
      h = Math.max(2, Math.floor(rect.height));
      canvas.width = Math.floor(w * dpr);
      canvas.height = Math.floor(h * dpr);
      canvas.style.width = w + "px";
      canvas.style.height = h + "px";
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      build();
      paint(0, true);
    }

    function build() {
      var i, n = Math.min(160, Math.max(70, Math.floor(w * h / 1800)));
      stars = [];
      for (i = 0; i < n; i++) {
        var layer = (i % 3) + 1;
        var roll = Math.random();
        var color = roll < 0.72 ? "255,255,255"
          : roll < 0.84 ? "180,210,255"
          : roll < 0.93 ? "255,230,190"
          : "190,255,240";
        stars.push({
          x: Math.random() * w,
          y: Math.random() * h,
          r: (layer === 1 ? rand(0.4, 0.9) : layer === 2 ? rand(0.7, 1.4) : rand(1.1, 2.0)),
          a: rand(0.25, 0.95),
          tw: rand(0.4, 1.6),
          ph: rand(0, Math.PI * 2),
          layer: layer,
          color: color
        });
      }
      nebulae = [
        { x: w * 0.22, y: h * 0.42, rx: w * 0.34, ry: h * 0.55, color: "110,70,180", a: 0.22, drift: 0.003 },
        { x: w * 0.72, y: h * 0.58, rx: w * 0.30, ry: h * 0.48, color: "30,140,150", a: 0.18, drift: -0.0025 },
        { x: w * 0.55, y: h * 0.28, rx: w * 0.22, ry: h * 0.30, color: "40,70,160", a: 0.14, drift: 0.0018 }
      ];
      galaxies = [
        { x: w * 0.82, y: h * 0.28, rx: 28, ry: 10, rot: -0.5, color: "200,210,255", a: 0.22 },
        { x: w * 0.18, y: h * 0.70, rx: 18, ry: 7, rot: 0.7, color: "255,210,180", a: 0.16 }
      ];
      /* Keep an in-flight glint across resize; only clear if size collapsed. */
      if (w < 40 || h < 20) glint = null;
      if (reduced) {
        nextGlintAt = 1e18;
        glint = null;
      } else if (!nextGlintAt || nextGlintAt > performance.now() + 60000) {
        /* First schedule: 5–10 s after load/rebuild. */
        nextGlintAt = performance.now() + rand(5000, 10000);
      }
    }

    function spawnGlint(now) {
      /* Edge-to-edge pass on an angled/gently curved arc, 4–7 s. */
      var left = Math.random() < 0.5;
      var up = Math.random() < 0.5;
      var deg = rand(10, 35);
      var rad = deg * Math.PI / 180;
      var durMs = rand(4000, 7000);
      var startX = left ? -40 : w + 40;
      var endX = left ? (w + 40) : -40;
      var dx = endX - startX;
      /* Rise/fall from angle over full width; clamp endpoints into the header band. */
      var rise = Math.tan(rad) * Math.abs(dx) * (up ? -1 : 1);
      var midBand = h * 0.5;
      var startY = midBand - rise * 0.5 + rand(-h * 0.08, h * 0.08);
      var endY = startY + rise;
      startY = Math.max(h * 0.08, Math.min(h * 0.92, startY));
      endY = Math.max(h * 0.08, Math.min(h * 0.92, endY));
      /* Slight arc bulge (perpendicular to chord), ~4–9% of height. */
      var bulge = rand(0.04, 0.09) * h * (Math.random() < 0.5 ? 1 : -1);
      glint = {
        x0: startX, y0: startY,
        x1: endX, y1: endY,
        bulge: bulge,
        born: now,
        dur: durMs,
        x: startX, y: startY,
        trail: [],
        angleDeg: Math.round(deg * 10) / 10
      };
      nextGlintAt = now + rand(12000, 25000);
      root.setAttribute("data-glint-count", String((Number(root.getAttribute("data-glint-count") || 0) + 1)));
      root.setAttribute("data-glint-at", String(Math.round(now)));
      root.setAttribute("data-glint-angle", String(glint.angleDeg));
      if (window.console && console.debug) {
        console.debug("[netbot cosmos] glint #" + root.getAttribute("data-glint-count") +
          " at " + Math.round(now) + "ms angle=" + glint.angleDeg + "deg");
      }
    }

    function paint(now, forceStatic) {
      ctx.clearRect(0, 0, w, h);
      ctx.fillStyle = "#" + "05070d";
      ctx.fillRect(0, 0, w, h);
      var t = now * 0.001;
      var i;
      for (i = 0; i < nebulae.length; i++) {
        var n = nebulae[i];
        var nx = n.x + (reduced || forceStatic ? 0 : Math.sin(t * n.drift * 60 + i) * 10);
        var ny = n.y + (reduced || forceStatic ? 0 : Math.cos(t * n.drift * 50 + i) * 6);
        var g = ctx.createRadialGradient(nx, ny, 0, nx, ny, n.rx);
        g.addColorStop(0, "rgba(" + n.color + "," + n.a + ")");
        g.addColorStop(0.55, "rgba(" + n.color + "," + (n.a * 0.35) + ")");
        g.addColorStop(1, "rgba(" + "0,0,0,0)");
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.ellipse(nx, ny, n.rx, n.ry, 0, 0, Math.PI * 2);
        ctx.fill();
      }
      for (i = 0; i < galaxies.length; i++) {
        var gal = galaxies[i];
        ctx.save();
        ctx.translate(gal.x, gal.y);
        ctx.rotate(gal.rot);
        var gg = ctx.createRadialGradient(0, 0, 0, 0, 0, gal.rx);
        gg.addColorStop(0, "rgba(" + gal.color + "," + gal.a + ")");
        gg.addColorStop(0.45, "rgba(" + gal.color + "," + (gal.a * 0.35) + ")");
        gg.addColorStop(1, "rgba(" + "0,0,0,0)");
        ctx.fillStyle = gg;
        ctx.beginPath();
        ctx.ellipse(0, 0, gal.rx, gal.ry, 0, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
      }
      for (i = 0; i < stars.length; i++) {
        var s = stars[i];
        var tw = 1;
        if (!reduced && !forceStatic) {
          tw = 0.55 + 0.45 * Math.sin(t * s.tw + s.ph);
        }
        var alpha = Math.max(0.12, Math.min(1, s.a * tw));
        var dx = (!reduced && !forceStatic) ? Math.sin(t * 0.02 * s.layer + s.ph) * (0.4 * s.layer) : 0;
        var dy = (!reduced && !forceStatic) ? Math.cos(t * 0.015 * s.layer + s.ph) * (0.25 * s.layer) : 0;
        ctx.fillStyle = "rgba(" + s.color + "," + alpha + ")";
        ctx.beginPath();
        ctx.arc(s.x + dx, s.y + dy, s.r, 0, Math.PI * 2);
        ctx.fill();
      }
      if (glint) {
        var age = Math.max(0, now - glint.born);
        var mid = glint.dur / 2;
        var fade = 1 - Math.abs(age - mid) / mid;
        fade = Math.max(0, Math.min(1, fade));
        /* Trail from stored points (oldest → newest). */
        var trail = glint.trail || [];
        if (trail.length >= 2) {
          var ti;
          for (ti = 1; ti < trail.length; ti++) {
            var p0 = trail[ti - 1];
            var p1 = trail[ti];
            var tf = (ti / trail.length) * fade;
            ctx.strokeStyle = "rgba(" + "220,235,255," + (0.08 + 0.55 * tf) + ")";
            ctx.lineWidth = 1.2 + 1.4 * tf;
            ctx.beginPath();
            ctx.moveTo(p0.x, p0.y);
            ctx.lineTo(p1.x, p1.y);
            ctx.stroke();
          }
        }
        /* Bright core + soft halo. */
        var halo = ctx.createRadialGradient(glint.x, glint.y, 0, glint.x, glint.y, 7);
        halo.addColorStop(0, "rgba(" + "255,255,255," + (0.55 + 0.45 * fade) + ")");
        halo.addColorStop(0.35, "rgba(" + "200,220,255," + (0.25 * fade) + ")");
        halo.addColorStop(1, "rgba(" + "200,220,255,0)");
        ctx.fillStyle = halo;
        ctx.beginPath();
        ctx.arc(glint.x, glint.y, 7, 0, Math.PI * 2);
        ctx.fill();
        ctx.fillStyle = "rgba(" + "255,255,255," + (0.75 + 0.25 * fade) + ")";
        ctx.beginPath();
        ctx.arc(glint.x, glint.y, 2.1, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    function frame(now) {
      if (!last) last = now;
      var dt = Math.min(50, now - last);
      last = now;
      if (!reduced) {
        if (!glint && now >= nextGlintAt) spawnGlint(now);
        if (glint) {
          var lived = now - glint.born;
          var u = Math.max(0, Math.min(1, lived / glint.dur));
          /* Quadratic Bezier: endpoints on opposite edges, control point offset for curve. */
          var mx = (glint.x0 + glint.x1) / 2;
          var my = (glint.y0 + glint.y1) / 2;
          var cx = mx;
          var cy = my + glint.bulge;
          var omu = 1 - u;
          glint.x = omu * omu * glint.x0 + 2 * omu * u * cx + u * u * glint.x1;
          glint.y = omu * omu * glint.y0 + 2 * omu * u * cy + u * u * glint.y1;
          glint.trail.push({ x: glint.x, y: glint.y });
          if (glint.trail.length > 18) glint.trail.shift();
          if (u >= 1) glint = null;
        }
      }
      paint(now, false);
      raf = window.requestAnimationFrame(frame);
    }

    resize();
    window.addEventListener("resize", function () {
      clearTimeout(resize._t);
      resize._t = setTimeout(resize, 120);
    });
    if (reduced) {
      paint(performance.now(), true);
    } else {
      raf = window.requestAnimationFrame(frame);
    }
    document.addEventListener("visibilitychange", function () {
      if (document.hidden) {
        if (raf) cancelAnimationFrame(raf);
        raf = 0;
      } else if (!reduced && !raf) {
        last = 0;
        raf = window.requestAnimationFrame(frame);
      }
    });
  }

  announced = byId("live-word").textContent;
  byId("btn-copy").addEventListener("click", function () {
    if (!fullLink || !navigator.clipboard || !navigator.clipboard.writeText) return;
    var btn = this;
    navigator.clipboard.writeText(fullLink).then(function () {
      btn.textContent = "Copied";
      setTimeout(function () { btn.textContent = "Copy"; }, 1600);
    }, function () {});
  });
  byId("btn-show").addEventListener("click", function () {
    linkShown = !linkShown;
    paintLink();
  });
  setInterval(function () {
    if (state === "lost" || sampleTs == null) return;
    var age = Math.max(0, Math.floor(Date.now() / 1000 - sampleTs));
    byId("live-age").textContent = formatAge(age);
    var next = age >= staleAfter ? "stale" : "live";
    if (next !== state) applyState(next);
  }, 1000);
  var monStart = byId("btn-monitor-start");
  var monStop = byId("btn-monitor-stop");
  if (monStart) monStart.addEventListener("click", function () { postMonitor("start", monStart); });
  if (monStop) monStop.addEventListener("click", function () { postMonitor("stop", monStop); });
  refreshMonitor();
  startCosmos();
  poll();
}());
