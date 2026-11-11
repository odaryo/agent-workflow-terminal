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
# 同時に走らせる群の数。CI の runner は 3 コアで、負荷で揺れやすいのは次の2つである。
# - changing-screen: 0.05 秒ごとの出力が 0.2 秒止まると、安定と判定されて送信してしまう。
# - gone-other: 作成から 0.5 秒でプロンプトが出ている前提に頼っている。
# どちらも誤って NG になる向きに揺れるので、NG が出たらここを下げる (Issue #852)。
max_jobs=8
group_names=()
group_pids=()
group_rcs=()
groups_reported=0
__awt_finished=0

T() { env -u TMUX tmux -L "$SOCK" "$@"; }

wait_running_groups() {
  local i rc
  for ((i = ${#group_rcs[@]}; i < ${#group_pids[@]}; i++)); do
    rc=0
    wait "${group_pids[i]}" 2>/dev/null || rc=$?
    group_rcs+=("$rc")
  done
}

# 群のログはすべて回収してから起動順に出す。並列の出力が混ざらず、順も実行ごとに変わらない。
# 通常の NG も die から on_exit に入るので、出したことを覚えておかないと全群のログが2回出る。
report_groups() {
  local i name dir rc group_checked group_failures
  groups_reported=1
  for ((i = 0; i < ${#group_pids[@]}; i++)); do
    name="${group_names[i]}"
    dir="$work_dir/cases/$name"
    rc="${group_rcs[i]:-0}"
    info "== 群 $name =="
    cat "$dir/log" >&2 || true
    group_checked=""
    group_failures=""
    if [[ -f "$dir/result" ]]; then
      read -r group_checked group_failures <"$dir/result" || true
    fi
    if [[ "$rc" -ne 0 || ! "$group_checked" =~ ^[0-9]+$ || ! "$group_failures" =~ ^[0-9]+$ ]]; then
      checked=$((checked + 1))
      ng "$name: 途中で止まりました (exit $rc)"
      [[ ! -f "$dir/stopped" ]] || cat "$dir/stopped" >&2 || true
    fi
    if [[ "$group_checked" =~ ^[0-9]+$ && "$group_failures" =~ ^[0-9]+$ ]]; then
      checked=$((checked + group_checked))
      failures=$((failures + group_failures))
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
    if [[ "$stop_rc" -ne 2 ]]; then
      [[ "$stop_rc" -eq 0 ]] || info "後始末: stop-tty-processes.sh が exit $stop_rc で終わりました"
      return "$stop_rc"
    fi
  done
  info "後始末: stop-tty-processes.sh が 4 回とも exit 2 で終わりました"
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
  wait_running_groups || true
  [[ "$groups_reported" -eq 1 ]] || report_groups || true
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

# zsh は rc の外部コマンドを別のプロセスグループで前景に置く (bash の rc と fish の conf.d はシェルと同じ pgid)。
# 待ちは群が rc-marker を作るまで続き、上限に達したら rc-timeout を作って終わる。送信の時機を負荷に頼らないため。
cat >"$work_dir/zsh-rc-wait.zshrc" <<'RC'
PS1='handoff> '
print -n 'loading> '
/bin/sh -c '
i=0
while [ ! -e "$1" ]; do
  if [ "$i" -ge 100 ]; then
    : >"$2"
    exit 0
  fi
  i=$((i + 1))
  /bin/sleep 0.1
done
' sh "$AWT_TEST_DIR/rc-marker" "$AWT_TEST_DIR/rc-timeout"
RC

# exec しないので、プロンプトでの前景は子の zsh の pgid になり、pane の PID の pgid とは一致しない。
cat >"$work_dir/bash-child-zsh.rc" <<'RC'
PS1='handoff> '
"$AWT_TEST_SHELL" -f -i
RC

# rc の待ちが明けた前景が子 zsh の pgid に戻る形を作るため、exec しない。
cat >"$work_dir/bash-child-zsh-rc.rc" <<'RC'
PS1='handoff> '
ZDOTDIR="$AWT_TEST_DIR" "$AWT_TEST_SHELL" -i
RC

# 引数の数と各引数を NUL 区切りで書くので、空白や改行を含む引数も呼び出しの境界も崩れない。
cat >"$work_dir/tmux-shim" <<'SHIM'
#!/bin/bash
set -eu
printf '%s\0' "$#" "$@" >>"$AWT_TEST_TMUX_LOG"
exec "$AWT_TEST_REAL_TMUX" "$@"
SHIM

cat >"$work_dir/hostctl" <<'HOSTCTL'
#!/usr/bin/env bash
set -eu
if [[ $# -ge 2 && "$1" == project && "$2" == check ]]; then
  printf 'called\n' >>"$AWT_TEST_DIR/calls"
  printf '%s\0' "$#" "$@" >>"$AWT_TEST_DIR/check-calls"
  [[ $# -eq 6 && "$3" == --directory && "$5" == --socket && "$6" == test-socket ]] || exit 2
  case "${AWT_TEST_HOSTCTL_CHECK:-registered}" in
    registered)
      printf '%s\n' '{"ok":true,"registered":true,"version":1}'
      exit 0
      ;;
    not-registered)
      printf '%s\n' '{"code":"not_registered","message":"not registered","ok":false,"version":1}'
      exit 1
      ;;
    old) exit 2 ;;
    unavailable) exit 69 ;;
    communication-error) exit 74 ;;
    *) exit 2 ;;
  esac
fi
# AWT_TEST_HOSTCTL_KIND: new は --from-pane と --purpose を、from-pane は --from-pane だけを知る。old はどちらも知らない。
command_ok=0
if [[ $# -ge 2 && "$1" == worktree && "$2" == open ]]; then
  command_ok=1
  shift 2
fi
directory=""
socket=""
from_pane=""
from_pane_set=0
purpose=""
purpose_set=0
unknown=""
while [[ "$command_ok" -eq 1 && $# -gt 0 ]]; do
  option="$1"
  case "$option" in
    --directory | --socket) ;;
    --from-pane) [[ "$AWT_TEST_HOSTCTL_KIND" != old ]] || unknown="${unknown:-$option}" ;;
    --purpose) [[ "$AWT_TEST_HOSTCTL_KIND" == new ]] || unknown="${unknown:-$option}" ;;
    *)
      unknown="${unknown:-$option}"
      shift
      continue
      ;;
  esac
  if [[ $# -lt 2 ]]; then
    unknown="${unknown:-$option}"
    break
  fi
  case "$option" in
    --directory) directory="$2" ;;
    --socket) socket="$2" ;;
    --from-pane)
      from_pane="$2"
      from_pane_set=1
      ;;
    --purpose)
      purpose="$2"
      purpose_set=1
      ;;
  esac
  shift 2
done
# calls と from-pane は exit 2 で拒否した呼び出しも含めて全部記録する。sends は exit 2 以外で終わったものだけ。
printf 'called\n' >>"$AWT_TEST_DIR/calls"
printf '%s\n' "$from_pane" >>"$AWT_TEST_DIR/from-pane"
if [[ -n "$unknown" ]]; then
  printf '不正な引数です: %s\n' "$unknown" >&2
  exit 2
fi
[[ "$command_ok" -eq 1 && "$directory" == "$AWT_TEST_DIR" && "$socket" == test-socket ]] || exit 2
if [[ "$purpose_set" -eq 1 && ( -z "$purpose" || "$purpose" == --* ) ]]; then
  printf '%s\n' '不正な引数です: --purpose' >&2
  exit 2
fi
if [[ "$AWT_TEST_MODE" == argument-error ]]; then
  printf '%s\n' 'invalid arguments' >&2
  exit 2
fi
if [[ "$AWT_TEST_MODE" == wait-release ]]; then
  touch "$AWT_TEST_DIR/hostctl-started"
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ ! -e "$AWT_TEST_DIR/hostctl-release" ]] || break
    sleep 0.1
  done
  exit 2
fi
printf 'sent\n' >>"$AWT_TEST_DIR/sends"
printf '%s\0%s\0%s\0%s\0' "$from_pane_set" "$from_pane" "$purpose_set" "$purpose" >"$AWT_TEST_DIR/last-send"
if [[ "$AWT_TEST_MODE" == unavailable ]]; then
  printf '%s\n' '{"ok":false,"version":1,"code":"unavailable","message":"app is not running"}' >&2
  exit 69
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
  zsh-rc)
    tmux new-session -d -s "$AWT_TEST_SESSION" -x 120 -y 24 \
      env ZDOTDIR="$AWT_TEST_DIR" AWT_TEST_DIR="$AWT_TEST_DIR" AWT_TEST_ARGV="$AWT_TEST_DIR/argv" "$AWT_TEST_SHELL" -i
    ;;
  bash-child-zsh)
    tmux new-session -d -s "$AWT_TEST_SESSION" -x 120 -y 24 \
      env AWT_TEST_SHELL="$AWT_TEST_SHELL" AWT_TEST_ARGV="$AWT_TEST_DIR/argv" \
      /bin/bash --noprofile --rcfile "$AWT_TEST_DIR/bash-child-zsh.rc" -i
    ;;
  bash-child-zsh-rc)
    tmux new-session -d -s "$AWT_TEST_SESSION" -x 120 -y 24 \
      env AWT_TEST_DIR="$AWT_TEST_DIR" AWT_TEST_SHELL="$AWT_TEST_SHELL" AWT_TEST_ARGV="$AWT_TEST_DIR/argv" \
      /bin/bash --noprofile --rcfile "$AWT_TEST_DIR/bash-child-zsh-rc.rc" -i
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
chmod +x "$work_dir/agent" "$work_dir/hostctl" "$work_dir/tmux-shim"
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
export AWT_TEST_HOSTCTL_KIND=new
export AWT_TEST_HOSTCTL_CHECK=registered
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
  rm -f "$AWT_TEST_DIR/calls" "$AWT_TEST_DIR/from-pane" "$AWT_TEST_DIR/sends" "$AWT_TEST_DIR/last-send" \
    "$AWT_TEST_DIR/argv" "$AWT_TEST_DIR/check-calls"
}

