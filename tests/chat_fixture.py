"""Private protocol fixture: no network, credentials, model requests, or shell execution."""
import json
import os
import sys
from pathlib import Path

root = Path(os.environ['CODEX_HOME'])
history = [{'id': 'old-turn', 'status': 'completed', 'items': [
    {'id': f'old-{i}', 'type': 'userMessage' if i % 2 == 0 else 'agentMessage',
     **({'content': [{'type': 'text', 'text': f'历史消息 {i}'}]} if i % 2 == 0 else {'text': f'历史消息 {i}'})}
    for i in range(24)]}]
serial = 0
active = {}
prompts = {}

def emit(value):
    data = (json.dumps(value, ensure_ascii=False) + '\n').encode()
    # Split both framing and UTF-8 characters across pipe reads.
    for offset in range(0, len(data), 7):
        sys.stdout.buffer.write(data[offset:offset + 7])
        sys.stdout.buffer.flush()

def result(wire, value): emit({'id': wire, 'result': value})
def event(method, params): emit({'method': method, 'params': params})
def complete(thread, turn):
    event('turn/completed', {'threadId': thread, 'turn': {'id': turn, 'status': 'completed', 'items': []}})
    active.pop(thread, None)

for line in sys.stdin:
    request = json.loads(line)
    method, params, wire = request.get('method'), request.get('params', {}), request.get('id')
    if not method:
        if wire in prompts:
            thread, turn, kind = prompts.pop(wire)
            if kind == 'unsupported': assert request['error']['code'] == -32601
            elif kind == 'approval': assert request['result']['decision'] == 'decline'
            elif kind == 'question': assert request['result']['answers']['choice']['answers'] == ['选项一']
            complete(thread, turn)
        continue
    if method == 'initialize': result(wire, {'userAgent': 'fixture'})
    elif method == 'initialized': pass
    elif method == 'account/read': result(wire, {'account': {'type': 'apiKey'}, 'requiresOpenaiAuth': True})
    elif method == 'thread/read':
        turns = history
        if params['threadId'] == 'busy': turns = [{'id': 'busy-turn', 'status': 'inProgress', 'items': []}]
        result(wire, {'thread': {'id': params['threadId'], 'name': '示例任务', 'cwd': str(root), 'turns': turns}})
    elif method in ('thread/resume', 'thread/start'):
        assert params['sandbox'] == 'workspace-write' and params['approvalPolicy'] == 'on-request'
        thread = params.get('threadId', 'created-fixture')
        if thread == 'unsupported-history':
            emit({'id': wire, 'error': {'code': -32600, 'message': 'Unsupported paginated history'}})
        else: result(wire, {'thread': {'id': thread, 'cwd': params.get('cwd', str(root)), 'turns': []}})
    elif method == 'thread/name/set': result(wire, {})
    elif method == 'turn/start':
        assert params['approvalPolicy'] == 'on-request'
        serial += 1
        thread, turn, text = params['threadId'], f'live-{serial}', params['input'][0]['text']
        active[thread] = turn
        if text == '早结束':
            complete(thread, turn)
            result(wire, {'turn': {'id': turn, 'status': 'inProgress', 'items': []}})
            continue
        result(wire, {'turn': {'id': turn, 'status': 'inProgress', 'items': []}})
        event('turn/started', {'threadId': thread, 'turn': {'id': turn, 'status': 'inProgress', 'items': []}})
        event('item/started', {'threadId': thread, 'item': {'id': turn + '-user', 'type': 'userMessage', 'content': [{'type': 'text', 'text': text}]}})
        event('item/started', {'threadId': thread, 'item': {'id': turn + '-reply', 'type': 'agentMessage', 'text': ''}})
        event('item/agentMessage/delta', {'threadId': thread, 'itemId': turn + '-reply', 'delta': '你好，'})
        event('item/agentMessage/delta', {'threadId': thread, 'itemId': turn + '-reply', 'delta': '回复正在同步。'})
        if text in ['审批测试', '问题测试', '不支持的交互']:
            wire_id = 900 + serial
            kind = {'审批测试': 'approval', '问题测试': 'question', '不支持的交互': 'unsupported'}[text]
            method = {'approval': 'item/commandExecution/requestApproval', 'question': 'item/tool/requestUserInput', 'unsupported': 'item/permissions/requestApproval'}[kind]
            prompts[wire_id] = (thread, turn, kind)
            extra = {'questions': [{'id': 'choice', 'question': '请选择', 'header': '选择', 'options': [{'label': '选项一', 'description': '测试回答'}]}]} if kind == 'question' else {'command': 'fixture command only', 'reason': '测试审批'}
            emit({'id': wire_id, 'method': method, 'params': {'threadId': thread, 'turnId': turn, 'itemId': turn + '-tool', **extra}})
            continue
        if text == '连接中断': sys.exit(0)
        if text == '等待停止': continue
        event('item/completed', {'threadId': thread, 'item': {'id': turn + '-reply', 'type': 'agentMessage', 'text': '你好，回复正在同步。'}})
        complete(thread, turn)
    elif method == 'turn/interrupt':
        result(wire, {})
        complete(params['threadId'], params['turnId'])
    else: emit({'id': wire, 'error': {'code': -32601, 'message': 'Unsupported fixture method'}})
