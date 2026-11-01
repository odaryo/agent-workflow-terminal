#!/usr/bin/env python3
import argparse
from pathlib import Path
import re
import sys


class Undetermined(ValueError):
    pass


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise Undetermined(message)


def parse_patterns(value):
    sequence = re.fullmatch(r"\[(.*)\]\s*(?:#.*)?", value)
    if sequence is None:
        raise Undetermined("paths-ignore は1行の flow sequence が必要です")
    body = sequence.group(1).strip()
    patterns = []
    while body:
        item = re.match(r'''(?:"([A-Za-z0-9/._*\-]+)"|'([A-Za-z0-9/._*\-]+)')''', body)
        if item is None:
            raise Undetermined("paths-ignore の要素の形式またはパターン文字が未対応です")
        patterns.append(item.group(1) or item.group(2))
        body = body[item.end():].strip()
        if not body:
            break
        if not body.startswith(','):
            raise Undetermined("paths-ignore の要素区切りが不正です")
        body = body[1:].strip()
    return patterns


def workflow_patterns(source):
    lines = [line for line in source.splitlines() if line.strip() and not line.lstrip().startswith('#')]
    # YAML 全体を解釈しないため、引用したキーや重複した on を別ブロックとして見逃さない。
    on_lines = [i for i, line in enumerate(lines) if re.match(r'''(?:on|'on'|"on")\s*:''', line)]
    if len(on_lines) != 1 or not re.fullmatch(r'on:\s*(?:#.*)?', lines[on_lines[0]]):
        raise Undetermined("最上位の on ブロックが一意な対応形式ではありません")
    start = on_lines[0] + 1
    end = next((i for i in range(start, len(lines)) if not lines[i][0].isspace()), len(lines))
    events = {}
    event = None
    event_indent = None
    option_indent = None
    keys = set()
    for line in lines[start:end]:
        match = re.fullmatch(r'([ ]+)([A-Za-z0-9_-]+):\s*(.*)', line)
        if match is None:
            raise Undetermined("on ブロック内に未対応の構文があります")
        indent, key, value = len(match.group(1)), match.group(2), match.group(3)
        if event_indent is None:
            event_indent = indent
        if indent == event_indent:
            if key not in ('push', 'pull_request') or key in events:
                raise Undetermined("トリガーが push / pull_request の一組ではありません")
            if value and not value.startswith('#'):
                raise Undetermined("トリガーは block mapping が必要です")
            event = key
            events[event] = None
            option_indent = None
            keys = set()
        else:
            if event is None or indent < event_indent:
                raise Undetermined("on ブロックのインデントが不正です")
            if option_indent is None:
                option_indent = indent
            if indent != option_indent or key in keys:
                raise Undetermined("トリガー直下の構文またはキーの重複が未対応です")
            keys.add(key)
            if key == 'paths':
                raise Undetermined("paths を持つトリガーは判定できません")
            if key == 'paths-ignore':
                events[event] = parse_patterns(value)
            elif not value or value.startswith(('#', '|', '>', '&', '*', '!', '{')):
                raise Undetermined("トリガーのオプションに未対応の構文があります")
    if set(events) != {'push', 'pull_request'} or any(value is None for value in events.values()):
        raise Undetermined("push / pull_request の両方に paths-ignore が必要です")
    if events['push'] != events['pull_request']:
        raise Undetermined("push / pull_request の paths-ignore が一致しません")
    return events['push']


def pattern_regex(pattern):
    pieces = []
    index = 0
    while index < len(pattern):
        if pattern.startswith('**', index):
            pieces.append('.*')
            index += 2
        elif pattern[index] == '*':
            pieces.append("[^/]*")
            index += 1
        else:
            pieces.append(re.escape(pattern[index]))
            index += 1
    return re.compile(''.join(pieces))


def main():
    parser = ArgumentParser(description="CI の paths-ignore に全変更ファイルが一致するか判定する")
    parser.add_argument('--workflow', required=True)
    try:
        args = parser.parse_args()
        patterns = workflow_patterns(Path(args.workflow).read_text(encoding='utf-8'))
        paths = [line.rstrip('\n') for line in sys.stdin if line.rstrip('\n')]
        if not 1 <= len(paths) <= 300:
            raise Undetermined("変更ファイル数は1件以上300件以下が必要です")
        regexes = [pattern_regex(pattern) for pattern in patterns]
        return 0 if all(any(regex.fullmatch(path) for regex in regexes) for path in paths) else 1
    except (Undetermined, OSError, UnicodeError, re.error) as error:
        print('判定できません: ' + ' '.join(str(error).splitlines()), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
