#!/usr/bin/env bash
set -u

usage_error() {
  printf '%s\n' '使い方: handoff.sh --check | --directory <worktree> --prompt <700 バイトまでの1行の指示>' >&2
  exit 2
}

for dependency in python3 tmux; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf '引き渡しの窓口が使えません: %s がありません。\n' "$dependency" >&2
    exit 69
  fi
done

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
  [[ -n "$directory" && "$prompt_set" -eq 1 ]] || usage_error
  printf '%s' "$prompt" | python3 -I -c '
import sys

data = sys.stdin.buffer.read()
reason = None
if not data.strip():
    reason = "空です"
elif len(data) > 700:
    reason = "700 バイトを超えています"
else:
    try:
        data.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        reason = "不正な UTF-8 です"
    if reason is None:
        if any(byte < 0x20 or byte == 0x7f for byte in data):
            reason = "制御文字を含んでいます"
        elif b"\\" in data:
            reason = "backslash を含んでいます"
        elif data.startswith(b"-"):
            reason = "- で始まっています"
if reason is not None:
    print(f"指示が不正です: {reason}。", file=sys.stderr)
    sys.exit(2)
'
  rc=$?
  [[ "$rc" -eq 0 ]] || exit "$rc"
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
  [[ -z "$response" ]] || printf '%s\n' "$response" >&2
  [[ "$rc" -ne 2 ]] || rc=1
  exit "$rc"
fi

parsed=$(printf '%s' "$response" | python3 -I -c '
import json
import sys

session = None
try:
    response = json.load(sys.stdin)
    session = response["session"]
    if not isinstance(session, str) or not session or any(c in session for c in "\r\n\0"):
        session = None
        raise ValueError("session が不正です")
    created = response["created"]
    if not isinstance(created, bool):
        raise ValueError("created が不正です")
    if not created:
        print(f"session={session} 既にセッションがあります。", file=sys.stderr)
        sys.exit(3)
    command = response["agentCommand"]
    if command is None:
        command = "claude"
    if not isinstance(command, str):
        raise ValueError("agentCommand が不正です")
    if any(byte < 0x20 or byte == 0x7f for byte in command.encode("utf-8")):
        print(f"session={session} agentCommand が制御文字を含んでいます。", file=sys.stderr)
        sys.exit(4)
    if not command.strip():
        command = "claude"
    quote = chr(39)
    escaped = sys.argv[1].replace(quote, quote + "\\" + quote + quote)
    line = command + " " + quote + escaped + quote
    if len(line.encode("utf-8")) > 900:
        print(f"session={session} 送信するコマンドが 900 バイトを超えています。", file=sys.stderr)
        sys.exit(4)
    print(session)
    print(line)
except (ValueError, KeyError, TypeError) as error:
    context = f"session={session} " if session is not None else ""
    print(f"{context}hostctl の応答を読めません: {error}", file=sys.stderr)
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
  printf 'session=%s シェルのプロンプトを15秒以内に確認できませんでした。\n' "$session" >&2
  exit 5
fi

if ! pane_pid=$(tmux display-message -p -t "=$session:" '#{pane_pid}') ||
  [[ ! "$pane_pid" =~ ^[0-9]+$ ]]; then
  printf 'session=%s pane の PID を読めません。\n' "$session" >&2
  exit 6
fi

# 子プロセスの有無では、rc や常駐が残した子を Agent と取り違える。前景のプロセスグループの変化を見る。
if ! foreground_before=$(ps -o tpgid= -p "$pane_pid" | tr -d ' ') ||
  [[ ! "$foreground_before" =~ ^[0-9]+$ ]]; then
  printf 'session=%s pane の前景プロセスを読めません。\n' "$session" >&2
  exit 6
fi

if ! tmux send-keys -t "=$session:" -l -- "$line" ||
  ! tmux send-keys -t "=$session:" Enter; then
  printf 'session=%s セッションへの送信に失敗しました。\n' "$session" >&2
  exit 6
fi
# プロンプトが動かす外部コマンドも前景を一瞬変えるので、同じプロセスグループが3秒続いてはじめて起動とみなす。
# 10秒以内に現れて3秒続く Agent を見逃さないよう、13秒まで見る。
foreground_candidate=""
foreground_samples=0
for ((attempt = 0; attempt < 65; attempt++)); do
  sleep 0.2
  foreground_now=$(ps -o tpgid= -p "$pane_pid" | tr -d ' ')
  if [[ ! "$foreground_now" =~ ^[0-9]+$ || "$foreground_now" == "$foreground_before" ]]; then
    foreground_candidate=""
    foreground_samples=0
    continue
  fi
  if [[ "$foreground_now" != "$foreground_candidate" ]]; then
    foreground_candidate="$foreground_now"
    foreground_samples=0
  fi
  foreground_samples=$((foreground_samples + 1))
  if [[ "$foreground_samples" -ge 15 ]]; then
    printf 'session=%s\n' "$session"
    exit 0
  fi
done
printf 'session=%s Agent の起動を確認できません。\n' "$session" >&2
exit 7
