#!/usr/bin/env python3
"""Read observed Codex rollout content for the detail panel; no network access."""
import json
import sys
from pathlib import Path

import ai


def text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return '\n'.join(x['text'] for x in value if isinstance(x, dict)
                         and x.get('type') in ('text', 'input_text', 'output_text')
                         and isinstance(x.get('text'), str))
    return ''


def read_records(stream):
    for line in stream:
        try:
            row = json.loads(line)
            if isinstance(row, dict) and isinstance(row.get('payload'), dict):
                yield row
        except (ValueError, UnicodeError):
            continue


def pick(records):
    result = {'request': '', 'response': '', 'activity': '', 'turn': '', 'files': []}
    for row in records:
        kind, p = row.get('type'), row['payload']
        event = p.get('type')
        if kind == 'turn_context':
            for key in ('approval_policy', 'model', 'effort'):
                if isinstance(p.get(key), str):
                    result[key] = p[key]
            sandbox = p.get('sandbox_policy')
            if isinstance(sandbox, dict):
                result['sandbox'] = sandbox.get('type', '')
        if kind == 'session_meta':
            result['session_id'] = p.get('id', p.get('session_id', ''))
        if kind == 'event_msg' and event == 'task_started':
            result.update(response='', activity='', turn='턴 진행 중', files=[])
        elif kind == 'event_msg' and event == 'task_complete':
            result['turn'] = '턴 응답 종료'  # Not proof that the user's task succeeded.
            if isinstance(p.get('last_agent_message'), str) and p['last_agent_message']:
                result['response'] = ai.redact(p['last_agent_message'])[:6000]
        elif kind == 'event_msg' and event == 'turn_aborted':
            result['turn'] = '턴 중단'
        item = p.get('item', {}) if kind == 'event_msg' else {}
        if not isinstance(item, dict):
            item = {}
        role, text = '', ''
        if item.get('type') in ('UserMessage', 'AgentMessage'):
            role = 'user' if item['type'] == 'UserMessage' else 'assistant'
            if item.get('phase') != 'analysis':
                text = text_content(item.get('content'))
        elif kind == 'event_msg' and event in ('user_message', 'agent_message'):
            role = 'user' if event == 'user_message' else 'assistant'
            text = text_content(p.get('message'))
        elif kind == 'response_item' and event == 'message' and p.get('channel') != 'analysis':
            role, text = p.get('role'), text_content(p.get('content'))
        text = text.strip()
        if text and not text.startswith(ai.GENERATED_PREFIXES + ('# AGENTS.md instructions', '<environment_context>')):
            if role == 'user':
                clean = ai.redact(text)[:6000]
                if clean != result['request']:
                    result.update(response='', activity='', files=[], turn='')
                result['request'] = clean
            elif role == 'assistant':
                result['response'] = ai.redact(text)[:6000]
        if item.get('type') == 'CommandExecution':
            status = item.get('status', '')
            code = item.get('exit_code')
            result['activity'] = '명령 실행 · ' + str(status)
            if type(code) is int:
                result['activity'] += f' · 종료 코드 {code}'
        elif item.get('type') == 'McpToolCall':
            result['activity'] = f"도구 {item.get('server', '')}/{item.get('tool', '')} · {item.get('status', '')}"
        elif item.get('type') == 'FileChange':
            changes = item.get('changes', {})
            result['activity'] = '파일 변경 · ' + str(item.get('status', ''))
            if isinstance(changes, dict):
                result['files'] = list(changes)[:5]
        elif kind == 'response_item' and event in ('function_call', 'custom_tool_call'):
            result['activity'] = '도구 호출 · ' + str(p.get('name', ''))
    return result


def read(path):
    with open(path, 'rb') as stream:
        stream.seek(0, 2)
        size = stream.tell()
        start = max(0, size - 1048576)
        stream.seek(start)
        if start:
            stream.readline()  # Discard the potentially incomplete first record.
        result = pick(read_records(stream))
        if start and not result['request']:
            # Streaming fallback retains just the panel fields, not the whole log.
            stream.seek(0)
            result = pick(read_records(stream))
    return result


def screen_fields(screen):
    result = {'request': '', 'response': '', 'footer': ''}
    target = None
    placeholders = ('Ask Codex to do anything', 'Implement {feature}',
                    'Find and fix a bug in @filename', 'Write tests for @filename',
                    'Explain this codebase', 'Improve documentation in @filename',
                    'Summarize recent commits', 'Run /review on my current changes')
    for raw in screen.splitlines():
        line = raw.strip()
        if line.startswith('@@TTY:'):
            continue
        if 'Context ' in line and ('% used' in line or '% left' in line):
            result['footer'] = line
            target = None
        elif line.startswith('› '):
            value = line[2:].strip()
            target = None
            if value and value not in placeholders:
                result.update(request=value, response='')
                target = 'request'
        elif raw.startswith('• '):
            value = line[2:]
            if value.startswith(('Ran ', 'Explored', 'Called ', 'Updated Plan', 'Edited ', 'Added ', 'Deleted ')):
                target = None
            else:
                result['response'] = value
                target = 'response'
        elif line.startswith(('Worked for ', 'Working ', '└', '← for agents', '? for shortcuts')):
            target = None
        elif target and line:
            result[target] += '\n' + line
    return {key: ai.redact(value)[:6000] for key, value in result.items()}


def display_screen(screen, detailed=False):
    result = screen_fields(screen)
    ai.section('표시 출처', '현재 터미널 화면', 1)
    for field, label in (('request', '마지막 요청 · 화면'), ('response', '최근 응답 · 화면'),
                         ('footer', '모델 · 컨텍스트 · 사용량')):
        if result[field]:
            ai.section(label, result[field], 12 if detailed else 4)
    if not any(result.values()):
        ai.section('Codex 기록', '현재 화면에서 읽을 대화가 없습니다. 터미널 탭에서 확인해 주세요.', 3)


def display(path, detailed=False):
    if not path or not Path(path).is_file():
        ai.section('Codex 기록', '이 프로세스의 세션 기록을 확인할 수 없습니다.', 3)
        return
    result = read(path)
    for field, label in (('request', '마지막 요청'), ('response', '최근 응답'), ('activity', '최근 도구 활동')):
        if result[field]:
            ai.section(label, result[field], 12 if detailed else (4 if field == 'response' else 3))
    if result['turn']:
        ai.section('턴 기록', result['turn'], 1)
    policy = ' · '.join(str(result[k]) for k in ('approval_policy', 'sandbox', 'effort') if result.get(k))
    if policy:
        ai.section('승인 · 샌드박스 · 추론', policy, 3)
    if detailed:
        for name in result['files']:
            ai.section('최근 변경 파일', str(name), 3)
        ai.section('세션 기록', str(path), 4)
    if not any(result[k] for k in ('request', 'response', 'activity')):
        ai.section('Codex 기록', '아직 표시할 요청·응답 기록이 없습니다.', 2)


if __name__ == '__main__':
    try:
        detailed = len(sys.argv) > 2 and sys.argv[2] == 'full'
        if len(sys.argv) > 1 and sys.argv[1] == '--screen':
            display_screen(sys.stdin.read(), detailed)
        else:
            display(sys.argv[1] if len(sys.argv) > 1 else '', detailed)
    except (OSError, ValueError):
        ai.section('Codex 기록', '세션 기록을 읽을 수 없습니다.', 2)
