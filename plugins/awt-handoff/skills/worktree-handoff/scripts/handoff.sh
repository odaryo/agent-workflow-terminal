#!/usr/bin/env bash
set -u

usage_error() {
  printf '%s\n' '使い方: handoff.sh --check | --directory <worktree> --prompt <700 バイトまでの1行の指示>' >&2
  exit 2
}

directory=""
prompt=""
check=0
if [[ $# -eq 1 && "$1" == --check ]]; then
  check=1
else
  directory_set=0
  prompt_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --directory)
        [[ $# -ge 2 && "$directory_set" -eq 0 ]] || usage_error
        directory="$2"
        directory_set=1
        shift 2
        ;;
      --prompt)
        [[ $# -ge 2 && "$prompt_set" -eq 0 ]] || usage_error
        prompt="$2"
        prompt_set=1
        shift 2
        ;;
      *) usage_error ;;
    esac
  done
  [[ -n "$directory" && -n "$prompt" ]] || usage_error
  [[ "$prompt" != *$'\n'* && "$prompt" != *$'\r'* ]] || usage_error
  [[ $(printf '%s' "$prompt" | wc -c) -le 700 ]] || usage_error
fi

resolve_environment() {
  local name="$1" fallback="$2" value
  if value=$(tmux show-environment -g "$name" 2>/dev/null) && [[ "$value" == "$name="* ]]; then
    printf '%s' "${value#*=}"
  else
    printf '%s' "$fallback"
  fi
}

hostctl=$(resolve_environment AWT_HOSTCTL "${AWT_HOSTCTL:-}")
socket=$(resolve_environment AWT_HOSTCTL_SOCKET "${AWT_HOSTCTL_SOCKET:-}")
if [[ -z "$hostctl" || ! -f "$hostctl" || ! -x "$hostctl" || -z "$socket" ]]; then
  printf '%s\n' '引き渡しの窓口が使えません。このセッションの中で続けてください。' >&2
  exit 69
fi
[[ "$check" -eq 0 ]] || exit 0

response=$("$hostctl" worktree open --directory "$directory" --socket "$socket")
rc=$?
if [[ "$rc" -ne 0 ]]; then
  printf '%s\n' "$response" >&2
  exit "$rc"
fi

parsed=$(printf '%s' "$response" | python3 -I -c '
import json
import sys

try:
    response = json.load(sys.stdin)
    session = response["session"]
    created = response["created"]
    if not isinstance(session, str) or not session or any(c in session for c in "\r\n\0"):
        raise ValueError("session が不正です")
    if not isinstance(created, bool):
        raise ValueError("created が不正です")
    if not created:
        print(f"既にセッションがあります: {session}", file=sys.stderr)
        sys.exit(3)
    command = response["agentCommand"]
    if command is None:
        command = "claude"
    if not isinstance(command, str):
        raise ValueError("agentCommand が不正です")
    quote = chr(39)
    escaped = sys.argv[1].replace(quote, quote + "\\" + quote + quote)
    line = command + " " + quote + escaped + quote
    if len(line.encode("utf-8")) > 900:
        print("送信するコマンドが 900 バイトを超えています。", file=sys.stderr)
        sys.exit(4)
    print(session)
    print(line)
except (ValueError, KeyError, TypeError) as error:
    print(f"hostctl の応答を読めません: {error}", file=sys.stderr)
    sys.exit(1)
' "$prompt")
rc=$?
[[ "$rc" -eq 0 ]] || exit "$rc"
session=${parsed%%$'\n'*}
line=${parsed#*$'\n'}

deadline=$((SECONDS + 15))
previous=""
observed=0
ready=0
while [[ "$SECONDS" -lt "$deadline" ]]; do
  sleep 0.2
  if cursor=$(tmux display-message -p -t "=$session:" '#{cursor_x}') &&
    screen=$(tmux capture-pane -p -t "=$session:") &&
    [[ "$cursor" =~ ^[0-9]+$ && "$cursor" -gt 0 ]]; then
    if [[ "$observed" -eq 1 && "$screen" == "$previous" ]]; then
      ready=1
      break
    fi
    previous="$screen"
    observed=1
  else
    observed=0
  fi
done
if [[ "$ready" -eq 0 ]]; then
  printf 'シェルのプロンプトを15秒以内に確認できませんでした: %s\n' "$session" >&2
  exit 5
fi

if ! tmux send-keys -t "=$session:" -l -- "$line" ||
  ! tmux send-keys -t "=$session:" Enter; then
  printf 'セッションへの送信に失敗しました: %s\n' "$session" >&2
  exit 6
fi
printf 'session=%s\n' "$session"
