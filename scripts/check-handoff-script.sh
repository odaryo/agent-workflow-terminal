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
failures=0
checked=0
# 同時に走らせる群の数。CI の runner は 3 コアで、成功系は「前景の変化が 3 秒続く」ことを数えるので、
# 負荷で判定が揺れたらここを下げる (Issue #852)。
max_jobs=8
group_names=()
group_pids=()
__awt_finished=0

T() { env -u TMUX tmux -L "$SOCK" "$@"; }

wait_running_groups() {
  local i
  for ((i = 0; i < ${#group_pids[@]}; i++)); do
    if kill -0 "${group_pids[i]}" 2>/dev/null; then
      wait "${group_pids[i]}" 2>/dev/null || true
    fi
  done
}

# 一覧を取ってから stop-tty-processes.sh が tty を確かめるまでに pane が閉じると (exec-agent の agent は
# 30 秒で終わり、exec なので pane ごと閉じる)、何も止めずに exit 2 で終わる。そのときだけ取り直す。
stop_all_ttys() {
  local attempt listed tty stop_rc
  local ttys=()
  for ((attempt = 0; attempt < 4; attempt++)); do
    [[ "$attempt" -eq 0 ]] || sleep 0.5
    listed=$(T list-panes -a -F '#{pane_tty}' 2>/dev/null) || return 0
    ttys=()
    while IFS= read -r tty; do
      [[ -z "$tty" ]] || ttys+=("$tty")
    done <<<"$listed"
    [[ "${#ttys[@]}" -gt 0 ]] || return 0
    stop_rc=0
    "$STOP" -L "$SOCK" "${ttys[@]}" || stop_rc=$?
    [[ "$stop_rc" -eq 2 ]] || return "$stop_rc"
  done
  return 1
}

cleanup() {
  local names name
  local cleanup_rc=0
  stop_all_ttys || cleanup_rc=1
  # 止めた pane が閉じて server ごと終わっていることがある。消せなかったうえに残っている session だけを失敗にする。
  if names=$(T list-sessions -F '#{session_name}' 2>/dev/null); then
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      if ! T kill-session -t "=$name" 2>/dev/null && T has-session -t "=$name" 2>/dev/null; then
        info "session $name を消せません"
        cleanup_rc=1
      fi
    done <<<"$names"
  fi
  if ! T list-sessions >/dev/null 2>&1; then
    rm -f "${TMUX_TMPDIR:-/private/tmp}/tmux-$(id -u)/$SOCK"
  fi
  rm -rf "$work_dir"
  return "$cleanup_rc"
}

# bash 3.2 は EXIT trap があると未定義変数で停止しても exit 0 になり得る（規約 §7）。
# die で途中から抜けたときに、動いている群と rm -rf を競合させないよう、群を待ってから後始末する。
on_exit() {
  local rc=$?
  wait_running_groups
  cleanup || rc=1
  [[ "$__awt_finished" -eq 1 || "$rc" -ne 0 ]] || rc=1
  exit "$rc"
}
trap on_exit EXIT

cat >"$work_dir/agent" <<'AGENT'
#!/usr/bin/env bash
set -eu
exec python3 -I -c '
import os
import pathlib
import sys
import time
pathlib.Path(os.environ["AWT_TEST_ARGV"]).write_bytes(
    b"".join(arg.encode("utf-8") + b"\0" for arg in sys.argv[1:]))
time.sleep(30)
' "$@"
AGENT

cat >"$work_dir/changing-screen.py" <<'SCREEN'
import pathlib
import sys
import time

stop = pathlib.Path(sys.argv[1])
counter = 0
while not stop.exists():
    print(f"\rchanging {counter:012d}> ", end="", flush=True)
    if counter == 0:
        stop.with_suffix(".ready").touch()
    counter += 1
    time.sleep(0.05)
stop.with_suffix(".done").touch()
SCREEN

cat >"$work_dir/changing-screen.rc" <<'RC'
PS1='handoff> '
python3 -I "$AWT_TEST_DIR/changing-screen.py" "$AWT_TEST_DIR/screen-stop" &
RC

cat >"$work_dir/hostctl" <<'HOSTCTL'
#!/usr/bin/env bash
set -eu
printf 'called\n' >>"$AWT_TEST_DIR/calls"
from_pane=""
from_pane_set=0
if [[ $# -eq 8 && "$7" == --from-pane ]]; then
  from_pane="$8"
  from_pane_set=1
  set -- "$1" "$2" "$3" "$4" "$5" "$6"
fi
printf '%s\n' "$from_pane" >>"$AWT_TEST_DIR/from-pane"
[[ $# -eq 6 && "$1" == worktree && "$2" == open && "$3" == --directory &&
  "$4" == "$AWT_TEST_DIR" && "$5" == --socket && "$6" == test-socket ]] || exit 2
if [[ "$from_pane_set" -eq 1 && "${AWT_TEST_OLD_HOSTCTL:-0}" == 1 ]]; then
  printf '%s\n' '不正な引数です: --from-pane' >&2
  exit 2
fi
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
  missing-session) ;;
  changing-screen)
    tmux new-session -d -s "$AWT_TEST_SESSION" -x 120 -y 24 \
      env AWT_TEST_DIR="$AWT_TEST_DIR" AWT_TEST_ARGV="$AWT_TEST_DIR/argv" \
      /bin/bash --noprofile --rcfile "$AWT_TEST_DIR/changing-screen.rc" -i
    for ((attempt = 0; attempt < 50; attempt++)); do
      [[ ! -e "$AWT_TEST_DIR/screen-stop.ready" ]] || break
      sleep 0.1
    done
    [[ -e "$AWT_TEST_DIR/screen-stop.ready" ]] || exit 1
    ;;
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
mkdir "$work_dir/bin" "$work_dir/cases"
cp "$work_dir/agent" "$work_dir/bin/claude"

T -f /dev/null new-session -d -s anchor -x 120 -y 24 /bin/sleep 600
socket_path=$(T display-message -p '#{socket_path}')
[[ -n "$socket_path" ]] || die "隔離 server の socket path が読めません"
T set-environment -g AWT_HOSTCTL "$work_dir/hostctl"
T set-environment -g AWT_HOSTCTL_SOCKET test-socket

# 偽 hostctl は --directory が AWT_TEST_DIR と一致することを確かめ、呼び出しの記録も argv もそこへ書く。
# 並列の群が互いの記録を読まないよう、群ごとに $work_dir/cases/<群名> を持たせる。
export AWT_TEST_DIR="$work_dir/cases/serial"
export AWT_TEST_MODE=success
export AWT_TEST_SESSION=success
export AWT_TEST_AGENT="$work_dir/agent"
export AWT_TEST_OLD_HOSTCTL=0
mkdir "$AWT_TEST_DIR"

# この検査自体が tmux pane の中で動くことがあるので、継承した TMUX_PANE を渡さない。
# bash 3.2 は set -u の下で空の配列の展開を未定義の参照として止まるので、要素を必ず1つ以上にする。
pane_env=(-u TMUX_PANE)

H() {
  env "${pane_env[@]}" TMUX="$socket_path,0,0" AWT_HOSTCTL=/missing/hostctl AWT_HOSTCTL_SOCKET=wrong-socket "$HANDOFF" "$@"
}

ng() {
  info "NG: $*"
  failures=$((failures + 1))
}

expect_exit() {
  local want="$1" label="$2" rc=0
  shift 2
  checked=$((checked + 1))
  H "$@" >"$AWT_TEST_DIR/stdout" 2>"$AWT_TEST_DIR/stderr" || rc=$?
  if [[ "$want" == 3 || "$want" == 4 || "$want" == 5 || "$want" == 6 || "$want" == 7 ]]; then
    checked=$((checked + 1))
    if ! rg -q -F "session=$AWT_TEST_SESSION" "$AWT_TEST_DIR/stderr"; then
      ng "$label: stderr に session= がありません"
    fi
  fi
  if [[ "$rc" -eq "$want" ]]; then
    info "OK (exit $rc): $label"
  else
    ng "$label: exit $rc (期待: $want)"
    cat "$AWT_TEST_DIR/stdout" "$AWT_TEST_DIR/stderr"
  fi
}

expect_no_call() {
  local label="$1"
  checked=$((checked + 1))
  if [[ -e "$AWT_TEST_DIR/calls" ]]; then
    ng "$label: hostctl が呼ばれました"
  else
    info "OK: $label (hostctl は呼ばれない)"
  fi
}

wait_for_argv() {
  local attempt
  for ((attempt = 0; attempt < 50; attempt++)); do
    [[ -s "$AWT_TEST_DIR/argv" ]] && return 0
    sleep 0.1
  done
  return 1
}

expect_unsent() {
  local name="$1" before="$2"
  checked=$((checked + 1))
  if [[ ! -e "$AWT_TEST_DIR/argv" ]] &&
    [[ "$(T capture-pane -p -t "=$name:")" == "$before" ]]; then
    info "OK: $name には送信していない"
  else
    ng "$name に送信されています"
  fi
}

expect_argv_prompt() {
  local want="$1"
  python3 -I -c '
import pathlib
import sys
assert pathlib.Path(sys.argv[1]).read_bytes() == sys.argv[2].encode("utf-8") + b"\0"
' "$AWT_TEST_DIR/argv" "$want"
}

# 引数は呼び出しごとに偽 hostctl が受け取る --from-pane の値 (無ければ空)。末尾の改行まで比べる。
expect_hostctl_calls() {
  local label="$1" pane
  shift
  : >"$AWT_TEST_DIR/want-calls"
  : >"$AWT_TEST_DIR/want-from-pane"
  for pane in "$@"; do
    printf 'called\n' >>"$AWT_TEST_DIR/want-calls"
    printf '%s\n' "$pane" >>"$AWT_TEST_DIR/want-from-pane"
  done
  checked=$((checked + 1))
  if cmp -s "$AWT_TEST_DIR/want-calls" "$AWT_TEST_DIR/calls" &&
    cmp -s "$AWT_TEST_DIR/want-from-pane" "$AWT_TEST_DIR/from-pane"; then
    info "OK: $label (hostctl を $# 回呼んだ)"
  else
    ng "$label: hostctl の呼び出しが期待と異なります"
    cat "$AWT_TEST_DIR/calls" "$AWT_TEST_DIR/from-pane" 2>/dev/null || true
  fi
}

reset_hostctl_calls() {
  rm -f "$AWT_TEST_DIR/calls" "$AWT_TEST_DIR/from-pane" "$AWT_TEST_DIR/argv"
}

expect_agent_prompt() {
  local label="$1" want="$2"
  checked=$((checked + 1))
  if wait_for_argv && expect_argv_prompt "$want"; then
    info "OK: $label (Agent に指示が届いた)"
  else
    ng "$label: Agent に指示が届いていません"
  fi
}

expect_no_old_hostctl_error() {
  local label="$1"
  checked=$((checked + 1))
  if rg -q -F '不正な引数です' "$AWT_TEST_DIR/stderr"; then
    ng "$label: 古い hostctl の拒否が stderr に出ています"
  else
    info "OK: $label (古い hostctl の拒否を出さない)"
  fi
}

# shellcheck disable=SC2016 # 展開されずにそのまま Agent へ届くことを検査する
prompt="指示 'quoted'"' $HOME `printf expanded` # end'

group_success() {
  local before
  AWT_TEST_SESSION=success
  expect_exit 0 '特殊文字を含む指示を渡す' --directory "$AWT_TEST_DIR" --prompt "$prompt"
  wait_for_argv || true
  checked=$((checked + 1))
  if expect_argv_prompt "$prompt" &&
    [[ "$(cat "$AWT_TEST_DIR/stdout")" == session=success ]]; then
    info 'OK: argv は1つで、特殊文字はそのまま届いた'
  else
    ng 'argv または成功時の stdout が期待と異なります'
  fi

  rm -f "$AWT_TEST_DIR/argv"
  before=$(T capture-pane -p -t '=success:')
  AWT_TEST_MODE=existing
  expect_exit 3 '既存セッションには送らない' --directory "$AWT_TEST_DIR" --prompt existing
  checked=$((checked + 1))
  if [[ ! -s "$AWT_TEST_DIR/stdout" ]] && rg -q session=success "$AWT_TEST_DIR/stderr"; then
    info 'OK: 既存セッション名を stderr に出した'
  else
    ng '既存セッション名が stderr にありません'
  fi
  expect_unsent success "$before"

  AWT_TEST_MODE=unavailable
  expect_exit 69 'hostctl exit 69 を保つ' --directory "$AWT_TEST_DIR" --prompt unavailable
  checked=$((checked + 1))
  if [[ ! -s "$AWT_TEST_DIR/stdout" ]] && rg -q 'app is not running' "$AWT_TEST_DIR/stderr"; then
    info 'OK: hostctl の失敗応答を stderr に出した'
  else
    ng 'hostctl の失敗応答が stderr にありません'
  fi

  AWT_TEST_MODE=argument-error
  expect_exit 1 'hostctl exit 2 を exit 1 にする' --directory "$AWT_TEST_DIR" --prompt arguments
  checked=$((checked + 1))
  if [[ ! -s "$AWT_TEST_DIR/stdout" && "$(cat "$AWT_TEST_DIR/stderr")" == 'invalid arguments' ]]; then
    info 'OK: 空の stdout に空行を足さない'
  else
    ng 'hostctl の失敗時の出力が期待と異なります'
  fi
}

group_exec_agent() {
  AWT_TEST_SESSION=exec-agent
  AWT_TEST_AGENT="exec $work_dir/agent"
  expect_exit 0 'exec で pane の shell を置き換えて起動する' --directory "$AWT_TEST_DIR" --prompt "$prompt"
  checked=$((checked + 1))
  if wait_for_argv && expect_argv_prompt "$prompt"; then
    info 'OK: exec でも argv がそのまま届いた'
  else
    ng 'exec の argv が期待と異なります'
  fi
}

# 引数は TMUX_PANE の値。'-' なら TMUX_PANE を外す。
group_from_pane() {
  local pane="$1" label="$2"
  shift 2
  AWT_TEST_SESSION=$(basename -- "$AWT_TEST_DIR")
  if [[ "$pane" == - ]]; then
    pane_env=(-u TMUX_PANE)
  else
    pane_env=("TMUX_PANE=$pane")
  fi
  expect_exit 0 "$label" --directory "$AWT_TEST_DIR" --prompt from-pane
  expect_hostctl_calls "$label" "$@"
  expect_agent_prompt "$label" from-pane
}

group_from_pane_old() {
  AWT_TEST_OLD_HOSTCTL=1
  pane_env=(TMUX_PANE=%22)
  AWT_TEST_SESSION=from-pane-old
  expect_exit 0 '古い hostctl には --from-pane を外して呼び直す' --directory "$AWT_TEST_DIR" --prompt from-pane
  expect_hostctl_calls '古い hostctl には --from-pane を外して呼び直す' %22 ''
  expect_agent_prompt '古い hostctl には --from-pane を外して呼び直す' from-pane
  expect_no_old_hostctl_error '古い hostctl には --from-pane を外して呼び直す'

  reset_hostctl_calls
  AWT_TEST_MODE=existing
  expect_exit 3 '古い hostctl の呼び直しでも既存セッションには送らない' --directory "$AWT_TEST_DIR" --prompt from-pane-existing
  expect_hostctl_calls '古い hostctl の呼び直しでも既存セッションには送らない' %22 ''
  expect_no_old_hostctl_error '古い hostctl の呼び直しでも既存セッションには送らない'
  AWT_TEST_OLD_HOSTCTL=0

  reset_hostctl_calls
  AWT_TEST_MODE=unavailable
  expect_exit 69 '--from-pane 付きの呼び出しの exit 69 を保つ' --directory "$AWT_TEST_DIR" --prompt from-pane-unavailable
  expect_hostctl_calls '--from-pane 付きの呼び出しの exit 69 を保つ' %22
  checked=$((checked + 1))
  if [[ ! -s "$AWT_TEST_DIR/stdout" ]] && rg -q 'app is not running' "$AWT_TEST_DIR/stderr"; then
    info 'OK: --from-pane 付きの呼び出しの失敗応答を stderr に出した'
  else
    ng '--from-pane 付きの呼び出しの失敗応答が stderr にありません'
  fi

  reset_hostctl_calls
  AWT_TEST_MODE=argument-error
  pane_env=(-u TMUX_PANE)
  expect_exit 1 '--from-pane 無しの exit 2 は呼び直さない' --directory "$AWT_TEST_DIR" --prompt arguments
  expect_hostctl_calls '--from-pane 無しの exit 2 は呼び直さない' ''

  reset_hostctl_calls
  pane_env=(TMUX_PANE=%22)
  expect_exit 1 '呼び直しの exit 2 も exit 1 にする' --directory "$AWT_TEST_DIR" --prompt arguments
  expect_hostctl_calls '呼び直しの exit 2 も exit 1 にする' %22 ''
  checked=$((checked + 1))
  if [[ ! -s "$AWT_TEST_DIR/stdout" && "$(cat "$AWT_TEST_DIR/stderr")" == 'invalid arguments' ]]; then
    info 'OK: 呼び直しの出力だけを stderr に出した'
  else
    ng '呼び直しの失敗時の出力が期待と異なります'
  fi
}

group_default_agent() {
  local agent="$1"
  AWT_TEST_SESSION=$(basename -- "$AWT_TEST_DIR")
  AWT_TEST_AGENT="$agent"
  # pane の PATH は tmux の global environment ではなく起動元の PATH から決まるので、pane へ明示的に渡す。
  # 渡せないと本物の claude が起動する。
  export AWT_TEST_PANE_PATH="$work_dir/bin:$PATH"
  expect_exit 0 '空の agentCommand は claude を使う' --directory "$AWT_TEST_DIR" --prompt default-agent
  checked=$((checked + 1))
  if wait_for_argv && python3 -I -c '
import pathlib
import sys
assert pathlib.Path(sys.argv[1]).read_bytes() == b"default-agent\0"
' "$AWT_TEST_DIR/argv"; then
    info 'OK: 偽の claude へ指示が届いた'
  else
    ng '偽の claude へ指示が届いていません'
  fi
}

group_prompt_command() {
  AWT_TEST_SESSION='prompt-command'
  AWT_TEST_MODE='prompt-command'
  AWT_TEST_AGENT="$work_dir/no-such-agent"
  expect_exit 7 'プロンプトの外部コマンドを Agent の起動と取り違えない' --directory "$AWT_TEST_DIR" --prompt no-agent
}

group_no_agent() {
  AWT_TEST_SESSION=no-agent
  AWT_TEST_AGENT=true
  expect_exit 7 '即座に終わるコマンドは Agent 起動を確認できない' --directory "$AWT_TEST_DIR" --prompt short
}

group_short_lived_exec() {
  AWT_TEST_SESSION=short-lived-exec
  AWT_TEST_AGENT="exec /bin/sh -c 'sleep 1; exit 1'"
  expect_exit 7 '短命の exec を Agent の起動と取り違えない' --directory "$AWT_TEST_DIR" --prompt short
  checked=$((checked + 1))
  if T has-session -t '=short-lived-exec' 2>/dev/null; then
    ng '短命の exec の session が残っています'
  else
    info 'OK: 短命の exec の session は消えた'
  fi
}

group_literal_command() {
  AWT_TEST_SESSION=literal-command
  AWT_TEST_AGENT=0x41
  expect_exit 7 '16進数のキー表記を含む agentCommand を文字列として送る' --directory "$AWT_TEST_DIR" --prompt x
  checked=$((checked + 1))
  if T capture-pane -p -t '=literal-command:' | rg -q -F "handoff> 0x41 'x'"; then
    info 'OK: pane に 0x41 が literal で届いた'
  else
    ng 'pane に 0x41 が literal で届いていません'
  fi
}

group_gone() {
  local before
  AWT_TEST_MODE=missing-session
  AWT_TEST_SESSION=gone
  T new-session -d -s gone-other -x 120 -y 24 \
    env PS1='handoff> ' AWT_TEST_ARGV="$AWT_TEST_DIR/argv" /bin/bash --norc --noprofile -i
  sleep 0.5
  before=$(T capture-pane -p -t '=gone-other:')
  expect_exit 5 '存在しない session の接頭辞が一致しても送らない' --directory "$AWT_TEST_DIR" --prompt wrong-session
  expect_unsent gone-other "$before"
}

group_changing_screen() {
  local before cursor attempt
  cp "$work_dir/changing-screen.rc" "$work_dir/changing-screen.py" "$AWT_TEST_DIR/"
  AWT_TEST_MODE=changing-screen
  AWT_TEST_SESSION=changing-screen
  expect_exit 5 'cursor が正でも画面が変わり続ける pane には送らない' --directory "$AWT_TEST_DIR" --prompt changing-screen
  checked=$((checked + 1))
  cursor=$(T display-message -p -t '=changing-screen:' '#{cursor_x}')
  if [[ "$cursor" =~ ^[0-9]+$ && "$cursor" -gt 0 ]]; then
    info 'OK: 変化する画面の cursor は0より大きい'
  else
    ng '変化する画面の cursor が0より大きくありません'
  fi
  touch "$AWT_TEST_DIR/screen-stop"
  for ((attempt = 0; attempt < 50; attempt++)); do
    [[ ! -e "$AWT_TEST_DIR/screen-stop.done" ]] || break
    sleep 0.1
  done
  checked=$((checked + 1))
  if [[ -e "$AWT_TEST_DIR/screen-stop.done" ]]; then
    info 'OK: 変化する画面の出力が止まった'
  else
    ng '変化する画面の出力が止まりません'
  fi
  before=$(T capture-pane -p -t '=changing-screen:')
  expect_unsent changing-screen "$before"
}

group_no_prompt() {
  local before
  AWT_TEST_MODE=no-prompt
  AWT_TEST_SESSION=no-prompt
  expect_exit 5 'cursor が動かない pane はタイムアウトする' --directory "$AWT_TEST_DIR" --prompt waiting
  before=$(T capture-pane -p -t '=no-prompt:')
  expect_unsent no-prompt "$before"
}

group_shell() {
  local shell_name="$1"
  if ! command -v "$shell_name" >/dev/null 2>&1; then
    if [[ "${CI:-}" == true ]]; then
      checked=$((checked + 1))
      ng "$shell_name がありません"
    else
      info "SKIP: $shell_name がありません"
    fi
    return 0
  fi
  export AWT_TEST_SHELL
  AWT_TEST_SHELL=$(command -v "$shell_name")
  AWT_TEST_MODE="$shell_name"
  AWT_TEST_SESSION="$shell_name"
  expect_exit 0 "$shell_name の pane へ送信する" --directory "$AWT_TEST_DIR" --prompt "$prompt"
  checked=$((checked + 1))
  if wait_for_argv && expect_argv_prompt "$prompt"; then
    info "OK: $shell_name でも argv がそのまま届いた"
  else
    ng "$shell_name の argv が期待と異なります"
  fi
}

# 背景の群の中で動く。件数は親へ戻らないので、最後に result へ書く。result が無ければ親は途中で
# 止まった群として数えるので、result は最後の文でだけ書く。
run_group() {
  trap - EXIT
  AWT_TEST_DIR="$1"
  shift
  checked=0
  failures=0
  "$@"
  printf '%s %s\n' "$checked" "$failures" >"$AWT_TEST_DIR/result"
}

running_groups() {
  local i running=0
  for ((i = 0; i < ${#group_pids[@]}; i++)); do
    if kill -0 "${group_pids[i]}" 2>/dev/null; then
      running=$((running + 1))
    fi
  done
  printf '%s' "$running"
}

# 最古の pid を wait する形にしない。17 秒かかるタイムアウト系が先頭に居座り、空いた枠が埋まらない。
# bash 3.2 には wait -n が無いので、生きている群を数えて待つ。
start_group() {
  local name="$1" dir="$work_dir/cases/$1"
  shift
  while [[ "$(running_groups)" -ge "$max_jobs" ]]; do
    sleep 0.2
  done
  mkdir "$dir"
  run_group "$dir" "$@" >"$dir/log" 2>&1 &
  group_pids+=("$!")
  group_names+=("$name")
}

# 直列の段。tmux の global environment を変える区間を、並列の群と重ねない (重なると群が exit 69 になる)。
expect_exit 0 '環境変数と異なる tmux global の窓口で --check が使える' --check
expect_no_call '--check'

expect_exit 2 '改行を拒否する' --directory "$AWT_TEST_DIR" --prompt $'first\nsecond'
expect_no_call '改行'
expect_exit 2 'CR を拒否する' --directory "$AWT_TEST_DIR" --prompt $'first\rsecond'
expect_no_call 'CR'
expect_exit 2 '空の指示を拒否する' --directory "$AWT_TEST_DIR" --prompt ''
expect_no_call '空の指示'
long_prompt=$(python3 -I -c 'print("あ" * 234, end="")')
expect_exit 2 '700 バイト超を拒否する' --directory "$AWT_TEST_DIR" --prompt "$long_prompt"
expect_no_call '700 バイト超'

for invalid_prompt in $'foo\\' 'a\\b' $'a\tb' $'a\x03b' $'a\x15b' $'a\x7fb' $'a\xffb' '-option'; do
  expect_exit 2 '危険な指示を拒否する' --directory "$AWT_TEST_DIR" --prompt "$invalid_prompt"
  expect_no_call '危険な指示'
done

T set-environment -gu AWT_HOSTCTL
expect_exit 69 'AWT_HOSTCTL が無い' --directory "$AWT_TEST_DIR" --prompt missing
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

# 次の2件は hostctl を呼ぶので、calls が無いことに頼る上の検査より後に置く。
AWT_TEST_SESSION=long-line
AWT_TEST_AGENT="$work_dir/agent $(python3 -I -c 'print(" " * 901, end="")')"
expect_exit 4 'LINE が900 バイト超なら送らない' --directory "$AWT_TEST_DIR" --prompt short
checked=$((checked + 1))
if [[ ! -e "$AWT_TEST_DIR/argv" ]] &&
  [[ "$(T capture-pane -p -t '=long-line:')" != *short* ]]; then
  info 'OK: 長すぎる LINE は送っていない'
else
  ng '長すぎる LINE が送信されています'
fi

rm -f "$AWT_TEST_DIR/argv"
AWT_TEST_SESSION=control-command
AWT_TEST_AGENT=$'echo\nunsafe'
expect_exit 4 'agentCommand の制御文字を拒否する' --directory "$AWT_TEST_DIR" --prompt short
checked=$((checked + 1))
if [[ ! -e "$AWT_TEST_DIR/argv" ]] &&
  [[ "$(T capture-pane -p -t '=control-command:')" != *short* ]]; then
  info 'OK: 制御文字を含む agentCommand は送っていない'
else
  ng '制御文字を含む agentCommand が送信されています'
fi

AWT_TEST_MODE=success
AWT_TEST_SESSION=success
AWT_TEST_AGENT="$work_dir/agent"

# 並列の段。タイムアウトを待つ群 (13〜15 秒) を先に起動し、その間に成功系を回す。
start_group prompt-command group_prompt_command
start_group no-agent group_no_agent
start_group short-lived-exec group_short_lived_exec
start_group literal-command group_literal_command
start_group gone group_gone
start_group changing-screen group_changing_screen
start_group no-prompt group_no_prompt
start_group success group_success
start_group exec-agent group_exec_agent
start_group from-pane-valid group_from_pane %22 'TMUX_PANE を --from-pane で渡す' %22
start_group from-pane-unset group_from_pane - 'TMUX_PANE が無ければ --from-pane を足さない' ''
start_group from-pane-invalid-1 group_from_pane 22 "不正な TMUX_PANE '22' は渡さない" ''
start_group from-pane-invalid-2 group_from_pane %2a "不正な TMUX_PANE '%2a' は渡さない" ''
start_group from-pane-invalid-3 group_from_pane '' "不正な TMUX_PANE '' は渡さない" ''
start_group from-pane-old group_from_pane_old
start_group default-empty group_default_agent ''
start_group default-whitespace group_default_agent '   '
start_group zsh group_shell zsh
start_group fish group_shell fish

# 群のログはすべて回収してから起動順に出す。並列の出力が混ざらず、順も実行ごとに変わらない。
group_rcs=()
for ((group_index = 0; group_index < ${#group_pids[@]}; group_index++)); do
  group_rc=0
  wait "${group_pids[group_index]}" || group_rc=$?
  group_rcs+=("$group_rc")
done

for ((group_index = 0; group_index < ${#group_pids[@]}; group_index++)); do
  group_name="${group_names[group_index]}"
  group_dir="$work_dir/cases/$group_name"
  group_rc="${group_rcs[group_index]}"
  cat "$group_dir/log" >&2
  group_checked=""
  group_failures=""
  if [[ -f "$group_dir/result" ]]; then
    read -r group_checked group_failures <"$group_dir/result" || true
  fi
  if [[ "$group_rc" -ne 0 || ! "$group_checked" =~ ^[0-9]+$ || ! "$group_failures" =~ ^[0-9]+$ ]]; then
    checked=$((checked + 1))
    ng "$group_name: 途中で止まりました (exit $group_rc)"
  fi
  if [[ "$group_checked" =~ ^[0-9]+$ && "$group_failures" =~ ^[0-9]+$ ]]; then
    checked=$((checked + group_checked))
    failures=$((failures + group_failures))
  fi
done

[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
__awt_finished=1
