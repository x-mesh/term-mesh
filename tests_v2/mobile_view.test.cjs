const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../Resources/mobile/app.js'), 'utf8');

function element() {
  const listeners = new Map();
  const classes = new Set();
  let content = '';
  return {
    get textContent() { return content; },
    set textContent(value) { content = value; this.children = []; },
    hidden: false, disabled: false, value: '', children: [],
    scrollHeight: 0, scrollTop: 0, clientHeight: 0,
    style: { removeProperty() {} },
    classList: {
      toggle(name, enabled) { if (enabled) classes.add(name); else classes.delete(name); },
      contains(name) { return classes.has(name); },
    },
    setAttribute() {},
    addEventListener(name, callback) { listeners.set(name, callback); },
    dispatch(name, event = {}) { listeners.get(name)?.({ preventDefault() {}, ...event }); },
    focus() {}, scrollIntoView() {}, removeAttribute() {},
    setSelectionRange() {},
    querySelectorAll() { return []; },
    appendChild(child) { this.children.push(child); child.parentNode = this; },
    removeChild(child) { this.children = this.children.filter(item => item !== child); },
  };
}

function page(initial, saved = {}, health = {}) {
  const nodes = new Map();
  const intervals = new Map();
  const storage = new Map(Object.entries(saved));
  const requests = [];
  let targets = initial;
  let pendingTargets = null;
  let targetsError = null;
  let transcript = {entries: [], running: true};
  let commandError = false;
  let pendingCommands = null;
  let prompt = null;
  let preview = [];
  let transcriptError = null;
  let models = { cli: 'codex', custom: false, current_model: 'Jev Auto', models: [
    { id: 'GLM 5', label: 'GLM 5', description: 'GLM', current: false },
    { id: 'Jev Auto', label: 'Jev Auto', description: 'auto', current: true },
  ] };
  let commands = [
    {name:'help', invocation:'/help', kind:'command', description:'도움말', source:'builtin', selectable:true},
    {name:'rc', invocation:'/rc', kind:'skill', description:'모바일 원격 제어', source:'user', selectable:true},
    {name:'deploy', invocation:'/deploy', kind:'skill', description:'배포 작업', source:'project', selectable:true},
  ];
  const copied = [];
  const document = {
    hidden: false, title: 'term-mesh', body: element(),
    getElementById(id) {
      if (!nodes.has(id)) nodes.set(id, element());
      return nodes.get(id);
    },
    createElement: element,
    createTextNode(text) { const node = element(); node.textContent = text; return node; },
    addEventListener() {},
  };
  const window = {
    location: { pathname: '/t/pane-1' },
    history: { replaceState() {} },
    localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
    navigator: { clipboard: { writeText: async text => { copied.push(text); } } },
    setInterval(callback, ms) { intervals.set(ms, callback); return ms; },
    clearInterval(ms) { intervals.delete(ms); },
    setTimeout() {}, clearTimeout() {},
  };
  const response = body => ({ ok: true, text: async () => JSON.stringify(body) });
  const bodies = [];
  const fetch = async (url, init) => {
    requests.push(url);
    if (init && init.body) bodies.push([url, JSON.parse(init.body)]);
    if (url === '/api/targets') {
      if (targetsError) {
        const error = targetsError;
        targetsError = null;
        throw error;
      }
      if (pendingTargets) return pendingTargets;
      return response({ targets });
    }
    if (url.endsWith('/commands')) {
      if (commandError) { commandError = false; throw new Error('catalog unavailable'); }
      if (pendingCommands) return pendingCommands;
      return response({items:commands});
    }
    if (url === '/api/health') return response({ ok: true, ...health });
    if (url.includes('/transcript')) {
      if (transcriptError) throw Object.assign(new Error('unavailable'), transcriptError);
      return response(transcript);
    }
    if (url.endsWith('/prompt')) {
      if (init && init.method === 'POST') { prompt = null; return response({ answered: 1 }); }
      return response({ prompt, preview });
    }
    if (url.endsWith('/models')) return response(models);
    if (url.endsWith('/effort')) {
      if (init && init.method === 'POST') return response({ message: 'Set effort level to low (this session only)', session_only: true });
      return response({ levels: ['low', 'medium', 'high'], current: 'high' });
    }
    if (url.endsWith('/model')) return response({ cli: models.cli, delivered: true, message: 'Model changed to glm-5 medium for this session only', session_only: true });
    return response({ text: 'shell screen' });
  };
  vm.runInNewContext(source, { document, window, fetch, console, URL, Date, Promise, Map, Set });
  return {
    nodes, requests, storage, bodies, document, copied,
    setCommands(next) { commands = next; },
    setTranscript(next) { transcript = next; },
    setPrompt(next) { prompt = next; },
    setPreview(next) { preview = next; },
    failTranscript(error) { transcriptError = error; },
    failCommands() { commandError = true; },
    pauseCommands() {
      let resolve;
      pendingCommands = new Promise(done => { resolve = done; });
      return items => { pendingCommands = null; resolve(response({items})); };
    },
    setTargets(next) { targets = next; },
    failTargets() { targetsError = new Error('network unavailable'); },
    tick() { intervals.get(2000)(); },
    pauseTargets() {
      let resolve;
      pendingTargets = new Promise(done => { resolve = done; });
      return next => { pendingTargets = null; resolve(response({ targets: next })); };
    },
  };
}

