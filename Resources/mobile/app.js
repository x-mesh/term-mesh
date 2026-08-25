// term-mesh mobile remote control (docs/mobile-remote-control.md §4.5).
//
// Talks only to the same-origin API served by http_mobile.rs:
//   GET  /api/targets
//   GET  /api/targets/{id}/screen?lines=N
//   GET  /api/targets/{id}/requests        (leader targets)
//   POST /api/targets/{id}/text {text, request_id}
//   POST /api/targets/{id}/key  {key}
// The page keeps no state beyond the selected target; the host is the source
// of truth and the screen is re-fetched every POLL_MS.

(function () {
  'use strict';

  var POLL_MS = 2000;
  var SCREEN_LINES = 200;
  var BOTTOM_SLACK_PX = 24;

  var $ = function (id) { return document.getElementById(id); };
  var el = {
    target: $('target'),
    refresh: $('refresh'),
    status: $('status'),
    empty: $('empty'),
    screenWrap: $('screen-wrap'),
    screen: $('screen'),
    jump: $('jump'),
    requests: $('requests'),
    requestsCount: $('requests-count'),
    requestsList: $('requests-list'),
    composer: $('composer'),
    keys: $('keys'),
    form: $('send-form'),
    text: $('text'),
    send: $('send'),
    sendStatus: $('send-status'),
  };

  var state = {
    targets: [],
    selected: null,      // target object
    pollTimer: null,
    inFlight: false,
    lastText: null,
    lastError: null,
  };

  // ── helpers ──────────────────────────────────────────────────────────

  function setStatus(text, isError) {
    el.status.textContent = text;
    el.status.classList.toggle('error', !!isError);
  }

  function setSendStatus(text, isError) {
    el.sendStatus.textContent = text;
    el.sendStatus.classList.toggle('error', !!isError);
  }

  function requestId() {
    if (window.crypto && typeof window.crypto.randomUUID === 'function') {
      return window.crypto.randomUUID();
    }
    return 'r-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
  }

  function api(method, path, body) {
    var init = { method: method, headers: {}, credentials: 'same-origin' };
    if (body !== undefined) {
      init.headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(body);
    }
    return fetch(path, init).then(function (res) {
      return res.text().then(function (raw) {
        var data = null;
        try { data = raw ? JSON.parse(raw) : null; } catch (e) { data = null; }
        if (!res.ok) {
          var code = data && data.error && data.error.code ? data.error.code : ('http_' + res.status);
          var message = data && data.error && data.error.message ? data.error.message : res.statusText;
          var err = new Error(message);
          err.status = res.status;
          err.code = code;
          throw err;
        }
        return data;
      });
    });
  }

  function describeError(err) {
    if (!err) { return 'error'; }
    switch (err.code) {
      case 'login_required': return '인증 없음: Tailscale Serve를 통해 접속하세요';
      case 'login_not_allowed': return '이 tailnet 계정은 허용 목록에 없습니다';
      case 'not_exposed': return '이 pane은 더 이상 노출되지 않습니다 (/rc on)';
      case 'target_gone': return 'pane이 사라졌습니다';
      case 'app_unavailable': return 'term-mesh 앱에 연결할 수 없습니다';
      case 'keys_disabled': return '이 pane은 keys=none 으로 노출되었습니다';
      case 'key_not_allowed': return '허용되지 않은 키';
      default: return (err.code ? err.code + ': ' : '') + (err.message || 'error');
    }
  }

  function isAtBottom(node) {
    return node.scrollHeight - node.scrollTop - node.clientHeight <= BOTTOM_SLACK_PX;
  }

  function targetLabel(t) {
    var bits = [];
    if (t.kind === 'leader') { bits.push('leader'); }
    if (t.agent_cli) { bits.push(t.agent_cli); }
    var head = t.title || t.surface_id.slice(0, 8);
    return bits.length ? head + ' · ' + bits.join(' ') : head;
  }

  function surfaceFromPath() {
    var m = /^\/t\/([A-Za-z0-9._-]+)\/?$/.exec(window.location.pathname);
    return m ? m[1] : null;
  }

  // ── targets ──────────────────────────────────────────────────────────

  function loadTargets() {
    return api('GET', '/api/targets').then(function (data) {
      state.targets = (data && data.targets) || [];
      renderTargets();
      return state.targets;
    });
  }

  function renderTargets() {
    var wanted = state.selected ? state.selected.surface_id : surfaceFromPath();
    el.target.textContent = '';
    state.targets.forEach(function (t) {
      var opt = document.createElement('option');
      opt.value = t.surface_id;
      opt.textContent = targetLabel(t);
      el.target.appendChild(opt);
    });
    var next = null;
    state.targets.forEach(function (t) { if (t.surface_id === wanted) { next = t; } });
    if (!next && state.targets.length) { next = state.targets[0]; }
    selectTarget(next, /* fromRender */ true);
  }

  function selectTarget(t, fromRender) {
    var changed = !state.selected || !t || state.selected.surface_id !== t.surface_id;
    state.selected = t || null;
    if (t) { el.target.value = t.surface_id; }
    var has = !!t;
    el.empty.hidden = has;
    el.screenWrap.hidden = !has;
    el.composer.hidden = !has;
    el.requests.hidden = !(has && t.kind === 'leader');
    el.keys.hidden = !!(has && t.keys === 'none');
    if (has) {
      setStatus(t.kind === 'leader' ? 'leader · ' + (t.team_name || '') : (t.agent_cli || 'pane') + ' · ' + (t.cwd || ''));
    } else {
      setStatus('no exposed panes');
    }
    if (changed) {
      state.lastText = null;
      el.screen.textContent = '';
      el.requestsList.textContent = '';
      el.requestsCount.textContent = '';
      if (!fromRender || has) { refreshNow(); }
    }
  }

  // ── screen ───────────────────────────────────────────────────────────

  function refreshScreen() {
    var t = state.selected;
    if (!t) { return Promise.resolve(); }
    var stickToBottom = isAtBottom(el.screen);
    return api('GET', '/api/targets/' + encodeURIComponent(t.surface_id) + '/screen?lines=' + SCREEN_LINES)
      .then(function (data) {
        var text = (data && data.text) || '';
        if (text !== state.lastText) {
          state.lastText = text;
          el.screen.textContent = text;
          if (stickToBottom) {
            el.screen.scrollTop = el.screen.scrollHeight;
          }
        }
        el.jump.hidden = isAtBottom(el.screen);
        state.lastError = null;
        var when = new Date().toLocaleTimeString();
        setStatus((t.kind === 'leader' ? 'leader' : (t.agent_cli || 'pane')) + ' · ' + when);
      })
      .catch(function (err) {
        state.lastError = err;
        setStatus(describeError(err), true);
        if (err.code === 'not_exposed' || err.code === 'target_gone') {
          return loadTargets();
        }
      });
  }

  function refreshRequests() {
    var t = state.selected;
    if (!t || t.kind !== 'leader') { return Promise.resolve(); }
    return api('GET', '/api/targets/' + encodeURIComponent(t.surface_id) + '/requests')
      .then(function (data) {
        var items = (data && data.requests) || [];
        el.requestsCount.textContent = String(items.length);
        el.requestsList.textContent = '';
        items.slice(-8).reverse().forEach(function (r) {
          var li = document.createElement('li');
          var id = document.createElement('span');
          id.className = 'id';
          id.textContent = r.id || r.request_id || '?';
          var st = document.createElement('span');
          st.className = 'muted';
          st.textContent = r.status || '';
          li.appendChild(id);
          li.appendChild(st);
          el.requestsList.appendChild(li);
        });
      })
      .catch(function () { /* the screen poll already reports errors */ });
  }

  function refreshNow() {
    if (state.inFlight) { return; }
    state.inFlight = true;
    el.refresh.disabled = true;
    Promise.all([refreshScreen(), refreshRequests()]).then(done, done);
    function done() {
      state.inFlight = false;
      el.refresh.disabled = false;
    }
  }

  function startPolling() {
    stopPolling();
    state.pollTimer = window.setInterval(function () {
      if (document.hidden) { return; }
      refreshNow();
    }, POLL_MS);
  }

  function stopPolling() {
    if (state.pollTimer) {
      window.clearInterval(state.pollTimer);
      state.pollTimer = null;
    }
  }

  // ── input ────────────────────────────────────────────────────────────

  function sendText(text) {
    var t = state.selected;
    if (!t) { return; }
    var id = requestId();
    el.send.disabled = true;
    setSendStatus('sending…');
    api('POST', '/api/targets/' + encodeURIComponent(t.surface_id) + '/text', { text: text, request_id: id })
      .then(function (data) {
        if (t.kind === 'leader') {
          var bits = ['queued ' + String(data.request_id || id).slice(0, 8)];
          if (data.wake_dispatched) { bits.push('leader woken'); }
          if (data.request_replayed) { bits.push('replayed'); }
          setSendStatus(bits.join(' · '));
        } else {
          setSendStatus(data.deduplicated ? 'already delivered' : 'typed');
        }
        el.text.value = '';
        refreshNow();
      })
      .catch(function (err) {
        setSendStatus(describeError(err), true);
      })
      .then(function () { el.send.disabled = false; });
  }

  function sendKey(key) {
    var t = state.selected;
    if (!t) { return; }
    setSendStatus('key ' + key + '…');
    api('POST', '/api/targets/' + encodeURIComponent(t.surface_id) + '/key', { key: key })
      .then(function () {
        setSendStatus('sent ' + key);
        window.setTimeout(refreshNow, 250);
      })
      .catch(function (err) {
        setSendStatus(describeError(err), true);
      });
  }

  // ── wiring ───────────────────────────────────────────────────────────

  el.target.addEventListener('change', function () {
    var id = el.target.value;
    var next = null;
    state.targets.forEach(function (t) { if (t.surface_id === id) { next = t; } });
    if (next && window.history && window.history.replaceState) {
      window.history.replaceState(null, '', '/t/' + encodeURIComponent(next.surface_id));
    }
    selectTarget(next, false);
  });

  el.refresh.addEventListener('click', function () {
    loadTargets().then(refreshNow, refreshNow);
  });

  el.screen.addEventListener('scroll', function () {
    el.jump.hidden = isAtBottom(el.screen);
  });

  el.jump.addEventListener('click', function () {
    el.screen.scrollTop = el.screen.scrollHeight;
    el.jump.hidden = true;
  });

  el.keys.addEventListener('click', function (ev) {
    var btn = ev.target.closest('button[data-key]');
    if (!btn) { return; }
    sendKey(btn.getAttribute('data-key'));
  });

  el.form.addEventListener('submit', function (ev) {
    ev.preventDefault();
    var text = el.text.value;
    if (!text.trim()) { return; }
    sendText(text);
  });

  el.text.addEventListener('keydown', function (ev) {
    // Cmd/Ctrl+Enter sends; plain Enter inserts a newline on phones.
    if (ev.key === 'Enter' && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      el.form.requestSubmit ? el.form.requestSubmit() : el.form.dispatchEvent(new Event('submit'));
    }
  });

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) { refreshNow(); }
  });

  loadTargets()
    .then(function () { startPolling(); })
    .catch(function (err) {
      setStatus(describeError(err), true);
      el.empty.hidden = false;
      startPolling();
    });
})();
