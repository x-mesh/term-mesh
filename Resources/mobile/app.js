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
  // xterm-style 16-color palette; 16–231 is the 6x6x6 cube, 232–255 grays.
  var ANSI16 = [
    '#000000', '#cd3131', '#0dbc79', '#e5e510', '#2472c8', '#bc3fbc', '#11a8cd', '#e5e5e5',
    '#666666', '#f14c4c', '#23d18b', '#f5f543', '#3b8eea', '#d670d6', '#29b8db', '#ffffff'
  ];

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
    direct: $('direct'),
    type: $('type'),
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
    direct: false,       // direct-typing mode: keystrokes go straight to the pane
    typeRefreshTimer: null,
    typeQueue: [],       // pending keystrokes, sent one request at a time in order
    typeBusy: false,
    rowKeys: [],         // per-row render keys for incremental redraws
    rowNodes: [],
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

  function paletteColor(c) {
    if (c === null || c === undefined) { return null; }
    if (typeof c === 'string') { return c; }
    if (c < 16) { return ANSI16[c]; }
    if (c < 232) {
      var n = c - 16;
      var steps = [0, 95, 135, 175, 215, 255];
      var r = steps[Math.floor(n / 36)], g = steps[Math.floor(n / 6) % 6], b = steps[n % 6];
      return 'rgb(' + r + ',' + g + ',' + b + ')';
    }
    var v = 8 + (c - 232) * 10;
    return 'rgb(' + v + ',' + v + ',' + v + ')';
  }

  // Draw styled rows into the <pre>, touching only rows whose content or
  // cursor changed: rebuilding hundreds of spans per refresh is what made
  // typing feel slow on a phone. Colors go through the CSSOM, which the
  // page's CSP allows; attribute classes carry bold/dim/italic/underline/
  // inverse. The cursor cell gets a marker.
  function renderStyled(rows, cursor) {
    var cursorRow = cursor ? cursor.row : -1;
    for (var i = 0; i < rows.length; i++) {
      var key = JSON.stringify(rows[i]) + (i === cursorRow ? '|c' + cursor.col : '');
      if (state.rowKeys[i] === key && state.rowNodes[i]) { continue; }
      var node = buildRow(rows[i], i === cursorRow ? cursor : null, i);
      if (state.rowNodes[i]) {
        el.screen.replaceChild(node, state.rowNodes[i]);
      } else {
        el.screen.appendChild(node);
      }
      state.rowNodes[i] = node;
      state.rowKeys[i] = key;
    }
    while (state.rowNodes.length > rows.length) {
      var extra = state.rowNodes.pop();
      state.rowKeys.pop();
      if (extra.parentNode === el.screen) { el.screen.removeChild(extra); }
    }
  }

  function resetScreen() {
    el.screen.textContent = '';
    state.rowKeys = [];
    state.rowNodes = [];
  }

  function buildRow(spans, cursor, rowIndex) {
    var row = document.createElement('span');
    row.className = 'row';
    var col = 0;
    spans.forEach(function (s) {
      var text = s.t || '';
      var cursorHere = cursor && cursor.row === rowIndex && cursor.col >= col && cursor.col < col + text.length;
      if (cursorHere) {
        var at = cursor.col - col;
        appendSpan(row, text.slice(0, at), s, false);
        appendSpan(row, text.charAt(at) || ' ', s, true);
        appendSpan(row, text.slice(at + 1), s, false);
      } else {
        appendSpan(row, text, s, false);
      }
      col += text.length;
    });
    if (cursor && cursor.row === rowIndex && cursor.col >= col) {
      appendSpan(row, ' ', {}, true);
    }
    row.appendChild(document.createTextNode('\n'));
    return row;
  }

  function appendSpan(parent, text, s, isCursor) {
    if (!text && !isCursor) { return; }
    var node = document.createElement('span');
    node.textContent = text;
    var fg = paletteColor(s.fg), bg = paletteColor(s.bg);
    if (s.inv) { var tmp = fg; fg = bg; bg = tmp; node.classList.add('inv'); }
    if (fg) { node.style.color = fg; }
    if (bg) { node.style.backgroundColor = bg; }
    if (s.b) { node.classList.add('b'); }
    if (s.d) { node.classList.add('d'); }
    if (s.i) { node.classList.add('i'); }
    if (s.u) { node.classList.add('u'); }
    if (isCursor) { node.classList.add('cursor'); }
    parent.appendChild(node);
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
    if (changed && state.direct) { setDirect(false); }
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
      resetScreen();
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
    return api('GET', '/api/targets/' + encodeURIComponent(t.surface_id) + '/screen?lines=' + SCREEN_LINES + '&format=styled')
      .then(function (data) {
        var styled = data && Array.isArray(data.rows);
        // Compare the serialized frame so an unchanged screen is not redrawn.
        var key = styled ? JSON.stringify([data.rows, data.cursor]) : ((data && data.text) || '');
        if (key !== state.lastText) {
          state.lastText = key;
          if (styled) {
            renderStyled(data.rows, data.cursor || null);
          } else {
            resetScreen();
            el.screen.textContent = (data && data.text) || '';
          }
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
      if (document.hidden || state.typeBusy || state.typeQueue.length) { return; }
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

  // ── direct typing ─────────────────────────────────────────────────────
  // Tap the screen (or ⌨) and the phone keyboard types straight into the
  // pane: printable text as keystrokes (raw, even on a leader), Enter and
  // Backspace as keys. IME composition (Korean) is flushed only once the
  // composed text is committed, so no syllable fragments reach the pane.

  // Keystrokes are queued and sent one request at a time so they reach the
  // pane in order; text queued while a request is in flight is coalesced
  // into one POST. The screen refreshes once the queue drains, not per key.
  function enqueueType(item) {
    var last = state.typeQueue[state.typeQueue.length - 1];
    if (item.kind === 'text' && last && last.kind === 'text') {
      last.text += item.text;
    } else {
      state.typeQueue.push(item);
    }
    pumpType();
  }

  function pumpType() {
    if (state.typeBusy) { return; }
    if (!state.typeQueue.length) { scheduleTypeRefresh(); return; }
    var t = state.selected;
    if (!t) { state.typeQueue.length = 0; return; }
    var item = state.typeQueue.shift();
    var base = '/api/targets/' + encodeURIComponent(t.surface_id);
    var req = item.kind === 'text'
      ? api('POST', base + '/text', { text: item.text, request_id: requestId(), raw: true })
      : api('POST', base + '/key', { key: item.key });
    state.typeBusy = true;
    req.catch(function (err) {
      setSendStatus(describeError(err), true);
      state.typeQueue.length = 0;
    }).then(function () {
      state.typeBusy = false;
      pumpType();
    });
  }

  function typeRaw(text) {
    if (text) { enqueueType({ kind: 'text', text: text }); }
  }

  function typeKey(key) {
    enqueueType({ kind: 'key', key: key });
  }

  function scheduleTypeRefresh() {
    if (state.typeRefreshTimer) { window.clearTimeout(state.typeRefreshTimer); }
    state.typeRefreshTimer = window.setTimeout(function () {
      state.typeRefreshTimer = null;
      refreshNow();
    }, 120);
  }

  function flushTyped() {
    var value = el.type.value;
    if (!value) { return; }
    el.type.value = '';
    typeRaw(value);
  }

  function setDirect(on) {
    state.direct = !!on;
    el.screenWrap.classList.toggle('direct', state.direct);
    el.direct.setAttribute('aria-pressed', state.direct ? 'true' : 'false');
    if (state.direct) {
      el.type.value = '';
      el.type.focus();
      setSendStatus('직접 입력: 키보드 입력이 pane으로 바로 갑니다 (⌨로 종료)');
    } else {
      el.type.blur();
      setSendStatus('');
    }
  }

  var HARDWARE_KEYS = {
    ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right',
    Escape: 'Escape', Tab: 'Tab',
  };

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

  el.direct.addEventListener('click', function () {
    setDirect(!state.direct);
  });

  el.screen.addEventListener('click', function () {
    if (state.selected && !state.direct) { setDirect(true); }
    else if (state.direct) { el.type.focus(); }
  });

  el.type.addEventListener('beforeinput', function (ev) {
    if (!state.direct) { return; }
    if (ev.inputType === 'insertLineBreak' || ev.inputType === 'insertParagraph') {
      ev.preventDefault();
      flushTyped();
      typeKey('Enter');
    } else if (ev.inputType === 'deleteContentBackward' && !el.type.value) {
      ev.preventDefault();
      typeKey('Backspace');
    }
  });

  el.type.addEventListener('input', function (ev) {
    if (!state.direct || ev.isComposing) { return; }
    flushTyped();
  });

  el.type.addEventListener('compositionend', function () {
    if (!state.direct) { return; }
    // iOS fires a trailing non-composing input event as well; flushing here
    // and there is safe because the field is emptied on the first flush.
    window.setTimeout(flushTyped, 0);
  });

  el.type.addEventListener('keydown', function (ev) {
    if (!state.direct) { return; }
    if (ev.ctrlKey && (ev.key === 'c' || ev.key === 'C')) {
      ev.preventDefault();
      typeKey('C-c');
      return;
    }
    var mapped = HARDWARE_KEYS[ev.key];
    if (mapped) {
      ev.preventDefault();
      flushTyped();
      typeKey(mapped);
    }
  });

  el.type.addEventListener('blur', function () {
    // Leaving the field (another control tapped) ends direct mode so the
    // composer and key row behave normally again.
    if (state.direct) { window.setTimeout(function () {
      if (document.activeElement !== el.type) { setDirect(false); }
    }, 100); }
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