const pane = (chat_capable, surface_id = 'pane-1') => ({ surface_id, kind: 'pane', chat_capable, keys: 'safe', agent_cli: chat_capable ? 'claude' : '', cwd: '/project' });
const settle = () => new Promise(resolve => setImmediate(resolve));

for (const cli of ['claude', 'codex']) {
  test(`late ${cli} detection switches the same pane to Chat`, async () => {
    const app = page([pane(false)]);
    await settle();
    assert.equal(app.nodes.get('chat').hidden, true);
    app.setTargets([{ ...pane(true), agent_cli: cli }]);
    app.tick();
    await settle();
    assert.equal(app.nodes.get('view-switch').hidden, false);
    assert.equal(app.nodes.get('chat').hidden, false);
    assert.equal(app.nodes.get('screen-wrap').hidden, true);
    assert.ok(app.requests.some(url => url.includes('/transcript')));
  });
}

test('explicit Term preference survives detection', async () => {
  const app = page([pane(false)], { 'term-mesh-view:pane-1': 'terminal' });
  await settle();
  app.setTargets([pane(true)]);
  app.tick();
  await settle();
  assert.equal(app.nodes.get('chat').hidden, true);
  assert.equal(app.nodes.get('view-switch').hidden, false);
});

test('shell stays in Terminal', async () => {
  const app = page([pane(false)]);
  await settle();
  app.tick();
  await settle();
  assert.equal(app.nodes.get('view-switch').hidden, true);
  assert.equal(app.nodes.get('chat').hidden, true);
  assert.equal(app.requests.filter(url => url.includes('/transcript')).length, 0);
});

test('manual Term selection survives capability loss and recovery', async () => {
  const app = page([pane(true)]);
  await settle();
  app.nodes.get('view-terminal').dispatch('click');
  assert.equal(app.storage.get('term-mesh-view:pane-1'), 'terminal');
  app.setTargets([pane(false)]);
  app.tick();
  await settle();
  app.setTargets([pane(true)]);
  app.tick();
  await settle();
  assert.equal(app.nodes.get('chat').hidden, true);
  app.nodes.get('view-chat').dispatch('click');
  assert.equal(app.nodes.get('chat').hidden, false);
});

