#!/usr/bin/env bash
set -u

usage_error() {
  printf '%s\n' '使い方: handoff.sh --check | --directory <worktree> --prompt <700 バイトまでの1行の指示> [--purpose <1024 バイトまでの1行の目的>]' >&2
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
purpose=""
purpose_set=0
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
      --purpose)
        [[ $# -ge 2 && "$purpose_set" -eq 0 ]] || usage_error
        purpose="$2"
        purpose_set=1
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
  if [[ "$purpose_set" -eq 1 ]]; then
    # 上限・Cc/Zl/Zp・末尾の ; はアプリがセッションを作る前に行う検査 (§12.7、§21.4) に揃える。ここで弾かないと、
    # アプリが invalid_request を返し、exit 2 ではなく exit 1 で引き渡しが止まる。
    printf '%s' "$purpose" | python3 -I -c '
import sys
import unicodedata

data = sys.stdin.buffer.read()
reason = None
if not data.strip():
    reason = "空です"
elif len(data) > 1024:
    reason = "1024 バイトを超えています"
else:
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        reason = "不正な UTF-8 です"
    if reason is None:
        if any(byte < 0x20 or byte == 0x7f for byte in data):
            reason = "制御文字を含んでいます"
        elif any(unicodedata.category(c) in ("Cc", "Zl", "Zp") for c in text):
            reason = "1行に収まらない文字を含んでいます"
        elif b"\\" in data:
            reason = "backslash を含んでいます"
        elif data.startswith(b"-"):
            reason = "- で始まっています"
        elif data.endswith(b";"):
            reason = "; で終わっています"
if reason is not None:
    print(f"目的が不正です: {reason}。", file=sys.stderr)
    sys.exit(2)
'
    rc=$?
    [[ "$rc" -eq 0 ]] || exit "$rc"
  fi
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

from_pane=""
[[ ! "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]] || from_pane="$TMUX_PANE"
# --purpose を知る hostctl は --from-pane も知るので、外すのは --purpose が先。
stages=()
[[ -z "$from_pane" || "$purpose_set" -eq 0 ]] || stages+=(from-pane+purpose)
if [[ -n "$from_pane" ]]; then
  stages+=(from-pane)
elif [[ "$purpose_set" -eq 1 ]]; then
  stages+=(purpose)
fi
stages+=(plain)
errors=""
if [[ "${#stages[@]}" -gt 1 ]]; then
  # 一時ファイルを作れなければ stderr を取らずに呼ぶ。古い hostctl の拒否が見えるだけで、目的は落とさない。
  errors=$(mktemp "${TMPDIR:-/tmp}/awt-handoff.XXXXXX" 2>/dev/null) || errors=""
fi
for ((stage = 0; stage < ${#stages[@]}; stage++)); do
  arguments=(worktree open --directory "$directory" --socket "$socket")
  case "${stages[stage]}" in
    from-pane*) arguments+=(--from-pane "$from_pane") ;;
  esac
  case "${stages[stage]}" in
    *purpose) arguments+=(--purpose "$purpose") ;;
  esac
  last=0
  [[ $((stage + 1)) -lt "${#stages[@]}" ]] || last=1
  if [[ "$last" -eq 0 && -n "$errors" ]]; then
    response=$("$hostctl" "${arguments[@]}" 2>"$errors")
    rc=$?
  else
    response=$("$hostctl" "${arguments[@]}")
    rc=$?
  fi
  # 知らない引数を受けた古い hostctl は、要求を送る前に exit 2 で拒否する。exit 2 なら呼び直しても二重には開かない。
  [[ "$last" -eq 0 && "$rc" -eq 2 ]] || break
done
if [[ -n "$errors" ]]; then
  [[ "$last" -eq 1 || "$rc" -eq 2 ]] || cat "$errors" >&2
  rm -f "$errors"
fi
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
  [[ ! "$foreground_before" =~ ^[0-9]+$ ]] ||
  ! command_before=$(ps -o comm= -p "$pane_pid") || [[ -z "$command_before" ]]; then
  printf 'session=%s pane の前景プロセスを読めません。\n' "$session" >&2
  exit 6
fi

if ! tmux send-keys -t "=$session:" -l -- "$line" ||
  ! tmux send-keys -t "=$session:" Enter; then
  printf 'session=%s セッションへの送信に失敗しました。\n' "$session" >&2
  exit 6
fi
# プロンプトの外部コマンドを取り違えないよう、前景の変化が3秒続いてはじめて起動とみなす。
# exec はプロセスグループを変えないので、pane PID の comm の変化も同じ期間確かめる。
# 10秒以内に現れて3秒続く Agent を見逃さないよう、13秒まで見る。
foreground_candidate=""
foreground_samples=0
command_candidate=""
command_samples=0
for ((attempt = 0; attempt < 65; attempt++)); do
  sleep 0.2
  foreground_now=$(ps -o tpgid= -p "$pane_pid" | tr -d ' ')
  if [[ ! "$foreground_now" =~ ^[0-9]+$ || "$foreground_now" == "$foreground_before" ]]; then
    foreground_candidate=""
    foreground_samples=0
  else
    if [[ "$foreground_now" != "$foreground_candidate" ]]; then
      foreground_candidate="$foreground_now"
      foreground_samples=0
    fi
    foreground_samples=$((foreground_samples + 1))
  fi
  command_now=$(ps -o comm= -p "$pane_pid")
  if [[ -z "$command_now" || "$command_now" == "$command_before" ]]; then
    command_candidate=""
    command_samples=0
  else
    if [[ "$command_now" != "$command_candidate" ]]; then
      command_candidate="$command_now"
      command_samples=0
    fi
    command_samples=$((command_samples + 1))
  fi
  if [[ "$foreground_samples" -ge 15 || "$command_samples" -ge 15 ]]; then
    printf 'session=%s\n' "$session"
    exit 0
  fi
done
printf 'session=%s Agent の起動を確認できません。\n' "$session" >&2
exit 7
