#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

[[ $# -eq 0 ]] || die "引数は指定できません"
require_cmd tmux
require_cmd python3

HANDOFF="$SCRIPT_DIR/../plugins/awt-handoff/skills/worktree-handoff/scripts/handoff.sh"
STOP="$SCRIPT_DIR/stop-tty-processes.sh"
SOCK="awt-handoff-$$-$RANDOM"
work_dir=$(mktemp -d)
sessions=(anchor)
failures=0
checked=0
__awt_finished=0

T() { env -u TMUX tmux -L "$SOCK" "$@"; }

cleanup() {
  local name ttys tty
  local cleanup_rc=0
  for name in "${sessions[@]}"; do
    if ttys=$(T list-panes -t "=$name:" -F '#{pane_tty}' 2>/dev/null); then
      while IFS= read -r tty; do
        [[ -n "$tty" ]] || continue
        "$STOP" -L "$SOCK" "$tty" || cleanup_rc=1
      done <<<"$ttys"
      if T has-session -t "=$name" 2>/dev/null; then
        T kill-session -t "=$name" || cleanup_rc=1
      fi
    fi
  done
  rm -rf "$work_dir"
  return "$cleanup_rc"
}

# bash 3.2 は EXIT trap があると未定義変数で停止しても exit 0 になり得る（規約 §7）。
on_exit() {
  local rc=$?
  cleanup || rc=1
  [[ "$__awt_finished" -eq 1 || "$rc" -ne 0 ]] || rc=1
  exit "$rc"
}
trap on_exit EXIT

cat >"$work_dir/agent" <<'AGENT'
#!/usr/bin/env bash
set -eu
printf '%s\0' "$@" >"$AWT_TEST_ARGV"
AGENT

cat >"$work_dir/hostctl" <<'HOSTCTL'
#!/usr/bin/env bash
set -eu
printf 'called\n' >>"$AWT_TEST_DIR/calls"
[[ $# -eq 6 && "$1" == worktree && "$2" == open && "$3" == --directory &&
  "$4" == "$AWT_TEST_DIR" && "$5" == --socket && "$6" == test-socket ]] || exit 2
if [[ "$AWT_TEST_MODE" == unavailable ]]; then
  printf '%s\n' '{"ok":false,"version":1,"code":"unavailable","message":"app is not running"}'
  exit 69
fi
created=true
case "$AWT_TEST_MODE" in
  existing) created=false ;;
  no-prompt)
    tmux new-session -d -s "$AWT_TEST_SESSION" -x 120 -y 24 /bin/sleep 600
    ;;
  *)
    tmux new-session -d -s "$AWT_TEST_SESSION" -x 120 -y 24 \
      env PS1='handoff> ' AWT_TEST_ARGV="$AWT_TEST_DIR/argv" /bin/bash --norc --noprofile -i
    ;;
esac
python3 -I -c '
import json
import sys
print(json.dumps({"ok": True, "version": 1, "created": sys.argv[1] == "true",
                  "session": sys.argv[2], "agentCommand": sys.argv[3]}))
' "$created" "$AWT_TEST_SESSION" "$AWT_TEST_AGENT"
HOSTCTL
chmod +x "$work_dir/agent" "$work_dir/hostctl"

T -f /dev/null new-session -d -s anchor -x 120 -y 24 /bin/sleep 600
socket_path=$(T display-message -p '#{socket_path}')
[[ -n "$socket_path" ]] || die "隔離 server の socket path が読めません"
T set-environment -g AWT_HOSTCTL "$work_dir/hostctl"
T set-environment -g AWT_HOSTCTL_SOCKET test-socket

export AWT_TEST_DIR="$work_dir"
export AWT_TEST_MODE=success
export AWT_TEST_SESSION=success
export AWT_TEST_AGENT="$work_dir/agent"

H() {
  env TMUX="$socket_path,0,0" AWT_HOSTCTL= AWT_HOSTCTL_SOCKET= "$HANDOFF" "$@"
}

ng() {
  info "NG: $*"
  failures=$((failures + 1))
}

expect_exit() {
  local want="$1" label="$2" rc=0
  shift 2
  checked=$((checked + 1))
  H "$@" >"$work_dir/stdout" 2>"$work_dir/stderr" || rc=$?
  if [[ "$rc" -eq "$want" ]]; then
    info "OK (exit $rc): $label"
  else
    ng "$label: exit $rc (期待: $want)"
    cat "$work_dir/stdout" "$work_dir/stderr"
  fi
}

expect_no_call() {
  local label="$1"
  checked=$((checked + 1))
  if [[ -e "$work_dir/calls" ]]; then
    ng "$label: hostctl が呼ばれました"
  else
    info "OK: $label (hostctl は呼ばれない)"
  fi
}