test('failed capability lookup reports an error and the next poll recovers', async () => {
  const app = page([pane(false)]);
  await settle();
  app.failTargets();
  app.tick();
  await settle();
  assert.match(app.nodes.get('status').textContent, /network unavailable/);
  assert.equal(app.nodes.get('refresh').disabled, false);
  app.setTargets([pane(true)]);
  app.tick();
  await settle();
  assert.equal(app.nodes.get('chat').hidden, false);
});

test('lost capability returns to Terminal and detection restores Chat', async () => {
  const app = page([pane(true)]);
  await settle();
  app.setTargets([pane(false)]);
  app.tick();
  await settle();
  assert.equal(app.nodes.get('chat').hidden, true);
  assert.equal(app.nodes.get('view-switch').hidden, true);
  app.setTargets([pane(true)]);
  app.tick();
  await settle();
  assert.equal(app.nodes.get('chat').hidden, false);
});

test('overlapping polls do not duplicate target requests or steal selection', async () => {
  const app = page([pane(false), pane(true, 'pane-2')]);
  await settle();
  const release = app.pauseTargets();
  const before = app.requests.filter(url => url === '/api/targets').length;
  app.tick();
  app.tick();
  app.nodes.get('target').value = 'pane-2';
  app.nodes.get('target').dispatch('change');
  release([pane(true), pane(true, 'pane-2')]);
  await settle();
  assert.equal(app.requests.filter(url => url === '/api/targets').length, before + 1);
  assert.equal(app.nodes.get('target').value, 'pane-2');
  assert.equal(app.nodes.get('chat').hidden, false);
});

test('slash opens a searchable command and skill picker without sending', async () => {
  const app = page([pane(true)]);
  await settle();
  const input = app.nodes.get('text');
  input.value = '/';
  input.dispatch('input');
  await settle();
  assert.equal(app.nodes.get('command-picker').hidden, false);
  assert.ok(app.requests.some(url => url.endsWith('/commands')));
  assert.equal(app.nodes.get('command-list').children.length, 3);
  const search = app.nodes.get('command-search');
  search.value = '배포';
  search.dispatch('input');
  assert.equal(app.nodes.get('command-list').children.length, 1);
  app.nodes.get('command-list').children[0].dispatch('click');
  assert.equal(input.value, '/deploy ');
  assert.equal(app.nodes.get('command-picker').hidden, true);
  assert.equal(app.requests.some(url => url.endsWith('/text')), false);
});

test('picker ranks a name match above a description match', async () => {
  const app = page([pane(true)]);
  await settle();
  app.setCommands([
    {name:'cso', invocation:'/cso', kind:'skill', description:'threat model audit', source:'user', selectable:true},
    {name:'model', invocation:'/model', kind:'command', description:'모델 선택', source:'builtin', selectable:true},
  ]);
  app.nodes.get('commands-toggle').dispatch('click');
  await settle();
  app.nodes.get('command-search').value = '/model';
  app.nodes.get('command-search').dispatch('input');
  const rows = app.nodes.get('command-list').children;
  assert.equal(rows.length, 2);
  app.nodes.get('command-list').children[0].dispatch('click');
  assert.equal(app.nodes.get('text').value, '/model ');
});

test('choosing /model opens the model sheet instead of typing the command', async () => {
  const app = page([{ ...pane(true), agent_cli: 'codex' }]);
  await settle();
  app.setCommands([{name:'model', invocation:'/model', kind:'command', description:'모델 선택', source:'builtin', selectable:true, action:'pick_model'}]);
  app.nodes.get('text').value = '';
  app.nodes.get('commands-toggle').dispatch('click');
  await settle();
  app.nodes.get('command-list').children[0].dispatch('click');
  await settle();
  assert.equal(app.nodes.get('text').value, '', 'nothing is typed into the composer');
  assert.equal(app.nodes.get('model-picker').hidden, false);
  assert.ok(app.requests.some(url => url.endsWith('/models')));
  const rows = app.nodes.get('model-list').children;
  assert.equal(rows.length, 2);
  rows[0].dispatch('click');
  await settle();
  assert.deepEqual(app.bodies.at(-1), ['/api/targets/pane-1/model', { model: 'GLM 5' }]);
  assert.equal(app.nodes.get('model-picker').hidden, true);
  assert.match(app.nodes.get('send-status').textContent, /이 세션만/);
  assert.equal(app.requests.some(url => url.endsWith('/text')), false);
});

