#!/usr/bin/env python3
"""A native worker that reports while it leaves edits uncommitted (#818).

The worker is a fake Codex behind the real bridge, settled from its turn text
the way the incident's worker was: it never runs `tm-agent reply`. For each
task it optionally writes a file into the turn's cwd (the task worktree) and
then answers NEEDS_REVIEW, BLOCKED or DONE. The status must stay as reported,
and `task get`, `wait`, `status` and `collect --headers` must carry what the
checkout held.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
from test_agent_send_queue_latency import _read_default, _restore_default, DEFAULTS_DOMAIN, DEFAULTS_KEY
from termmesh import termmesh, termmeshError

FAKE = r'''#!/usr/bin/env python3
import json,os,sys
TRACE = %r
for raw in sys.stdin:
 r=json.loads(raw); m=r.get('method'); i=r.get('id')
 if m=='initialize': print(json.dumps({'id':i,'result':{}}),flush=True)
 elif m=='thread/start': print(json.dumps({'id':i,'result':{'thread':{'id':'t818'}}}),flush=True)
 elif m=='turn/start':
  p=r['params']; text=''.join(x.get('text','') for x in p.get('input',[])); cwd=p.get('cwd')
  with open(TRACE,'a') as f: f.write(json.dumps({'text':text,'cwd':cwd})+'\n')
  print(json.dumps({'id':i,'result':{'turn':{'id':'turn818'}}}),flush=True)
  if 'CASE_DIRTY' in text and cwd:
   with open(os.path.join(cwd,'left-behind.txt'),'w') as f: f.write('half done\n')
  status='DONE'
  if 'CASE_REVIEW' in text: status='NEEDS_REVIEW'
  elif 'CASE_BLOCK' in text: status='BLOCKED'
  answer='STATUS: '+status+'\nFILES: left-behind.txt\nVERIFY: n/a\nNEXT: n/a\nFULL_REPORT: n/a\nexecution wrapper rejected the commit'
  if 'CASE_' not in text: answer='STATUS: DONE\nFILES: none\nVERIFY: pong\nNEXT: none\nFULL_REPORT: n/a\npong'
  print(json.dumps({'method':'item/completed','params':{'item':{'type':'agentMessage','text':answer}}}),flush=True)
  print(json.dumps({'method':'turn/completed','params':{'threadId':'t818','turn':{'status':'completed'}}}),flush=True)
'''


def wait(check, label, timeout=40):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = check()
        if value:
            return value
        time.sleep(.1)
    raise termmeshError('timeout: ' + label)


def git(*args, cwd):
    subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True)


def repository(root, name):
    repo = root / name
    repo.mkdir()
    git('init', '-q', cwd=repo)
    (repo / 'base.txt').write_text('base\n')
    git('add', 'base.txt', cwd=repo)
    git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base', cwd=repo)
    return repo


def main():
    repo_root = Path(__file__).resolve().parents[1]
    cli = repo_root / 'daemon/target/release/tm-agent'
    team = 'task818-' + uuid.uuid4().hex[:8]
    agent = 'worker818'
    old, value = _read_default()
    with tempfile.TemporaryDirectory(prefix='term-mesh-task818-') as tmp:
        root = Path(tmp).resolve()
        trace = root / 'trace'
        fake = root / 'codex'
        fake.write_text(FAKE % str(trace))
        fake.chmod(0o755)
        subprocess.run(['defaults', 'write', DEFAULTS_DOMAIN, DEFAULTS_KEY, '-string', str(fake)], check=True)
        try:
            with termmesh() as c:
                c.team_create(team, [])
                try:
                    env = {k: v for k, v in os.environ.items()
                           if not k.startswith('TERMMESH_LEADER_')
                           and k not in ('TERMMESH_PEER_SOCKET', 'TERMMESH_DAEMON_SOCKET', 'TERMMESH_DAEMON_UNIX_PATH')}
                    env.update(TERMMESH_SOCKET=c.socket_path, TERMMESH_SOCKET_PATH=c.socket_path, TERMMESH_TEAM=team)

                    def command(*args):
                        p = subprocess.run([str(cli), *args], cwd=repo_root, env=env, text=True,
                                           capture_output=True, timeout=120)
                        if p.returncode:
                            raise termmeshError(f'{args}: {p.stdout} {p.stderr}')
                        return p

                    def output_json(*args):
                        out = command(*args).stdout
                        return json.loads(out[out.index('{'):])

                    command('add', 'reviewer', '--name', agent, '--cli', 'codex', '--warmup', '--warmup-timeout', '40')
                    status = c.team_status(team)
                    members = status.get('agents', status.get('members', []))
                    member = next(x for x in members if x.get('name') == agent)
                    instance = member.get('agent_instance_id') or member.get('instance_id') or member.get('agentInstanceId')
                    if not instance:
                        raise termmeshError(f'missing instance: {member}')

                    def task(title, path=None):
                        t = c._call('team.task.create', {'team_name': team, 'title': title,
                                                          'assignee': agent, 'agent_instance_id': instance})
                        if path:
                            c._call('team.task.update', {'team_name': team, 'task_id': t['id'],
                                                         'worktree_path': str(path)})
                        return t['id']

                    def get(tid):
                        return c._call('team.task.get', {'team_name': team, 'task_id': tid})

                    def settled(tid, expected_status):
                        def check():
                            t = get(tid)
                            u = t.get('uncommitted_check') or {}
                            if t['status'] == expected_status and u.get('state') not in (None, 'pending'):
                                return t
                            return None
                        return wait(check, f'{tid} {expected_status} with a finished check')

                    review_repo = repository(root, 'review')
                    t_review = task('left edits, NEEDS_REVIEW', review_repo)
                    command('send', agent, 'CASE_DIRTY CASE_REVIEW R818', '--task', t_review)
                    # Called before the check is known to have finished: wait
                    # itself must re-read a pending check, not print it.
                    immediate = output_json('wait', '--task', t_review, '--mode', 'any', '--timeout', '30')
                    first = immediate['result']['task']['uncommitted_check']
                    assert first['state'] == 'checked' and first['count'] == 1, first
                    review = settled(t_review, 'review_ready')
                    check = review['uncommitted_check']
                    assert check['state'] == 'checked', check
                    assert check['count'] == 1 and check['paths'] == ['left-behind.txt'], check
                    assert check['checkout'] == str(review_repo), check

                    waited = output_json('wait', '--task', t_review, '--mode', 'any', '--timeout', '30')
                    assert waited['result']['task']['uncommitted_check']['count'] == 1, waited

                    inbox_wait = output_json('wait', '--mode', 'review_ready', '--timeout', '30')
                    item = next(i for i in inbox_wait['result']['items'] if i.get('task_id') == t_review)
                    assert item['uncommitted_check']['count'] == 1, item

                    now = c.team_status(team)
                    row = next(a for a in now.get('agents', now.get('members', [])) if a.get('name') == agent)
                    assert row.get('active_task_id') == t_review, row
                    assert row['active_task_uncommitted_check']['count'] == 1, row

                    collected = output_json('collect', '--headers')
                    entry = next(r for r in collected['result']['results'] if r.get('task_id') == t_review)
                    assert entry['uncommitted_check']['count'] == 1, entry

                    blocked_repo = repository(root, 'blocked')
                    t_blocked = task('left edits, BLOCKED', blocked_repo)
                    command('send', agent, 'CASE_DIRTY CASE_BLOCK B818', '--task', t_blocked)
                    assert settled(t_blocked, 'blocked')['uncommitted_check']['count'] == 1

                    done_repo = repository(root, 'done')
                    t_done = task('left edits, DONE', done_repo)
                    command('send', agent, 'CASE_DIRTY CASE_DONE D818', '--task', t_done)
                    assert settled(t_done, 'completed')['uncommitted_check']['count'] == 1

                    clean_repo = repository(root, 'clean')
                    t_clean = task('clean, DONE', clean_repo)
                    command('send', agent, 'CASE_DONE C818', '--task', t_clean)
                    clean = settled(t_clean, 'completed')['uncommitted_check']
                    assert clean['state'] == 'checked' and clean['count'] == 0, clean

                    t_plain = task('no worktree, DONE')
                    command('send', agent, 'CASE_DONE P818', '--task', t_plain)
                    plain = settled(t_plain, 'completed')['uncommitted_check']
                    assert plain['state'] == 'skipped' and plain['reason'] == 'no_task_worktree', plain

                    print(json.dumps({t: get(t)['uncommitted_check']
                                      for t in (t_review, t_blocked, t_done, t_clean, t_plain)}, indent=2))
                finally:
                    c.team_destroy(team)
        finally:
            _restore_default(old, value)
    print('PASS: native NEEDS_REVIEW/BLOCKED/DONE turns record the uncommitted edits; status, wait, collect and task get carry them')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