expect_project_check() {
  local label="$1"
  checked=$((checked + 1))
  if [[ ! -s "$AWT_TEST_DIR/stdout" && ! -e "$AWT_TEST_DIR/sends" ]] &&
    python3 -I - "$AWT_TEST_DIR" "$(pwd -P)" <<'PYTHON'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
assert (root / "calls").read_bytes() == b"called\n"
assert (root / "check-calls").read_bytes().split(b"\0") == [
    b"6", b"project", b"check", b"--directory", sys.argv[2].encode(),
    b"--socket", b"test-socket", b"",
]
PYTHON
  then
    info "OK: $label (登録確認は1回、引数と空の stdout が期待どおり、worktree open は呼ばれない)"
  else
    ng "$label: 登録確認の呼び出しまたは stdout が期待と異なります"
  fi
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

# 送信 (exit 2 以外で終わった呼び出し) が1回だけで、その引数の組が期待どおりかを見る。
expect_send() {
  local label="$1" sends=-1
  checked=$((checked + 1))
  printf '%s\0%s\0%s\0%s\0' "$2" "$3" "$4" "$5" >"$AWT_TEST_DIR/want-send"
  [[ ! -f "$AWT_TEST_DIR/sends" ]] || sends=$(wc -l <"$AWT_TEST_DIR/sends" | tr -d ' ')
  if [[ "$sends" -eq 1 ]] && cmp -s "$AWT_TEST_DIR/want-send" "$AWT_TEST_DIR/last-send"; then
    info "OK: $label (送信は1回で、引数の組が期待どおり)"
  else
    ng "$label: 送信が期待と異なります (送信 $sends 回)"
    tr '\0' '|' 2>/dev/null <"$AWT_TEST_DIR/last-send" || true
    printf '\n'
  fi
}

expect_stderr_contains() {
  local label="$1" text="$2"
  checked=$((checked + 1))
  if rg -q -F -- "$text" "$AWT_TEST_DIR/stderr"; then
    info "OK: $label (stderr に「${text}」がある)"
  else
    ng "$label: stderr に「${text}」がありません"
    cat "$AWT_TEST_DIR/stderr"
  fi
}

# shellcheck disable=SC2016 # 展開されずにそのまま Agent へ届くことを検査する
prompt="指示 'quoted'"' $HOME `printf expanded` # end'
purpose_value='Issue #837 の目的'
long_purpose=$(python3 -I -c 'print("あ" * 341 + "a", end="")')
# shellcheck disable=SC2016 # 展開されずにそのまま hostctl へ届くことを検査する
quoted_purpose='目的 '"'"'single'"'"' "double" $(printf expanded) `printf expanded`'

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
  AWT_TEST_HOSTCTL_KIND=old
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
  AWT_TEST_HOSTCTL_KIND=new

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

# zsh が無いときの扱いは group_shell に揃える (CI では NG、ローカルでは SKIP)。
use_test_zsh() {
  if ! command -v zsh >/dev/null 2>&1; then
    if [[ "${CI:-}" == true ]]; then
      checked=$((checked + 1))
      ng "zsh がありません"
    else
      info "SKIP: zsh がありません"
    fi
    return 1
  fi
  export AWT_TEST_SHELL
  AWT_TEST_SHELL=$(command -v zsh)
}

# watcher は背景の subshell なので、記録はファイルで親へ渡す。失敗しても watcher を非0で終わらせない
# (wait "$watcher" が非0を返すと、群が途中で止まったことになる)。
record_rc_wait_state() {
  local pane=""
  pane=$(T display-message -p -t "=$AWT_TEST_SESSION:" '#{pane_pid} #{pane_tty}' 2>/dev/null) || pane=""
  {
    printf 'pane_pid %s\n' "${pane%% *}"
    [[ "$pane" != *" "* ]] || ps -t "${pane#* }" -o pid=,ppid=,pgid=,tpgid=,comm= 2>&1 || true
  } >"$AWT_TEST_DIR/rc-wait-state" 2>/dev/null || true
}

# 陰性の群が効くのは、rc を実行する zsh が rc の外部コマンドを別の pgid で前景に置くときだけである
# (`unsetopt monitor` では同じ pgid になり、修正前の handoff.sh でも OK になる)。bash-child-zsh-rc では
# pane の PID は bash で、その pgid とは常に異なるので、比べる相手は子の zsh にする。
expect_rc_wait_foreground() {
  local label="$1" mode="$2"
  checked=$((checked + 1))
  if python3 -I - "$AWT_TEST_DIR/rc-wait-state" "$mode" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
if not path.exists():
    sys.exit("記録がありません")
lines = path.read_text(errors="replace").splitlines()
if not lines or not lines[0].startswith("pane_pid "):
    sys.exit("pane_pid の記録がありません")
pane_pid = lines[0][len("pane_pid "):]
if not pane_pid.isdigit():
    sys.exit("pane_pid が数値ではありません")
processes = []
for line in lines[1:]:
    fields = line.split(None, 4)
    if len(fields) == 5:
        processes.append(fields)
if mode == "zsh-rc":
    shells = [fields for fields in processes if fields[0] == pane_pid]
else:
    shells = [fields for fields in processes if fields[1] == pane_pid and fields[4].endswith("zsh")]
if len(shells) != 1:
    sys.exit("rc を実行する zsh が1つに決まりません (" + str(len(shells)) + " 件)")
pid, _, pgid, tpgid, _ = shells[0]
if not pgid.isdigit() or not tpgid.isdigit():
    sys.exit("zsh " + pid + " の pgid か tpgid が数値ではありません")
if pgid == tpgid:
    sys.exit("zsh " + pid + " の pgid と前景の pgid が同じ " + pgid + " です")
PYTHON
  then
    info "OK: $label (rc の待ちの間、前景は rc を実行する zsh とは別の pgid だった)"
  else
    ng "$label: rc の待ちの間の前景が、rc を実行する zsh とは別の pgid だったことを確かめられません"
    cat "$AWT_TEST_DIR/rc-wait-state" 2>/dev/null || true
  fi
}

# 送った指示は、rc の待ちの間は tty の echo で画面に出る。それを見てから rc-marker を作るので、待ちが rc-marker で
# 終わったなら (rc-timeout が無ければ) 送信は待ちの間だった。待ちの後に送信されたなら rc-timeout が先にできる。
watch_rc_wait() {
  local text="$1" attempt screen
  for ((attempt = 0; attempt < 200; attempt++)); do
    [[ ! -e "$AWT_TEST_DIR/rc-timeout" && ! -e "$AWT_TEST_DIR/watch-stop" ]] || return 0
    screen=$(T capture-pane -p -J -t "=$AWT_TEST_SESSION:" 2>/dev/null) || screen=""
    if [[ "$screen" == *"$text"* ]]; then
      # rc-marker の後は待ちが明けて前景が rc を実行する zsh に戻るので、その前に記録する。
      record_rc_wait_state || true
      touch "$AWT_TEST_DIR/rc-marker"
      return 0
    fi
    sleep 0.1
  done
}

# 引数の agent は missing (存在しないパス) か agent ($work_dir/agent)。
group_zsh_rc() {
  local want="$1" agent="$2" label="$3" mode="${4:-zsh-rc}" watcher
  use_test_zsh || return 0
  cp "$work_dir/zsh-rc-wait.zshrc" "$AWT_TEST_DIR/.zshrc"
  if [[ "$mode" == bash-child-zsh-rc ]]; then
    cp "$work_dir/bash-child-zsh-rc.rc" "$AWT_TEST_DIR/"
  fi
  AWT_TEST_MODE="$mode"
  AWT_TEST_SESSION=$(basename -- "$AWT_TEST_DIR")
  if [[ "$agent" == missing ]]; then
    AWT_TEST_AGENT="$AWT_TEST_DIR/no-such-agent"
  else
    AWT_TEST_AGENT="$work_dir/agent"
  fi
  # 送る行は「agentCommand '指示'」なので、引用符を含めた形は送信の前の画面に現れない。
  watch_rc_wait "'$AWT_TEST_SESSION'" &
  watcher=$!
  expect_exit "$want" "$label" --directory "$AWT_TEST_DIR" --prompt "$AWT_TEST_SESSION"
  touch "$AWT_TEST_DIR/watch-stop"
  wait "$watcher"
  checked=$((checked + 1))
  if [[ -e "$AWT_TEST_DIR/rc-marker" && ! -e "$AWT_TEST_DIR/rc-timeout" ]]; then
    info "OK: $label (送信は rc の待ちの間だった)"
  else
    ng "$label: 送信が rc の待ちの間ではありません"
    T capture-pane -p -J -t "=$AWT_TEST_SESSION:" 2>/dev/null || true
  fi
  expect_rc_wait_foreground "$label" "$mode"
  if [[ "$mode" == bash-child-zsh-rc ]]; then
    expect_bash_child_zsh "$label"
  fi
  [[ "$agent" == missing ]] || expect_agent_prompt "$label" "$AWT_TEST_SESSION"
}

group_bash_child_zsh() {
  local label='bash の rc から起動した子の対話 zsh の pane へ送信する'
  use_test_zsh || return 0
  cp "$work_dir/bash-child-zsh.rc" "$AWT_TEST_DIR/"
  AWT_TEST_MODE=bash-child-zsh
  AWT_TEST_SESSION=bash-child-zsh
  expect_exit 0 "$label" --directory "$AWT_TEST_DIR" --prompt "$prompt"
  expect_agent_prompt "$label" "$prompt"
  expect_bash_child_zsh "$label"
}

expect_bash_child_zsh() {
  local label="$1" pane_pid children
  # exec されると、子 zsh の pgid と pane の PID の pgid が異なる前提を満たさない。
  checked=$((checked + 1))
  pane_pid=$(T display-message -p -t "=$AWT_TEST_SESSION:" '#{pane_pid}') || pane_pid=""
  children=$(ps -A -o ppid=,comm= | awk -v parent="$pane_pid" '$1 == parent { print $2 }') || children=""
  if [[ "$pane_pid" =~ ^[0-9]+$ && "$(ps -o comm= -p "$pane_pid")" == *bash && "$children" == *zsh* ]]; then
    info "OK: $label (pane の PID は bash で、子に zsh がいる)"
  else
    ng "$label: pane が bash と子の zsh の形になっていません"
  fi
}

group_tmux_targets() {
  local label='tmux の -t はすべて完全一致の =<session>: を使う' real_tmux
  real_tmux=$(command -v tmux)
  mkdir "$AWT_TEST_DIR/shim-bin"
  cp "$work_dir/tmux-shim" "$AWT_TEST_DIR/shim-bin/tmux"
  AWT_TEST_SESSION=tmux-targets
  # 偽 hostctl も同じ PATH を継承するので、その new-session も記録に入る。
  pane_env=(-u TMUX_PANE PATH="$AWT_TEST_DIR/shim-bin:$PATH" AWT_TEST_REAL_TMUX="$real_tmux"
    AWT_TEST_TMUX_LOG="$AWT_TEST_DIR/tmux-calls")
  expect_exit 0 "$label" --directory "$AWT_TEST_DIR" --prompt tmux-targets
  expect_agent_prompt "$label" tmux-targets
  checked=$((checked + 1))
  # 特定の行を数えず、-t を持つ呼び出しをすべて見る。handoff.sh が -t 付きの呼び出しを足せば、それも対象になる。
  if python3 -I -c '
import pathlib
import sys

want = sys.argv[2]
fields = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")
if fields[-1] != b"":
    sys.exit("記録が NUL で終わっていません")
fields.pop()
calls = []
index = 0
while index < len(fields):
    count = int(fields[index])
    calls.append([field.decode("utf-8") for field in fields[index + 1:index + 1 + count]])
    index += 1 + count
if index != len(fields):
    sys.exit("記録の引数の数が合いません")
problems = []
kinds = {"display-message #{cursor_x}": 0, "capture-pane": 0, "display-message #{pane_pid}": 0,
         "send-keys -l": 0, "send-keys Enter": 0}
# tmux は -pt のような束ねた指定と、-t=<値> のように残りを値とする連結形を受け付ける。束ねた中の t が
# 別のオプションの値の一部 (-Ft) でも -t とみなす。誤って NG になる向きにだけ倒し、漏れる向きを作らない。
# -- で始まる引数は tmux のオプションではない (偽 hostctl の new-session の /bin/bash --norc など)。
for args in calls:
    rest = args[1:]
    options = rest[:rest.index("--")] if "--" in rest else rest
    targeted = False
    for position, arg in enumerate(options):
        if arg == "-" or not arg.startswith("-") or arg.startswith("--") or "t" not in arg[1:]:
            continue
        targeted = True
        value = arg[arg.index("t", 1) + 1:]
        if value == "":
            if position + 1 >= len(options):
                problems.append(args)
                continue
            value = options[position + 1]
        if value != want:
            problems.append(args)
    if not targeted or not args:
        continue
    if args[0] == "display-message" and "#{cursor_x}" in args:
        kinds["display-message #{cursor_x}"] += 1
    if args[0] == "capture-pane":
        kinds["capture-pane"] += 1
    if args[0] == "display-message" and "#{pane_pid}" in args:
        kinds["display-message #{pane_pid}"] += 1
    if args[0] == "send-keys" and "-l" in options:
        kinds["send-keys -l"] += 1
    if args[0] == "send-keys" and args[-1] == "Enter":
        kinds["send-keys Enter"] += 1
for args in problems:
    print("-t が " + want + " ではありません: " + repr(args), file=sys.stderr)
for kind, count in kinds.items():
    if count == 0:
        print("-t 付きの " + kind + " がありません", file=sys.stderr)
if problems or 0 in kinds.values():
    for args in calls:
        print(repr(args), file=sys.stderr)
    sys.exit(1)
' "$AWT_TEST_DIR/tmux-calls" '=tmux-targets:'; then
    info "OK: $label"
  else
    ng "$label: -t の値か呼び出しの種類が期待と異なります"
  fi
}

group_purpose_matrix() {
  local kind="$1" pane_kind="$2" purpose_kind="$3"
  local label="hostctl=$kind TMUX_PANE=$pane_kind --purpose=$purpose_kind"
  local arguments=(--directory "$AWT_TEST_DIR" --prompt purpose-matrix)
  local want_calls=()
  local want_pane_set=0 want_pane='' want_purpose_set=0 want_purpose=''
  AWT_TEST_HOSTCTL_KIND="$kind"
  AWT_TEST_SESSION="purpose-$kind-pane-$pane_kind-purpose-$purpose_kind"
  [[ "$purpose_kind" != set ]] || arguments+=(--purpose "$purpose_value")
  # 呼び出しごとの --from-pane の値。段は「両方 → --from-pane だけ → 無し」から付けるものが無い段を除いたもの。
  if [[ "$pane_kind" == set ]]; then
    pane_env=(TMUX_PANE=%22)
    [[ "$purpose_kind" != set || "$kind" == new ]] || want_calls+=(%22)
    if [[ "$kind" == old ]]; then
      want_calls+=(%22 '')
    else
      want_calls+=(%22)
    fi
  else
    pane_env=(-u TMUX_PANE)
    [[ "$purpose_kind" != set || "$kind" == new ]] || want_calls+=('')
    want_calls+=('')
  fi
  if [[ "$pane_kind" == set && "$kind" != old ]]; then
    want_pane_set=1
    want_pane=%22
  fi
  if [[ "$purpose_kind" == set && "$kind" == new ]]; then
    want_purpose_set=1
    want_purpose="$purpose_value"
  fi
  expect_exit 0 "$label" "${arguments[@]}"
  expect_hostctl_calls "$label" "${want_calls[@]}"
  expect_send "$label" "$want_pane_set" "$want_pane" "$want_purpose_set" "$want_purpose"
  expect_agent_prompt "$label" purpose-matrix
  expect_no_old_hostctl_error "$label"
}

group_purpose_valid() {
  local index="$1" valid_purpose="$2"
  AWT_TEST_HOSTCTL_KIND=new
  pane_env=(-u TMUX_PANE)
  AWT_TEST_SESSION="purpose-valid-$index"
  expect_exit 0 "目的 $index はそのまま渡す" --directory "$AWT_TEST_DIR" --prompt purpose-valid --purpose "$valid_purpose"
  expect_send "目的 $index はそのまま渡す" 0 '' 1 "$valid_purpose"
}

group_purpose_no_mktemp() {
  AWT_TEST_HOSTCTL_KIND=old
  pane_env=(TMUX_PANE=%22 TMPDIR="$work_dir/missing-tmp")
  AWT_TEST_SESSION=purpose-no-mktemp
  expect_exit 0 'mktemp に失敗しても段を飛ばさずに呼び直す' --directory "$AWT_TEST_DIR" --prompt purpose-no-mktemp --purpose "$purpose_value"
  expect_hostctl_calls 'mktemp に失敗しても段を飛ばさずに呼び直す' %22 %22 ''
  expect_send 'mktemp に失敗しても段を飛ばさずに呼び直す' 0 '' 0 ''
  expect_agent_prompt 'mktemp に失敗しても段を飛ばさずに呼び直す' purpose-no-mktemp
  # 一時ファイルに取れていれば出ない文言なので、mktemp が実際に失敗したことの確認になる。
  expect_stderr_contains 'mktemp に失敗したときは exit 2 の段の stderr をそのまま出す' '不正な引数です: --from-pane'
}

group_tempfile_signal() {
  local signal="$1" want="$2" label="$1 で一時ファイルを消して終了する"
  local handoff_pid attempt temp_file temp_count=0 ready=1 rc=0
  mkdir "$AWT_TEST_DIR/tmp"
  pane_env=(TMUX_PANE=%22 TMPDIR="$AWT_TEST_DIR/tmp")
  AWT_TEST_MODE=wait-release
  # job control 無しの & は SIGINT を無視して起動するので、exec の前に既定へ戻す。
  python3 -I -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    env "${pane_env[@]}" TMUX="$socket_path,0,0" AWT_HOSTCTL=/missing/hostctl AWT_HOSTCTL_SOCKET=wrong-socket \
    "$HANDOFF" --directory "$AWT_TEST_DIR" --prompt tempfile-signal \
    >"$AWT_TEST_DIR/stdout" 2>"$AWT_TEST_DIR/stderr" &
  handoff_pid=$!
  for ((attempt = 0; attempt < 50; attempt++)); do
    [[ ! -e "$AWT_TEST_DIR/hostctl-started" ]] || break
    kill -0 "$handoff_pid" 2>/dev/null || break
    sleep 0.1
  done
  checked=$((checked + 1))
  if [[ -e "$AWT_TEST_DIR/hostctl-started" ]]; then
    info "OK: $label (hostctl の開始を確認した)"
  else
    ng "$label: hostctl が上限内に開始しませんでした"
    ready=0
  fi
  for temp_file in "$AWT_TEST_DIR/tmp"/awt-handoff.*; do
    [[ ! -e "$temp_file" ]] || temp_count=$((temp_count + 1))
  done
  checked=$((checked + 1))
  if [[ "$temp_count" -eq 1 ]]; then
    info "OK: $label (シグナル前の awt-handoff.* は1つ)"
  else
    ng "$label: シグナル前の awt-handoff.* は $temp_count 個です (期待: 1)"
    ready=0
  fi
  if [[ "$ready" -eq 1 ]]; then
    if ! kill -"$signal" "$handoff_pid"; then
      checked=$((checked + 1))
      ng "$label: シグナルを送れませんでした"
      ready=0
    fi
  fi
  # 前景の hostctl が終わるまで trap は遅れるので、失敗時も release してから回収する。
  touch "$AWT_TEST_DIR/hostctl-release"
  wait "$handoff_pid" || rc=$?
  [[ "$ready" -eq 1 ]] || return 0

  checked=$((checked + 1))
  if [[ "$rc" -eq "$want" ]]; then
    info "OK (exit $rc): $label"
  else
    ng "$label: exit $rc (期待: $want)"
  fi
  temp_count=0
  for temp_file in "$AWT_TEST_DIR/tmp"/awt-handoff.*; do
    [[ ! -e "$temp_file" ]] || temp_count=$((temp_count + 1))
  done
  checked=$((checked + 1))
  if [[ "$temp_count" -eq 0 ]]; then
    info "OK: $label (awt-handoff.* は残っていない)"
  else
    ng "$label: awt-handoff.* が $temp_count 個残っています"
  fi
  expect_hostctl_calls "$label" %22
  checked=$((checked + 1))
  if [[ ! -e "$AWT_TEST_DIR/sends" ]]; then
    info "OK: $label (送信していない)"
  else
    ng "$label: 送信されています"
  fi
}

# bash 3.2 の ERR trap の中の $LINENO は、関数の定義行など失敗した行ではない値を返すので出さない。
# 呼び出しの連鎖の行番号 (BASH_LINENO) は正しい。
record_stop() {
  trap - ERR
  local status="$1" command="$2" chain="" i
  # set -E の ERR trap は、外側が失敗を許す $(...) の中でも発火する。止まっていない群に誤報を出さない。
  [[ "$BASH_SUBSHELL" -eq "$group_subshell" ]] || return 0
  for ((i = ${#FUNCNAME[@]} - 1; i >= 2; i--)); do
    chain+="${FUNCNAME[i]} ${BASH_LINENO[i - 1]}行 → "
  done
  chain+="${FUNCNAME[1]:-}"
  printf '止まったコマンド: %s (exit %s)、呼び出し: %s\n' "${command//$'\n'/ }" "$status" "$chain" \
    >"$AWT_TEST_DIR/stopped" || true
}

# 背景の群の中で動く。件数は親へ戻らないので、最後に result へ書く。result が無ければ親は途中で
# 止まった群として数えるので、result は最後の文でだけ書く。
run_group() {
  trap - EXIT
  AWT_TEST_DIR="$1"
  shift
  checked=0
  failures=0
  group_subshell=$BASH_SUBSHELL
  set -E
  trap 'record_stop "$?" "$BASH_COMMAND"' ERR
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
expect_project_check '--check'
expect_stderr_contains '--check の応答' '{"ok":true,"registered":true,"version":1}'
reset_hostctl_calls

for check_mode in not-registered old unavailable communication-error; do
  export AWT_TEST_HOSTCTL_CHECK="$check_mode"
  expect_exit 69 "登録確認が $check_mode なら --check は使えない" --check
  expect_project_check "$check_mode"
  expect_stderr_contains "$check_mode" 'このディレクトリがアプリに登録された Project か確かめられません'
  reset_hostctl_calls
done
export AWT_TEST_HOSTCTL_CHECK=registered

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

checked=$((checked + 1))
if [[ "$(printf '%s' "$long_purpose" | wc -c | tr -d ' ')" -eq 1024 ]]; then
  info 'OK: 1件目の目的は 1024 バイトちょうど'
else
  ng '1件目の目的が 1024 バイトではありません'
fi

too_long_purpose=$(python3 -I -c 'print("あ" * 341 + "ab", end="")')
purpose_index=0
for invalid_purpose in $'a\nb' $'a\tb' $'a\xc2\x85b' $'a\xe2\x80\xa8b' $'a\xe2\x80\xa9b' 'a\b' '-purpose' '' '   ' \
  "$too_long_purpose" 'end;' $'a\xffb'; do
  purpose_index=$((purpose_index + 1))
  expect_exit 2 "不正な目的 $purpose_index を拒否する" --directory "$AWT_TEST_DIR" --prompt purpose-invalid --purpose "$invalid_purpose"
  expect_no_call "不正な目的 $purpose_index"
  expect_stderr_contains "不正な目的 $purpose_index" '目的が不正です: '
done
pane_env=(TMUX_PANE=%22)
expect_exit 2 'TMUX_PANE があっても不正な目的を拒否する' --directory "$AWT_TEST_DIR" --prompt purpose-invalid --purpose 'end;'
expect_no_call 'TMUX_PANE があっても不正な目的'
pane_env=(-u TMUX_PANE)

expect_exit 2 '--purpose の2回目の指定を拒否する' --directory "$AWT_TEST_DIR" --prompt purpose-twice --purpose first --purpose second
expect_no_call '--purpose の2回目の指定'
expect_exit 2 '--purpose の値が無ければ拒否する' --directory "$AWT_TEST_DIR" --prompt purpose-missing --purpose
expect_no_call '--purpose の値が無い'

T set-environment -gu AWT_HOSTCTL
expect_exit 69 'AWT_HOSTCTL が無い' --directory "$AWT_TEST_DIR" --prompt missing
expect_exit 69 '--check が使えない' --check
expect_no_call '窓口が無い'
checked=$((checked + 1))
if env TMUX="$socket_path,0,0" AWT_HOSTCTL="$work_dir/hostctl" \
  AWT_HOSTCTL_SOCKET=test-socket "$HANDOFF" --check >"$AWT_TEST_DIR/stdout" 2>"$AWT_TEST_DIR/stderr"; then
  info 'OK: 同名の環境変数にフォールバックする'
else
  ng '同名の環境変数へのフォールバックが失敗しました'
fi
expect_project_check '環境変数へのフォールバック'
reset_hostctl_calls
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
start_group zsh-rc-no-agent group_zsh_rc 7 missing 'zsh の rc の待ちの間に送信しても、Agent が居なければ起動とみなさない'
start_group bash-child-zsh-rc-no-agent group_zsh_rc 7 missing \
  'bash の rc から起動した子の zsh の rc の待ちの間に送信しても、Agent が居なければ起動とみなさない' bash-child-zsh-rc
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
start_group zsh-rc-agent group_zsh_rc 0 agent 'zsh の rc の待ちの間に送信しても、Agent の起動を検出する'
start_group bash-child-zsh-rc-agent group_zsh_rc 0 agent \
  'bash の rc から起動した子の zsh の rc の待ちの間に送信しても、Agent の起動を検出する' bash-child-zsh-rc
start_group bash-child-zsh group_bash_child_zsh
start_group tmux-targets group_tmux_targets
for kind in new from-pane old; do
  for pane_kind in set unset; do
    for purpose_kind in set unset; do
      start_group "purpose-$kind-pane-$pane_kind-purpose-$purpose_kind" \
        group_purpose_matrix "$kind" "$pane_kind" "$purpose_kind"
    done
  done
done
start_group purpose-valid-1 group_purpose_valid 1 "$long_purpose"
start_group purpose-valid-2 group_purpose_valid 2 "$quoted_purpose"
start_group purpose-no-mktemp group_purpose_no_mktemp
start_group tempfile-int group_tempfile_signal INT 130
start_group tempfile-term group_tempfile_signal TERM 143
start_group tempfile-hup group_tempfile_signal HUP 129

wait_running_groups
report_groups

[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
__awt_finished=1