test('a running turn waiting on approval shows the question and answers it by number', async () => {
  const app = page([pane(true)]);
  app.setTranscript({ entries: [{ id: 'u1', kind: 'said', speaker: 'person', text: 'make b.txt' }], running: true, in_flight: true });
  app.setPrompt({ question: 'Do you want to proceed?', context: ['Bash command', 'touch b.txt'], fingerprint: 'fp-1',
    options: [{ index: 1, label: 'Yes' }, { index: 2, label: 'No' }] });
  await settle();
  app.tick();
  await settle();
  await settle();
  assert.equal(app.nodes.get('prompt-card').hidden, false);
  assert.equal(app.nodes.get('prompt-question').textContent, 'Do you want to proceed?');
  assert.equal(app.nodes.get('prompt-context').textContent, 'Bash command\ntouch b.txt');
  const buttons = app.nodes.get('prompt-options').children;
  assert.equal(buttons.length, 2);
  buttons[1].dispatch('click');
  await settle();
  assert.deepEqual(app.bodies.at(-1), ['/api/targets/pane-1/prompt', { fingerprint: 'fp-1', index: 2 }]);
  assert.equal(app.nodes.get('prompt-card').hidden, true);
});

test('an idle chat never asks the terminal for a prompt', async () => {
  const app = page([pane(true)]);
  app.setTranscript({ entries: [], running: true, in_flight: false });
  await settle();
  app.tick();
  await settle();
  assert.equal(app.requests.some(url => url.endsWith('/prompt')), false);
});

test('choosing /effort opens the effort sheet and posts the level', async () => {
  const app = page([pane(true)]);
  await settle();
  app.setCommands([{name:'effort', invocation:'/effort', kind:'command', description:'추론 강도', source:'builtin', selectable:true, action:'pick_effort'}]);
  app.nodes.get('commands-toggle').dispatch('click');
  await settle();
  app.nodes.get('command-list').children[0].dispatch('click');
  await settle();
  assert.ok(app.requests.some(url => url.endsWith('/effort')));
  assert.equal(app.nodes.get('model-title').textContent, '추론 강도');
  const rows = app.nodes.get('model-list').children;
  assert.equal(rows.length, 3);
  rows[0].dispatch('click');
  await settle();
  assert.deepEqual(app.bodies.at(-1), ['/api/targets/pane-1/effort', { level: 'low' }]);
});

test('a menu command is sent and the view switches to the terminal', async () => {
  const app = page([pane(true)]);
  await settle();
  app.setCommands([{name:'resume', invocation:'/resume', kind:'command', description:'이어가기', source:'builtin', selectable:true, action:'terminal'}]);
  app.nodes.get('commands-toggle').dispatch('click');
  await settle();
  app.nodes.get('command-list').children[0].dispatch('click');
  assert.equal(app.nodes.get('text').value, '/resume ');
  app.nodes.get('send-form').dispatch('submit');
  await settle();
  await settle();
  assert.equal(app.storage.get('term-mesh-view:pane-1'), 'terminal');
  assert.equal(app.nodes.get('chat').hidden, true);
});

test('a tagged dev app names itself in the header', async () => {
  const app = page([pane(true)], {}, { tag: 'mobmodel' });
  await settle();
  await settle();
  assert.equal(app.nodes.get('build-tag').hidden, false);
  assert.equal(app.nodes.get('build-tag').textContent, 'DEV mobmodel');
});

