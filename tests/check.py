import json, os, sqlite3, subprocess, tempfile
from pathlib import Path
binary = Path(__file__).resolve().parents[1] / 'dist/ai工作台.app/Contents/MacOS/CodexProgress'
with tempfile.TemporaryDirectory() as root:
    db = sqlite3.connect(Path(root) / 'state_5.sqlite')
    db.execute('CREATE TABLE threads(id,title,cwd,rollout_path,archived,agent_role,source,updated_at,name,project_id)')
    for i, events, source in [(1,['task_started'],'desktop'), (2,['task_started','task_complete'],'desktop'), (3,['task_started'], '{"subagent":{"other":"guardian"}}')]:
        p = Path(root) / f'{i}.jsonl'
        p.write_text(''.join(json.dumps({'type':'event_msg','payload':{'type':e}})+'\n' for e in events))
        db.execute('INSERT INTO threads(id,title,cwd,rollout_path,archived,agent_role,source,updated_at) VALUES(?,?,?,?,0,NULL,?,?)', (str(i),'fixture',root,str(p),source,i))
    db.commit(); db.close()
    result = subprocess.run([str(binary),'--diagnose'], env={**os.environ,'CODEX_HOME':root}, capture_output=True,text=True)
    assert result.returncode == 0 and 'threads=2, running=1, error=none' in result.stdout, result
    with tempfile.TemporaryDirectory() as missing:
        result = subprocess.run([str(binary),'--diagnose'], env={**os.environ,'CODEX_HOME':missing},capture_output=True,text=True)
        assert result.returncode == 1 and '无法读取' in result.stdout, result
print('PASS: active/completed events, internal-thread filtering, missing database')
# Progress must reflect events and plans, and reset when a new turn starts.
with tempfile.TemporaryDirectory() as root:
    db = sqlite3.connect(Path(root) / 'state_5.sqlite')
    db.execute('CREATE TABLE threads(id,title,cwd,rollout_path,archived,agent_role,source,updated_at,name,project_id)')
    def start(): return {'type':'event_msg','payload':{'type':'task_started'}}
    def command(cmd): return {'type':'response_item','payload':{'type':'custom_tool_call','name':'exec','input':'text(await tools.exec_command('+json.dumps({'cmd':cmd})+'));'}}
    def patch(): return {'type':'response_item','payload':{'type':'custom_tool_call','name':'apply_patch','input':'*** Begin Patch\n*** End Patch'}}
    def plan(): return {'type':'response_item','payload':{'type':'function_call','name':'update_plan','arguments':json.dumps({'plan':[{'step':'implement','status':'completed'},{'step':'verify','status':'in_progress'}]})}}
    fixtures = {
        'prepare':[start()],
        'long_turn':[start(),{'type':'event_msg','payload':{'type':'token_count','padding':'x'*700000}},command('pytest')],
        'edit':[start(),patch()],
        'verify':[start(),command('python3 tests/check.py')],
        'back_to_edit':[start(),command('pytest'),patch()],
        'reset':[start(),command('pytest'),start()],
        'planned':[start(),plan()],
        'write_test':[start(),command("cat > tests/test_example.py <<'PY'\npytest\nPY")],
    }
    for name,events in fixtures.items():
        p=Path(root)/f'{name}.jsonl'
        p.write_text(''.join(json.dumps(event)+'\n' for event in events))
        db.execute('INSERT INTO threads(id,title,cwd,rollout_path,archived,agent_role,source,updated_at) VALUES(?,?,?,?,0,NULL,?,0)',(name,name,root,str(p),'desktop'))
    db.commit(); db.close()
    result=subprocess.run([str(binary),'--diagnose-stages'],env={**os.environ,'CODEX_HOME':root},capture_output=True,text=True,check=True)
    rows={row['id']:row for row in json.loads(result.stdout)}
    for name,value in [('prepare',10),('edit',45),('verify',75),('back_to_edit',45),('reset',10),('write_test',45),('long_turn',75)]:
        assert rows[name]['percent']==value,(name,rows[name])
    assert rows['long_turn']['state']=='运行中'
    assert rows['planned']['percent']==50 and rows['planned']['planned']
    assert rows['planned']['remaining']=='剩余 1 个计划步骤'
print('PASS: stage evidence, revision, turn reset, real plan ratio, heredoc exclusion')

subprocess.run([str(binary),'--selfcheck-lifecycle'], check=True)

subprocess.run([str(binary),'--selfcheck-links'], check=True)

subprocess.run([str(binary),'--selfcheck-names'], check=True)

subprocess.run([str(binary),'--selfcheck-orb'], check=True)

subprocess.run([str(binary),'--selfcheck-pinning'], check=True)

subprocess.run([str(binary),'--selfcheck-window-actions'], check=True)
subprocess.run([str(binary),'--selfcheck-permissions'], check=True)
subprocess.run([str(binary),'--selfcheck-personalization'], check=True)
