#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

[[ $# -eq 0 ]] || die "引数は指定できません"
require_cmd tmux
require_cmd python3
require_cmd rg

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
  if ! T list-sessions >/dev/null 2>&1; then
    rm -f "${TMUX_TMPDIR:-/private/tmp}/tmux-$(id -u)/$SOCK"
  fi
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
sleep 30
AGENT

cat >"$work_dir/hostctl" <<'HOSTCTL'
#!/usr/bin/env bash
set -eu
printf 'called\n' >>"$AWT_TEST_DIR/calls"
[[ $# -eq 6 && "$1" == worktree && "$2" == open && "$3" == --directory &&
  "$4" == "$AWT_TEST_DIR" && "$5" == --socket && "$6" == test-socket ]] || exit 2
if [[ "$AWT_TEST_MODE" == unavailable ]]; then
  printf '%s\n' '{"ok":false,"version":1,"code":"unavailable","message":"app is not running"}' >&2
  exit 69
fi
if [[ "$AWT_TEST_MODE" == argument-error ]]; then
  printf '%s\n' 'invalid arguments' >&2
  exit 2
fi
created=true
case "$AWT_TEST_MODE" in
  existing) created=false ;;
  no-prompt)
    tmux new-session -d -s "$AWT_TEST_SESSION" -x 120 -y 24 /bin/sleep 600
    ;;
  prompt-command)
    tmux new-session -d -s "$AWT_TEST_SESSION" -x 120 -y 24 \
      env PS1='handoff> ' PROMPT_COMMAND='/bin/sleep 1' AWT_TEST_ARGV="$AWT_TEST_DIR/argv" /bin/bash --norc --noprofile -i
    ;;
  zsh | fish)
    tmux new-session -d -s "$AWT_TEST_SESSION" -x 120 -y 24 \
      env AWT_TEST_ARGV="$AWT_TEST_DIR/argv" "$AWT_TEST_SHELL" "$([[ "$AWT_TEST_MODE" == fish ]] && printf -- -N || printf -- -f)" -i
    ;;
  *)
    tmux new-session -d -s "$AWT_TEST_SESSION" -x 120 -y 24 \
      env PATH="${AWT_TEST_PANE_PATH:-$PATH}" PS1='handoff> ' AWT_TEST_ARGV="$AWT_TEST_DIR/argv" /bin/bash --norc --noprofile -i
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
  env TMUX="$socket_path,0,0" AWT_HOSTCTL=/missing/hostctl AWT_HOSTCTL_SOCKET=wrong-socket "$HANDOFF" "$@"
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
  if [[ "$want" == 3 || "$want" == 4 || "$want" == 5 || "$want" == 6 || "$want" == 7 ]]; then
    checked=$((checked + 1))
    if ! rg -q -F "session=$AWT_TEST_SESSION" "$work_dir/stderr"; then
      ng "$label: stderr に session= がありません"
    fi
  fi
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