test('a fresh session reads as waiting for its first message, not as an error', async () => {
  const app = page([pane(true)]);
  app.failTranscript({ code: 'session_unavailable' });
  await settle();
  app.tick();
  await settle();
  assert.match(app.nodes.get('status').textContent, /첫 메시지/);
  assert.equal(app.nodes.get('status').classList.contains('error'), false);
});

test('the first turn of a fresh session still shows the live screen', async () => {
  const app = page([pane(true)]);
  app.failTranscript({ code: 'session_unavailable' });
  app.setPreview(['⏺ TCP slow start는']);
  await settle();
  app.tick();
  await settle();
  await settle();
  assert.ok(app.requests.some(url => url.endsWith('/prompt')));
  assert.equal(app.nodes.get('chat-live').hidden, false);
});

function find(node, predicate) {
  if (predicate(node)) return node;
  for (const child of node.children || []) {
    const hit = find(child, predicate);
    if (hit) return hit;
  }
  return null;
}

test('a running turn shows what the terminal is streaming', async () => {
  const app = page([pane(true)]);
  app.setTranscript({ entries: [], running: true, in_flight: true });
  app.setPreview(['⏺ Reading files', '✻ Thinking… (esc to interrupt)']);
  await settle();
  app.tick();
  await settle();
  await settle();
  assert.equal(app.nodes.get('chat-live').hidden, false);
  assert.match(app.nodes.get('chat-live').textContent, /Thinking/);
});

test('a turn that ends while the page is hidden marks the tab title', async () => {
  const app = page([pane(true)]);
  app.setTranscript({ entries: [], running: true, in_flight: true });
  await settle();
  app.tick();
  await settle();
  app.document.hidden = true;
  app.setTranscript({ entries: [{ id: 'a1', kind: 'answered', text: 'done' }], running: true, in_flight: false });
  app.tick();
  await settle();
  assert.ok(app.document.title.startsWith('✓ '), app.document.title);
});

test('code blocks in an answer get a copy button', async () => {
  const app = page([pane(true)]);
  app.setTranscript({ entries: [{ id: 'a1', kind: 'answered', text: 'run:\n```sh\nmake test\n```' }], running: true, in_flight: false });
  await settle();
  app.tick();
  await settle();
  const copy = find(app.nodes.get('chat-list'), node => node.className === 'md-code-copy');
  assert.ok(copy, 'copy button rendered');
  copy.dispatch('click');
  await settle();
  assert.deepEqual(app.copied, ['make test']);
});

test('Codex skill selection uses dollar invocation and preserves the draft', async () => {
  const app = page([{ ...pane(true), agent_cli: 'codex' }]);
  await settle();
  app.setCommands([{name:'rc', invocation:'$rc', kind:'skill', description:'모바일 원격 제어', source:'user', selectable:true}]);
  app.nodes.get('text').value = 'on';
  app.nodes.get('commands-toggle').dispatch('click');
  await settle();
  app.nodes.get('command-list').children[0].dispatch('click');
  assert.equal(app.nodes.get('text').value, '$rc on');
});

test('picker filters by kind and reports an empty search', async () => {
  const app = page([pane(true)]);
  await settle();
  app.nodes.get('commands-toggle').dispatch('click');
  await settle();
  app.nodes.get('command-filter-skills').dispatch('click');
  assert.equal(app.nodes.get('command-list').children.length, 2);
  app.nodes.get('command-search').value = 'missing';
  app.nodes.get('command-search').dispatch('input');
  assert.equal(app.nodes.get('command-list').children.length, 0);
  assert.match(app.nodes.get('command-status').textContent, /없습니다/);
});

test('picker keyboard selection and Escape do not submit the draft', async () => {
  const app = page([pane(true)]);
  await settle();
  const input = app.nodes.get('text');
  input.value = '/';
  input.dispatch('input');
  await settle();
  input.dispatch('keydown', {key:'ArrowDown'});
  input.dispatch('keydown', {key:'Tab'});
  assert.equal(input.value, '/rc ');
  app.nodes.get('commands-toggle').dispatch('click');
  await settle();
  app.nodes.get('command-search').dispatch('keydown', {key:'Escape'});
  assert.equal(app.nodes.get('command-picker').hidden, true);
  assert.equal(app.requests.some(url => url.endsWith('/text')), false);
});