expect_unsent() {
  local name="$1"
  checked=$((checked + 1))
  if [[ ! -e "$work_dir/argv" ]] &&
    [[ "$(T capture-pane -p -t "=$name:")" == "$before" ]]; then
    info "OK: $name には送信していない"
  else
    ng "$name に送信されています"
  fi
}

expect_exit 0 '--check が使える' --check
expect_no_call '--check'

sessions+=(success)
# shellcheck disable=SC2016 # 展開されずにそのまま Agent へ届くことを検査する
prompt='指示 '\''quoted'\'' $HOME `printf expanded` # end'
expect_exit 0 '特殊文字を含む指示を渡す' --directory "$work_dir" --prompt "$prompt"
for _ in $(seq 1 50); do
  [[ -f "$work_dir/argv" ]] && break
  sleep 0.1
done
checked=$((checked + 1))
if python3 -I -c '
import pathlib
import sys
assert pathlib.Path(sys.argv[1]).read_bytes() == sys.argv[2].encode("utf-8") + b"\0"
' "$work_dir/argv" "$prompt" &&
  [[ "$(cat "$work_dir/stdout")" == session=success ]]; then
  info 'OK: argv は1つで、特殊文字はそのまま届いた'
else
  ng 'argv または成功時の stdout が期待と異なります'
fi

rm -f "$work_dir/argv"
before=$(T capture-pane -p -t '=success:')
AWT_TEST_MODE=existing
expect_exit 3 '既存セッションには送らない' --directory "$work_dir" --prompt existing
checked=$((checked + 1))
if [[ ! -s "$work_dir/stdout" ]] && rg -q success "$work_dir/stderr"; then
  info 'OK: 既存セッション名を stderr に出した'
else
  ng '既存セッション名が stderr にありません'
fi
expect_unsent success

AWT_TEST_MODE=unavailable
expect_exit 69 'hostctl exit 69 を保つ' --directory "$work_dir" --prompt unavailable
checked=$((checked + 1))
if [[ ! -s "$work_dir/stdout" ]] && rg -q 'app is not running' "$work_dir/stderr"; then
  info 'OK: hostctl の失敗応答を stderr に出した'
else
  ng 'hostctl の失敗応答が stderr にありません'
fi

rm -f "$work_dir/calls"
expect_exit 2 '改行を拒否する' --directory "$work_dir" --prompt $'first\nsecond'
expect_no_call '改行'
expect_exit 2 'CR を拒否する' --directory "$work_dir" --prompt $'first\rsecond'
expect_no_call 'CR'
expect_exit 2 '空の指示を拒否する' --directory "$work_dir" --prompt ''
expect_no_call '空の指示'
long_prompt=$(python3 -I -c 'print("あ" * 234, end="")')
expect_exit 2 '700 バイト超を拒否する' --directory "$work_dir" --prompt "$long_prompt"
expect_no_call '700 バイト超'

T set-environment -gu AWT_HOSTCTL
expect_exit 69 'AWT_HOSTCTL が無い' --directory "$work_dir" --prompt missing
expect_exit 69 '--check が使えない' --check
expect_no_call '窓口が無い'
checked=$((checked + 1))
if env TMUX="$socket_path,0,0" AWT_HOSTCTL="$work_dir/hostctl" \
  AWT_HOSTCTL_SOCKET=test-socket "$HANDOFF" --check; then
  info 'OK: 同名の環境変数にフォールバックする'
else
  ng '同名の環境変数へのフォールバックが失敗しました'
fi
T set-environment -g AWT_HOSTCTL "$work_dir/hostctl"

AWT_TEST_MODE=success
AWT_TEST_SESSION=long-line
sessions+=(long-line)
AWT_TEST_AGENT="$work_dir/agent $(python3 -I -c 'print(" " * 901, end="")')"
expect_exit 4 'LINE が900 バイト超なら送らない' --directory "$work_dir" --prompt short
checked=$((checked + 1))
if [[ ! -e "$work_dir/argv" ]] &&
  [[ "$(T capture-pane -p -t '=long-line:')" != *short* ]]; then
  info 'OK: 長すぎる LINE は送っていない'
else
  ng '長すぎる LINE が送信されています'
fi

AWT_TEST_MODE=no-prompt
AWT_TEST_SESSION=no-prompt
AWT_TEST_AGENT="$work_dir/agent"
sessions+=(no-prompt)
expect_exit 5 'cursor が動かない pane はタイムアウトする' --directory "$work_dir" --prompt waiting
before=$(T capture-pane -p -t '=anchor:')
expect_unsent no-prompt

[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
__awt_finished=1