wait_for_argv() {
  local attempt
  for ((attempt = 0; attempt < 50; attempt++)); do
    [[ -s "$work_dir/argv" ]] && return 0
    sleep 0.1
  done
  return 1
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

expect_exit 0 '環境変数と異なる tmux global の窓口で --check が使える' --check
expect_no_call '--check'

sessions+=(success)
# shellcheck disable=SC2016 # 展開されずにそのまま Agent へ届くことを検査する
prompt="指示 'quoted'"' $HOME `printf expanded` # end'
expect_exit 0 '特殊文字を含む指示を渡す' --directory "$work_dir" --prompt "$prompt"
wait_for_argv || true
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
if [[ ! -s "$work_dir/stdout" ]] && rg -q session=success "$work_dir/stderr"; then
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

AWT_TEST_MODE=argument-error
expect_exit 1 'hostctl exit 2 を exit 1 にする' --directory "$work_dir" --prompt arguments
checked=$((checked + 1))
if [[ ! -s "$work_dir/stdout" && "$(cat "$work_dir/stderr")" == 'invalid arguments' ]]; then
  info 'OK: 空の stdout に空行を足さない'
else
  ng 'hostctl の失敗時の出力が期待と異なります'
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

for invalid_prompt in $'foo\\' 'a\\b' $'a\tb' $'a\x03b' $'a\x15b' $'a\x7fb' $'a\xffb' '-option'; do
  expect_exit 2 '危険な指示を拒否する' --directory "$work_dir" --prompt "$invalid_prompt"
  expect_no_call '危険な指示'
done

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

rm -f "$work_dir/argv"
AWT_TEST_SESSION=control-command
AWT_TEST_AGENT=$'echo\nunsafe'
sessions+=(control-command)
expect_exit 4 'agentCommand の制御文字を拒否する' --directory "$work_dir" --prompt short
checked=$((checked + 1))
if [[ ! -e "$work_dir/argv" ]] &&
  [[ "$(T capture-pane -p -t '=control-command:')" != *short* ]]; then
  info 'OK: 制御文字を含む agentCommand は送っていない'
else
  ng '制御文字を含む agentCommand が送信されています'
fi

mkdir "$work_dir/bin"
cp "$work_dir/agent" "$work_dir/bin/claude"
# pane の PATH は tmux の global environment ではなく起動元の PATH から決まるので、pane へ明示的に渡す。
# 渡せないと本物の claude が起動する。
export AWT_TEST_PANE_PATH="$work_dir/bin:$PATH"
for command_kind in empty whitespace; do
  AWT_TEST_SESSION="default-$command_kind"
  AWT_TEST_AGENT=''
  [[ "$command_kind" != whitespace ]] || AWT_TEST_AGENT='   '
  sessions+=("$AWT_TEST_SESSION")
  expect_exit 0 '空の agentCommand は claude を使う' --directory "$work_dir" --prompt default-agent
  checked=$((checked + 1))
  if wait_for_argv && python3 -I -c '
import pathlib
import sys
assert pathlib.Path(sys.argv[1]).read_bytes() == b"default-agent\0"
' "$work_dir/argv"; then
    info 'OK: 偽の claude へ指示が届いた'
  else
    ng '偽の claude へ指示が届いていません'
  fi
  rm -f "$work_dir/argv"
done
unset AWT_TEST_PANE_PATH

AWT_TEST_SESSION='prompt-command'
AWT_TEST_MODE='prompt-command'
AWT_TEST_AGENT="$work_dir/no-such-agent"
sessions+=("$AWT_TEST_SESSION")
expect_exit 7 'プロンプトの外部コマンドを Agent の起動と取り違えない' --directory "$work_dir" --prompt no-agent
AWT_TEST_MODE=success

AWT_TEST_SESSION=no-agent
AWT_TEST_AGENT=true
sessions+=(no-agent)
expect_exit 7 '即座に終わるコマンドは Agent 起動を確認できない' --directory "$work_dir" --prompt short

for shell_name in zsh fish; do
  if ! command -v "$shell_name" >/dev/null 2>&1; then
    info "SKIP: $shell_name がありません"
    continue
  fi
  export AWT_TEST_SHELL
  AWT_TEST_SHELL=$(command -v "$shell_name")
  AWT_TEST_MODE="$shell_name"
  AWT_TEST_SESSION="$shell_name"
  AWT_TEST_AGENT="$work_dir/agent"
  sessions+=("$shell_name")
  expect_exit 0 "$shell_name の pane へ送信する" --directory "$work_dir" --prompt "$prompt"
  checked=$((checked + 1))
  if wait_for_argv && python3 -I -c '
import pathlib
import sys
assert pathlib.Path(sys.argv[1]).read_bytes() == sys.argv[2].encode("utf-8") + b"\0"
' "$work_dir/argv" "$prompt"; then
    info "OK: $shell_name でも argv がそのまま届いた"
  else
    ng "$shell_name の argv が期待と異なります"
  fi
  rm -f "$work_dir/argv"
done

AWT_TEST_MODE=no-prompt
AWT_TEST_SESSION=no-prompt
AWT_TEST_AGENT="$work_dir/agent"
sessions+=(no-prompt)
expect_exit 5 'cursor が動かない pane はタイムアウトする' --directory "$work_dir" --prompt waiting
before=$(T capture-pane -p -t '=no-prompt:')
expect_unsent no-prompt

[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
__awt_finished=1