test('shell never opens a command picker', async () => {
  const app = page([pane(false)]);
  await settle();
  app.nodes.get('text').value = '/';
  app.nodes.get('text').dispatch('input');
  assert.equal(app.nodes.get('commands-toggle').hidden, true);
  assert.equal(app.requests.some(url => url.endsWith('/commands')), false);
});

test('catalog errors are visible and retry loads the list', async () => {
  const app = page([pane(true)]);
  await settle();
  app.failCommands();
  app.nodes.get('commands-toggle').dispatch('click');
  await settle();
  assert.match(app.nodes.get('command-status').textContent, /불러오지 못했습니다/);
  app.nodes.get('command-status').children[0].dispatch('click');
  await settle();
  assert.equal(app.nodes.get('command-list').children.length, 3);
});

test('a late catalog response cannot reopen a picker after switching targets', async () => {
  const app = page([pane(true), pane(true, 'pane-2')]);
  await settle();
  const release = app.pauseCommands();
  app.nodes.get('commands-toggle').dispatch('click');
  app.nodes.get('target').value = 'pane-2';
  app.nodes.get('target').dispatch('change');
  release([{name:'stale',invocation:'/stale',kind:'skill',selectable:true}]);
  await settle();
  assert.equal(app.nodes.get('command-picker').hidden, true);
  app.nodes.get('commands-toggle').dispatch('click');
  await settle();
  assert.equal(app.nodes.get('command-list').children.length, 3);
});

test('dollar prefix lists skills and disabled commands cannot be selected', async () => {
  const app = page([{...pane(true),agent_cli:'codex'}]);
  await settle();
  app.setCommands([
    {name:'model',invocation:'/model',kind:'command',selectable:false,reason:'Terminal only'},
    {name:'rc',invocation:'$rc',kind:'skill',selectable:true},
  ]);
  app.nodes.get('text').value = '$';
  app.nodes.get('text').dispatch('input');
  await settle();
  assert.equal(app.nodes.get('command-list').children.length, 1);
  app.nodes.get('command-filter-all').dispatch('click');
  assert.equal(app.nodes.get('command-list').children.length, 2);
  app.nodes.get('command-list').children[0].dispatch('click');
  assert.equal(app.nodes.get('text').value, '$');
  assert.equal(app.requests.some(url => url.endsWith('/text')), false);
});

for (const activity of [{in_flight:true}, {thinking:true}]) {
  test(`spinner follows active turns: ${JSON.stringify(activity)}`, async () => {
    const app = page([pane(true)]);
    await settle();
    const status = app.nodes.get('chat-state');
    assert.equal(status.classList.contains('is-working'), false);
    app.setTranscript({entries:[], running:true, ...activity});
    app.tick();
    await settle();
    assert.equal(status.classList.contains('is-working'), true);
    app.setTranscript({entries:[], running:true});
    app.tick();
    await settle();
    assert.equal(status.classList.contains('is-working'), false);
  });
}

test('spinner is visible for read-only chat and resets when changing panes', async () => {
  const app = page([{...pane(true), keys:'none'}, pane(false,'pane-2')]);
  await settle();
  app.setTranscript({entries:[],running:true,in_flight:true});
  app.tick();
  await settle();
  assert.equal(app.nodes.get('interrupt').hidden, true);
  assert.equal(app.nodes.get('chat-state').classList.contains('is-working'), true);
  app.nodes.get('target').value = 'pane-2';
  app.nodes.get('target').dispatch('change');
  assert.equal(app.nodes.get('chat-state').classList.contains('is-working'), false);
});
