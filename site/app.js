/* TogetherBench landing — renders stats + the deepswe-style task list.
   Data comes from tasks.js (window.SUITE, window.TASKS). */
(function () {
  "use strict";
  var SUITE = window.SUITE || {};
  var TASKS = window.TASKS || [];

  /* ---------- helpers ---------- */
  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }
  function $(id) { return document.getElementById(id); }
  function fmtK(n) {
    if (n == null) return "";
    if (n >= 1000) return (n / 1000).toFixed(n >= 10000 ? 0 : 1).replace(/\.0$/, "") + "k";
    return String(n);
  }
  function cap(s) { return s ? s[0].toUpperCase() + s.slice(1) : s; }
  function fmtDur(m) {
    if (m == null) return null;
    if (m < 60) return m + " min";
    var h = Math.floor(m / 60), mm = m % 60;
    return h + "h" + (mm ? " " + mm + "m" : "");
  }
  function prettyCat(c) {
    if (!c) return "task";
    return c === "feature-implementation" ? "feature" : c;
  }
  var ICON = {
    repo: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M2 2.5A2.5 2.5 0 014.5 0h8.75a.75.75 0 01.75.75v12.5a.75.75 0 01-.75.75h-2.5a.75.75 0 010-1.5h1.75v-2h-8a1 1 0 00-.714 1.7.75.75 0 11-1.072 1.05A2.495 2.495 0 012 11.5zm10.5-1h-8a1 1 0 00-1 1v6.708A2.5 2.5 0 014.5 9h8z"/></svg>',
    star: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M8 .25a.75.75 0 01.673.418l1.882 3.815 4.21.612a.75.75 0 01.416 1.279l-3.046 2.97.719 4.192a.75.75 0 01-1.088.791L8 12.347l-3.766 1.98a.75.75 0 01-1.088-.79l.72-4.194L.818 6.374a.75.75 0 01.416-1.28l4.21-.611L7.327.668A.75.75 0 018 .25z"/></svg>',
    chat: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M14 8.5a5.5 5.5 0 01-7.9 4.96L2 14l.6-3.5A5.5 5.5 0 1114 8.5z"/></svg>',
    diff: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a.75.75 0 01.75.75v5.5h5.5a.75.75 0 010 1.5h-5.5v5.5a.75.75 0 01-1.5 0v-5.5h-5.5a.75.75 0 010-1.5h5.5v-5.5A.75.75 0 018 1z"/></svg>'
  };

  /* ---------- stats strip ---------- */
  function renderStats() {
    if (!$("stats")) return;
    var cells = [
      [SUITE.n_tasks, "tasks"],
      [SUITE.n_repos, "public repos"],
      [SUITE.n_user_turns, "user corrections"],
      [SUITE.n_models, "frontier models"],
      [SUITE.n_cohorts, "agent cohorts"]
    ];
    $("stats").innerHTML = cells.map(function (c) {
      return '<div class="stat"><div class="n">' + esc(c[0]) +
        '<span class="u">.</span></div><div class="l">' + esc(c[1]) + "</div></div>";
    }).join("");
  }

  /* ---------- cohorts ---------- */
  function renderCohorts() {
    var box = $("cohorts");
    if (!box || !SUITE.cohorts) return;
    box.innerHTML = SUITE.cohorts.map(function (c) {
      return '<span class="cohort"><span class="dot"></span>' + esc(c.model) +
        ' <span class="ag">· ' + esc(c.agent) + "</span></span>";
    }).join("");
  }

  /* ---------- distributions ---------- */
  function distBars(title, obj, total) {
    var keys = Object.keys(obj);
    var max = Math.max.apply(null, keys.map(function (k) { return obj[k]; }));
    var rows = keys.map(function (k) {
      var v = obj[k], pct = Math.round((v / max) * 100);
      return '<div class="bar-row"><span class="bl">' + esc(cap(k)) +
        '</span><div class="bar-track"><div class="bar-fill" style="width:' + pct +
        '%"></div></div><span class="bv">' + v + "</span></div>";
    }).join("");
    return '<div class="dist"><h4>' + esc(title) + ' <span>· ' + total +
      " total</span></h4>" + rows + "</div>";
  }
  function renderDists() {
    var box = $("dists");
    if (!box) return;
    box.innerHTML =
      distBars("Languages", SUITE.languages || {}, SUITE.n_tasks) +
      distBars("Task type", SUITE.categories || {}, SUITE.n_tasks) +
      distBars("Difficulty", SUITE.difficulties || {}, SUITE.n_tasks);
  }

  /* ---------- filters ---------- */
  function fillSelect(id, values) {
    var sel = $(id);
    if (!sel) return;
    values.forEach(function (v) {
      var o = document.createElement("option");
      o.value = v; o.textContent = cap(v);
      sel.appendChild(o);
    });
  }
  function uniq(arr) {
    return arr.filter(function (v, i) { return v && arr.indexOf(v) === i; });
  }

  /* ---------- task card ---------- */
  function metaItem(k, v) {
    return '<div class="mi"><div class="k">' + esc(k) + '</div><div class="v">' + v + "</div></div>";
  }
  function detailHTML(t) {
    var html = "";
    if (t.summary) html += '<p class="summary">' + esc(t.summary) + "</p>";

    if (t.intents && t.intents.length) {
      html += '<div class="dblock"><p class="dlabel">' + ICON.chat +
        " &nbsp;User interaction loop · " + t.intents.length + ' turns</p><div class="turns">';
      t.intents.forEach(function (it, i) {
        var kind = (it.kind || "").toLowerCase();
        var msg = it.quote || it.text || ""; // verbatim user words only
        html += '<div class="turn"><div class="ix">' + (i + 1) + '</div><div class="body">';
        if (it.kind) html += '<span class="kind ' + esc(kind) + '">' + esc(it.kind) + "</span>";
        if (msg) html += '<p class="ttext">' + esc(msg) + "</p>";
        html += "</div></div>";
      });
      html += "</div></div>";
    }

    if (t.goals && t.goals.length) {
      html += '<div class="dblock"><p class="dlabel">Completeness goals · ' + t.goals.length + "</p>";
      t.goals.forEach(function (g) {
        var w = g.weight != null ? Math.round(g.weight * 100) + "%" : "";
        html += '<div class="goal"><span class="w">' + esc(w) +
          '</span><span class="gtext"><span class="tier ' + esc(g.tier || "") + '">' +
          esc(g.tier || "") + "</span>" + esc(g.goal) + "</span></div>";
      });
      html += "</div>";
    }

    // meta grid
    var commit = "";
    if (t.base_commit) {
      commit = t.repo_url
        ? '<a href="' + esc(t.repo_url) + "/commit/" + esc(t.base_commit) +
          '" target="_blank" rel="noopener">' + esc(t.base_commit) + "</a>"
        : esc(t.base_commit);
    }
    var changes = (t.files_changed != null)
      ? t.files_changed + " files · +" + (t.additions || 0) + " / −" + (t.deletions || 0)
      : "—";
    var repoLink = t.repo_url
      ? '<a href="' + esc(t.repo_url) + '" target="_blank" rel="noopener">' + esc(t.repo) + "</a>"
      : esc(t.repo || "—");
    html += '<div class="dblock" style="margin-bottom:0"><p class="dlabel">Source</p><div class="meta-grid">' +
      metaItem("Repository", repoLink) +
      metaItem("Base commit", commit || "—") +
      metaItem("Reference diff", esc(changes)) +
      metaItem("Task id", esc(t.name)) +
      (t.session_min != null ? metaItem("Session time", esc(fmtDur(t.session_min))) : "") +
      "</div></div>";
    return html;
  }

  function cardHTML(t) {
    var tags = '<span class="tag cat">' + esc(prettyCat(t.category)) + "</span>";
    if (t.difficulty) tags += '<span class="tag diff" data-d="' + esc(t.difficulty) + '">' + esc(t.difficulty) + "</span>";
    if (t.language) tags += '<span class="tag lang">' + esc(t.language) + "</span>";

    var foot = "";
    if (t.repo) foot += '<span class="repo">' + ICON.repo + esc(t.repo) + "</span>";
    if (t.stars != null) foot += '<span class="m">' + ICON.star + fmtK(t.stars) + "</span>";
    if (t.n_intents) foot += '<span class="m">' + ICON.chat + t.n_intents + " turns</span>";
    if (t.files_changed != null) foot += '<span class="m">' + ICON.diff + t.files_changed + " files</span>";
    foot += '<span class="spacer"></span><span class="toggle">Details +</span>';

    return '<article class="card" data-name="' + esc(t.name) + '">' +
      '<div class="card-tags">' + tags + "</div>" +
      "<h3>" + esc(t.title) + "</h3>" +
      '<p class="blurb">' + esc(t.blurb) + "</p>" +
      '<div class="card-foot">' + foot + "</div>" +
      '<div class="detail">' + detailHTML(t) + "</div>" +
      "</article>";
  }

  /* ---------- list state ---------- */
  var state = { q: "", lang: "", cat: "", diff: "", sort: "default" };

  function matches(t) {
    if (state.lang && t.language !== state.lang) return false;
    if (state.diff && t.difficulty !== state.diff) return false;
    if (state.cat && prettyCat(t.category) !== state.cat) return false;
    if (state.q) {
      var hay = (t.title + " " + t.blurb + " " + t.summary + " " + (t.repo || "") +
        " " + t.name + " " + (t.tags || []).join(" ")).toLowerCase();
      if (hay.indexOf(state.q.toLowerCase()) === -1) return false;
    }
    return true;
  }
  function sortTasks(arr) {
    var s = state.sort, a = arr.slice();
    if (s === "turns") a.sort(function (x, y) { return (y.n_intents || 0) - (x.n_intents || 0); });
    else if (s === "changes") a.sort(function (x, y) {
      return ((y.additions || 0) + (y.deletions || 0)) - ((x.additions || 0) + (x.deletions || 0));
    });
    else if (s === "stars") a.sort(function (x, y) { return (y.stars || 0) - (x.stars || 0); });
    return a;
  }

  function render() {
    if (!$("grid")) return;
    var list = sortTasks(TASKS.filter(matches));
    $("grid").innerHTML = list.map(cardHTML).join("");
    $("count").innerHTML = "Showing <b>" + list.length + "</b> of <b>" + TASKS.length + "</b> tasks";
    $("empty").style.display = list.length ? "none" : "block";
  }

  function openCard(card) {
    if (!card) return;
    card.classList.add("open");
    var tog = card.querySelector(".toggle");
    if (tog) tog.textContent = "Close −";
  }
  // Deep link: ?open=<task-id> expands and scrolls to that task on load.
  function applyDeepLink() {
    var m = /[?&]open=([^&]+)/.exec(window.location.search);
    if (!m) return;
    var name = decodeURIComponent(m[1]);
    var card = $("grid").querySelector('.card[data-name="' + (window.CSS && CSS.escape ? CSS.escape(name) : name) + '"]');
    if (card) { openCard(card); card.scrollIntoView({ block: "center" }); }
  }

  /* ---------- wire up ---------- */
  function init() {
    renderStats();
    renderCohorts();
    renderDists();

    if (!$("grid")) return; // page has no task list — nothing more to wire

    fillSelect("f-lang", uniq(TASKS.map(function (t) { return t.language; })).sort());
    fillSelect("f-cat", uniq(TASKS.map(function (t) { return prettyCat(t.category); })).sort());
    fillSelect("f-diff", ["easy", "medium", "hard"].filter(function (d) {
      return TASKS.some(function (t) { return t.difficulty === d; });
    }));

    var q = $("q"), tmr;
    if (q) q.addEventListener("input", function () {
      clearTimeout(tmr);
      tmr = setTimeout(function () { state.q = q.value; render(); }, 120);
    });
    function bind(id, key) {
      var el = $(id);
      if (el) el.addEventListener("change", function (e) { state[key] = e.target.value; render(); });
    }
    bind("f-lang", "lang"); bind("f-cat", "cat"); bind("f-diff", "diff"); bind("f-sort", "sort");

    var qp = /[?&]q=([^&]+)/.exec(window.location.search);
    if (qp && q) { state.q = decodeURIComponent(qp[1].replace(/\+/g, " ")); q.value = state.q; }

    // expand/collapse (event delegation)
    $("grid").addEventListener("click", function (e) {
      var card = e.target.closest(".card");
      if (!card) return;
      if (e.target.closest("a")) return; // let links work
      var open = card.classList.toggle("open");
      var tog = card.querySelector(".toggle");
      if (tog) tog.textContent = open ? "Close −" : "Details +";
    });

    render();
    applyDeepLink();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
