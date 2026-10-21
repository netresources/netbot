/* Live page. Polls this server only. The seconds counter is outside the live region. */
(function () {
  "use strict";
  var sampleTs = null;
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
    else meta.textContent = "Page refreshes every " + pollS + " s · dish sampled every 5 min";
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
  poll();
}());
