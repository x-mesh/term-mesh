#!/usr/bin/env python3
"""Exercise task-bound followups and cwd reset through the app and Codex bridge."""
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
import json,sys,time
TRACE = %r
for raw in sys.stdin:
 r=json.loads(raw); m=r.get('method'); i=r.get('id')
 if m=='initialize': print(json.dumps({'id':i,'result':{}}),flush=True)
 elif m=='thread/start': print(json.dumps({'id':i,'result':{'thread':{'id':'task-thread'}}}),flush=True)
 elif m=='turn/start':
  p=r['params']; text=''.join(x.get('text','') for x in p.get('input',[]))
  with open(TRACE,'a') as f: f.write(json.dumps({'text':text,'cwd':p.get('cwd')})+'\n')
  print(json.dumps({'id':i,'result':{'turn':{'id':'task-turn'}}}),flush=True)
  answer='STATUS: DONE\nFILES: none\nVERIFY: pong\nNEXT: none\nFULL_REPORT: n/a\npong'
  if 'CASE_BLOCK' in text: answer='STATUS: BLOCKED\nFILES: none\nVERIFY: blocked\nNEXT: retry'
  elif 'CASE_DONE' in text: answer='STATUS: DONE\nFILES: none\nVERIFY: passed\nNEXT: none'
  print(json.dumps({'method':'item/completed','params':{'item':{'type':'agentMessage','text':answer}}}),flush=True)
  print(json.dumps({'method':'turn/completed','params':{'threadId':'task-thread','turn':{'status':'completed'}}}),flush=True)
'''

def wait(check, label):
 end=time.monotonic()+40
 while time.monotonic()<end:
  value=check()
  if value: return value
  time.sleep(.1)
 raise termmeshError('timeout: '+label)

def main():
 repo=Path(__file__).resolve().parents[1]
 cli=repo/'daemon/target/release/tm-agent'
 team='task817-'+uuid.uuid4().hex[:8]; agent='worker817'
 old,value=_read_default()
 with tempfile.TemporaryDirectory(prefix='term-mesh-task817-') as tmp:
  root=Path(tmp); trace=root/'trace'; fake=root/'codex'; fake.write_text(FAKE % str(trace)); fake.chmod(0o755)
  subprocess.run(['defaults','write',DEFAULTS_DOMAIN,DEFAULTS_KEY,'-string',str(fake)],check=True)
  try:
   with termmesh() as c:
    c.team_create(team,[])
    try:
     env={k:v for k,v in os.environ.items() if not k.startswith('TERMMESH_LEADER_') and k not in ('TERMMESH_PEER_SOCKET','TERMMESH_DAEMON_SOCKET','TERMMESH_DAEMON_UNIX_PATH')}
     env.update(TERMMESH_SOCKET=c.socket_path,TERMMESH_SOCKET_PATH=c.socket_path,TERMMESH_TEAM=team)
     def command(*args,success=True):
      p=subprocess.run([str(cli),*args],cwd=repo,env=env,text=True,capture_output=True,timeout=90)
      if success and p.returncode: raise termmeshError(f'{args}: {p.stdout} {p.stderr}')
      if not success and not p.returncode: raise termmeshError(f'expected refusal: {args}')
      return p
     command('add','reviewer','--name',agent,'--cli','codex','--warmup','--warmup-timeout','40')
     def records(): return [json.loads(x) for x in trace.read_text().splitlines()] if trace.exists() else []
     initial=wait(lambda: records(),'warmup')[0]['cwd']
     initial_task_count=len(c.team_task_list(team))
     focus_workspace=c.current_workspace()
     focus_surfaces=[x[1] for x in c.list_surfaces() if x[2]]
     status=c.team_status(team)
     members=status.get('agents',status.get('members',[]))
     member=next(x for x in members if x.get('name')==agent)
     instance=member.get('agent_instance_id') or member.get('instance_id') or member.get('agentInstanceId')
     if not instance: raise termmeshError(f'missing instance: {member}')
     def task(title,path=None):
      t=c._call('team.task.create',{'team_name':team,'title':title,'assignee':agent,'agent_instance_id':instance})
      tid=t['id']
      if path: c._call('team.task.update',{'team_name':team,'task_id':tid,'worktree_path':str(path)})
      return tid
     def state(tid): return next(x for x in c.team_task_list(team) if x['id']==tid)['status']
     def arrival(marker): return wait(lambda: next((r for r in records() if marker in r['text']),None),marker)
     a=root/'worktree-a'; a.mkdir(); b=root/'worktree-b'; b.mkdir()
     ta=task('cwd A',a)
     command('send',agent,'CASE_BLOCK A817','--task',ta)
     assert arrival('A817')['cwd']==str(a)
     wait(lambda: state(ta)=='blocked','task A blocked')
     command('send',agent,'CASE_DONE FOLLOW817','--task',ta)
     assert arrival('FOLLOW817')['cwd']==str(a)
     wait(lambda: state(ta)=='completed','task A completed')
     report_path=Path.home()/'.term-mesh/results'/team/(ta+'.md')
     wait(lambda: report_path.exists() and 'STATUS: DONE' in report_path.read_text(),'task report file')
     completed_report=report_path.read_text()
     command('send',agent,'CASE_DONE REFUSE817','--task',ta,success=False)
     tb=task('cwd B',b)
     command('send',agent,'CASE_DONE B817','--task',tb)
     assert arrival('B817')['cwd']==str(b)
     wait(lambda: state(tb)=='completed','task B completed')
     tc=task('base directory')
     command('send',agent,'CASE_DONE BASE817','--task',tc)
     assert arrival('BASE817')['cwd']==initial,(initial,records())
     wait(lambda: state(tc)=='completed','base task completed')
     command('send',agent,'CHAT817','--no-report')
     assert arrival('CHAT817')['cwd']==initial
     assert c.current_workspace()==focus_workspace
     assert [x[1] for x in c.list_surfaces() if x[2]]==focus_surfaces
     assert report_path.read_text()==completed_report
     assert len(c.team_task_list(team))==initial_task_count+3
     assert not any('REFUSE817' in r['text'] for r in records())
     print(json.dumps({'initial_cwd':initial,'turns':records(),'tasks':c.team_task_list(team)},indent=2))
    finally: c.team_destroy(team)
  finally: _restore_default(old,value)
 print('PASS: task followup completes the same task; A/B/base/chat cwd and terminal-task refusal hold through the app')
 return 0

if __name__=='__main__': raise SystemExit(main())
