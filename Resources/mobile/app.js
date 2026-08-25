// term-mesh mobile remote control (docs/mobile-remote-control.md §4.5).
//
// Talks only to the same-origin API served by http_mobile.rs:
//   GET  /api/targets
//   GET  /api/targets/{id}/screen?lines=N
//   GET  /api/targets/{id}/requests        (leader targets)
//   POST /api/targets/{id}/text {text, request_id}
//   POST /api/targets/{id}/key  {key}
// The host is the source of truth. Only the per-target Chat/Terminal view
// preference is kept locally; screen and transcript data are always fetched.

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
    viewSwitch: $('view-switch'),
    viewChat: $('view-chat'),
    viewTerminal: $('view-terminal'),
    empty: $('empty'),
    screenWrap: $('screen-wrap'),
    screen: $('screen'),
    jump: $('jump'),
    requests: $('requests'),
    requestsCount: $('requests-count'),
    requestsList: $('requests-list'),
    chat: $('chat'),
    chatTitle: $('chat-title'),
    chatSubtitle: $('chat-subtitle'),
    chatList: $('chat-list'),
    chatState: $('chat-state'),
    interrupt: $('interrupt'),
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
    fastPollTimer: null,
    inFlight: false,
    lastText: null,
    lastError: null,
    rowKeys: [],         // per-row render keys for incremental redraws
    rowNodes: [],
    chatNodes: {},       // entry id → {node, key} for the agent chat view
    chatRunning: false,
    mode: 'terminal',
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
      case 'mode_required': return '페이지가 업데이트되었습니다. 새로고침한 뒤 다시 보내세요';
      case 'invalid_mode': return '잘못된 보기 모드입니다. 새로고침한 뒤 다시 보내세요';
      default: return (err.code ? err.code + ': ' : '') + (err.message || 'error');
    }
  }

  function isAtBottom(node) {
    return node.scrollHeight - node.scrollTop - node.clientHeight <= BOTTOM_SLACK_PX;
  }

  function isAgent(t) { return !!t && t.kind === 'agent'; }
  function isChat(t) { return !!t && (isAgent(t) || (t.chat_capable && state.mode === 'chat')); }
  function isCurrentTarget(t) {
    return !!t && !!state.selected && state.selected.surface_id === t.surface_id && isChat(t);
  }
  function isPaneReadOnly(t) {
    return !!t && t.kind === 'pane' && t.keys === 'none';
  }

  function storedMode(t) {
    if (!t) { return 'terminal'; }
    if (isAgent(t)) { return 'chat'; }
    var saved = window.localStorage.getItem('term-mesh-view:' + t.surface_id);
    if (saved === 'chat' && t.chat_capable) { return 'chat'; }
    if (saved === 'terminal') { return 'terminal'; }
    return t.chat_capable ? 'chat' : 'terminal';
  }

  function setMode(mode) {
    var t = state.selected;
    if (!t || (mode === 'chat' && !t.chat_capable && !isAgent(t))) { return; }
    state.mode = isAgent(t) ? 'chat' : mode;
    if (!isAgent(t)) { window.localStorage.setItem('term-mesh-view:' + t.surface_id, state.mode); }
    resetScreen();
    resetChat();
    selectTarget(t, false);
  }

  function targetLabel(t) {
    var bits = [];
    if (t.kind === 'leader') { bits.push('leader'); }
    if (t.kind === 'agent') { bits.push('chat'); }
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
    state.selected = t || null;
    if (t) { el.target.value = t.surface_id; }
    var has = !!t;
    if (changed) { state.mode = storedMode(t); }
    var agent = isChat(t);
    el.empty.hidden = has;
    el.screenWrap.hidden = !has || agent;
    el.chat.hidden = !agent;
    var paneReadOnly = isPaneReadOnly(t);
    el.composer.hidden = !has || paneReadOnly;
    el.requests.hidden = !(has && t.kind === 'leader');
    el.keys.hidden = !has || agent || t.keys === 'none';
    el.viewSwitch.hidden = !has || isAgent(t) || !t.chat_capable;
    el.viewChat.disabled = !has || !t.chat_capable;
    el.viewChat.setAttribute('aria-pressed', String(agent));
    el.viewTerminal.setAttribute('aria-pressed', String(!agent));
    document.body.classList.toggle('chat-mode', agent);
    el.interrupt.hidden = !agent || !state.chatRunning || paneReadOnly;
    if (agent) {
      var chatName = t.agent_name || t.agent_cli || 'agent';
      el.chatTitle.textContent = chatName.charAt(0).toUpperCase() + chatName.slice(1) + ' session';
      el.chatSubtitle.textContent = t.cwd ? compactPath(t.cwd) : 'Live transcript';
      setStatus('chat · ' + chatName + (t.team_name ? ' @ ' + t.team_name : ''));
      el.text.placeholder = chatName + '에게 보낼 턴…';
      if (paneReadOnly) { setStatus('chat transcript · read only (keys=none)'); }
    } else if (has) {
      setStatus(t.kind === 'leader' ? 'leader · ' + (t.team_name || '') : (t.agent_cli || 'pane') + ' · ' + (t.cwd || ''));
      el.text.placeholder = '메시지…';
      if (paneReadOnly) { setStatus('terminal · read only (keys=none)'); }
    } else {
      setStatus('no exposed panes');
    }
    if (changed) {
      state.lastText = null;
      resetScreen();
      resetChat();
      el.requestsList.textContent = '';
      el.requestsCount.textContent = '';
      if (!fromRender || has) { refreshNow(); }
    }
  }

  // ── screen ───────────────────────────────────────────────────────────

  // ── agent chat ───────────────────────────────────────────────────────

  function resetChat() {
    el.chatList.textContent = '';
    state.chatNodes = {};
    state.chatRunning = false;
    el.chatState.textContent = '';
    el.interrupt.hidden = true;
  }

  function buildEntry(e) {
    var node;
    if (e.kind === 'tool') {
      node = document.createElement('details');
      node.className = 'tool' + (e.running ? ' running' : '') + (e.failed ? ' failed' : '');
      var summary = document.createElement('summary');
      var marker = document.createElement('span'); marker.className = 'tool-marker'; marker.setAttribute('aria-hidden', 'true');
      var body = document.createElement('span'); body.className = 'tool-summary-body';
      var name = document.createElement('span'); name.className = 'tool-name'; name.textContent = toolLabel(e.name);
      var head = document.createElement('span'); head.className = 'tool-head'; head.textContent = toolSummary(e);
      var stateLabel = document.createElement('span'); stateLabel.className = 'tool-state';
      stateLabel.textContent = e.failed ? 'Failed' : (e.running ? 'Running' : 'Done');
      body.appendChild(name); body.appendChild(head);
      summary.appendChild(marker); summary.appendChild(body); summary.appendChild(stateLabel);
      if (e.change) {
        var ch = document.createElement('span'); ch.className = 'tool-change';
        var add = document.createElement('span'); add.className = 'add'; add.textContent = '+' + (e.change.added || 0);
        var del = document.createElement('span'); del.className = 'del'; del.textContent = ' −' + (e.change.removed || 0);
        ch.appendChild(document.createTextNode((e.change.path || '') + ' ')); ch.appendChild(add); ch.appendChild(del);
        body.appendChild(ch);
      }
      node.appendChild(summary);
      var details = document.createElement('div'); details.className = 'tool-details';
      if (e.headline) {
        var commandLabel = document.createElement('div'); commandLabel.className = 'tool-section-label'; commandLabel.textContent = e.name === 'exec' ? 'Command' : 'Input';
        var command = document.createElement('pre'); command.className = 'tool-command'; command.textContent = e.headline;
        details.appendChild(commandLabel); details.appendChild(command);
      }
      if (e.result) {
        var resultLabel = document.createElement('div'); resultLabel.className = 'tool-section-label'; resultLabel.textContent = 'Output';
        var pre = document.createElement('pre'); pre.className = 'tool-output'; pre.textContent = e.result;
        details.appendChild(resultLabel); details.appendChild(pre);
      }
      if (details.childNodes.length) { node.appendChild(details); }
      return node;
    }
    node = document.createElement('article');
    if (e.kind === 'said') {
      node.className = 'msg said' + (e.speaker === 'leader' ? ' leader' : '');
      appendMessage(node, e.speaker === 'leader' ? 'Leader' : 'You', e.text || '');
    } else if (e.kind === 'answered') {
      node.className = 'msg answered'; appendMessage(node, 'Agent', e.text || '');
    } else if (e.kind === 'thought') {
      node.className = 'msg thought'; node.textContent = (e.text || '').slice(0, 400);
    } else if (e.kind === 'turn_ended') {
      node.className = 'msg turn' + (e.failed ? ' failed' : '');
      var bits = [e.failed ? 'failed' : 'done'];
      if (e.duration) { bits.push(Math.round(e.duration) + 's'); }
      if (e.cost) { bits.push('$' + Number(e.cost).toFixed(3)); }
      if (e.tokens_in || e.tokens_out) { bits.push('↑' + (e.tokens_in || 0) + ' ↓' + (e.tokens_out || 0)); }
      node.textContent = bits.join(' · ');
    } else {
      node.className = 'msg notice'; node.textContent = e.text || '';
    }
    return node;
  }

  function appendMessage(node, label, text) {
    var role = document.createElement('span'); role.className = 'msg-role'; role.textContent = label;
    var content = document.createElement('span'); content.className = 'msg-content'; content.textContent = text;
    node.appendChild(role); node.appendChild(content);
  }

  function toolLabel(name) {
    if (name === 'exec') { return 'Command'; }
    if (name === 'apply_patch') { return 'Edit'; }
    return name || 'Tool';
  }

  function toolSummary(e) {
    var raw = (e.headline || '').replace(/\s+/g, ' ').trim();
    if (!raw) { return e.running ? 'In progress' : 'Completed'; }
    if (e.name === 'exec') {
      var count = (raw.match(/tools.exec_command/g) || []).length;
      if (count > 1) { return 'Ran ' + count + ' commands'; }
      return 'Ran command';
    }
    return raw.slice(0, 88);
  }

  function compactPath(path) {
    var parts = String(path).split('/').filter(Boolean);
    if (parts.length < 2) { return path; }
    return '…/' + parts.slice(-2).join('/');
  }

  // Entries carry stable ids; answers stream and tool rows close in place,
  // so each entry is re-rendered only when its serialized form changes.
  function renderChat(data) {
    var entries = (data && data.entries) || [];
    var stick = isAtBottom(el.chatList);
    var seen = {};
    var prev = null;
    el.chatList.classList.toggle('empty', entries.length === 0);
    el.chatList.setAttribute('data-empty', entries.length ? '' : 'No conversation yet');
    entries.forEach(function (e) {
      var id = e.id || (e.kind + ':' + (e.text || e.headline || ''));
      seen[id] = true;
      var key = JSON.stringify(e);
      var cached = state.chatNodes[id];
      var node;
      if (cached && cached.key === key) {
        node = cached.node;
      } else {
        node = buildEntry(e);
        if (cached) {
          if (cached.node.open) { node.open = true; }
          el.chatList.replaceChild(node, cached.node);
        } else if (prev && prev.nextSibling) {
          el.chatList.insertBefore(node, prev.nextSibling);
        } else {
          el.chatList.appendChild(node);
        }
        state.chatNodes[id] = { node: node, key: key };
      }
      prev = node;
    });
    Object.keys(state.chatNodes).forEach(function (id) {
      if (!seen[id]) {
        var gone = state.chatNodes[id].node;
        if (gone.parentNode === el.chatList) { el.chatList.removeChild(gone); }
        delete state.chatNodes[id];
      }
    });
    // `running` means the agent process is alive between turns; a turn in
    // progress is `in_flight` (or `thinking` while it reasons).
    state.chatRunning = !!(data && (data.in_flight || data.thinking));
    el.interrupt.hidden = !state.chatRunning || isPaneReadOnly(state.selected);
    var alive = !!(data && data.running);
    el.chatState.textContent = state.chatRunning
      ? (data.thinking ? '생각 중…' : '작업 중…') + (data.summary ? ' · ' + data.summary : '')
      : (alive ? '대기 중' : '중지됨') + (data && data.summary ? ' · ' + data.summary : '');
    if (stick) { el.chatList.scrollTop = el.chatList.scrollHeight; }
  }

  function refreshChat() {
    var t = state.selected;
    if (!isChat(t)) { return Promise.resolve(); }
    return api('GET', '/api/targets/' + encodeURIComponent(t.surface_id) + '/transcript?limit=200')
      .then(function (data) {
        if (!isCurrentTarget(t)) { return; }
        renderChat(data);
        state.lastError = null;
        var access = isPaneReadOnly(t) ? 'chat transcript · read only' : 'chat';
        setStatus(access + ' · ' + (t.agent_name || t.agent_cli || 'agent') + ' · ' + new Date().toLocaleTimeString());
      })
      .catch(function (err) {
        if (!isCurrentTarget(t)) { return; }
        state.lastError = err;
        if (err.code === 'session_unavailable' && t.kind === 'pane') {
          setStatus('chat session 준비 중 · 다음 poll에서 재시도', true);
          return;
        }
        setStatus(describeError(err), true);
        if (err.code === 'not_exposed' || err.code === 'target_gone') {
          return loadTargets();
        }
      });
  }

  function refreshScreen() {
    var t = state.selected;
    if (isChat(t)) { return refreshChat(); }
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
      if (document.hidden) { return; }
      refreshNow();
    }, POLL_MS);
    // A running agent turn streams text; poll it twice as often.
    state.fastPollTimer = window.setInterval(function () {
      if (document.hidden || !state.chatRunning || !isChat(state.selected)) { return; }
      refreshNow();
    }, POLL_MS / 2);
  }

  function stopPolling() {
    if (state.pollTimer) {
      window.clearInterval(state.pollTimer);
      state.pollTimer = null;
    }
    if (state.fastPollTimer) {
      window.clearInterval(state.fastPollTimer);
      state.fastPollTimer = null;
    }
  }

  // ── input ────────────────────────────────────────────────────────────

  function sendText(text) {
    var t = state.selected;
    if (!t || isPaneReadOnly(t)) { return; }
    var id = requestId();
    el.send.disabled = true;
    setSendStatus('sending…');
    api('POST', '/api/targets/' + encodeURIComponent(t.surface_id) + '/text', { text: text, request_id: id, mode: isChat(t) ? 'chat' : 'terminal' })
      .then(function (data) {
        if (isChat(t)) {
          setSendStatus(data.deduplicated ? 'already sent' : 'turn sent');
        } else if (t.kind === 'leader') {
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

  el.viewChat.addEventListener('click', function () { setMode('chat'); });
  el.viewTerminal.addEventListener('click', function () { setMode('terminal'); });

  el.screen.addEventListener('scroll', function () {
    el.jump.hidden = isAtBottom(el.screen);
  });

  el.jump.addEventListener('click', function () {
    el.screen.scrollTop = el.screen.scrollHeight;
    el.jump.hidden = true;
  });

  el.interrupt.addEventListener('click', function () {
    var t = state.selected;
    if (!isChat(t) || isPaneReadOnly(t)) { return; }
    el.interrupt.disabled = true;
    api('POST', '/api/targets/' + encodeURIComponent(t.surface_id) + '/interrupt', {})
      .then(function () { setSendStatus('interrupted'); refreshNow(); })
      .catch(function (err) { setSendStatus(describeError(err), true); })
      .then(function () { el.interrupt.disabled = false; });
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
