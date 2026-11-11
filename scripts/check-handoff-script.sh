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
export AWT_TEST_HOSTCTL_KIND=new

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
AWT_TEST_SESSION=exec-agent
AWT_TEST_AGENT="exec $work_dir/agent"
sessions+=(exec-agent)
expect_exit 0 'exec で pane の shell を置き換えて起動する' --directory "$work_dir" --prompt "$prompt"
checked=$((checked + 1))
if wait_for_argv && python3 -I -c '
import pathlib
import sys
assert pathlib.Path(sys.argv[1]).read_bytes() == sys.argv[2].encode("utf-8") + b"\0"
' "$work_dir/argv" "$prompt"; then
  info 'OK: exec でも argv がそのまま届いた'
else
  ng 'exec の argv が期待と異なります'
fi
AWT_TEST_SESSION=success
AWT_TEST_AGENT="$work_dir/agent"

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

# 引数は呼び出しごとに偽 hostctl が受け取る --from-pane の値 (無ければ空)。末尾の改行まで比べる。
expect_hostctl_calls() {
  local label="$1" pane
  shift
  : >"$work_dir/want-calls"
  : >"$work_dir/want-from-pane"
  for pane in "$@"; do
    printf 'called\n' >>"$work_dir/want-calls"
    printf '%s\n' "$pane" >>"$work_dir/want-from-pane"
  done
  checked=$((checked + 1))
  if cmp -s "$work_dir/want-calls" "$work_dir/calls" &&
    cmp -s "$work_dir/want-from-pane" "$work_dir/from-pane"; then
    info "OK: $label (hostctl を $# 回呼んだ)"
  else
    ng "$label: hostctl の呼び出しが期待と異なります"
    cat "$work_dir/calls" "$work_dir/from-pane" 2>/dev/null || true
  fi
}

reset_hostctl_calls() {
  rm -f "$work_dir/calls" "$work_dir/from-pane" "$work_dir/sends" "$work_dir/last-send" "$work_dir/argv"
}

expect_agent_prompt() {
  local label="$1" want="$2"
  checked=$((checked + 1))
  if wait_for_argv && python3 -I -c '
import pathlib
import sys
assert pathlib.Path(sys.argv[1]).read_bytes() == sys.argv[2].encode("utf-8") + b"\0"
' "$work_dir/argv" "$want"; then
    info "OK: $label (Agent に指示が届いた)"
  else
    ng "$label: Agent に指示が届いていません"
  fi
}

expect_no_old_hostctl_error() {
  local label="$1"
  checked=$((checked + 1))
  if rg -q -F '不正な引数です' "$work_dir/stderr"; then
    ng "$label: 古い hostctl の拒否が stderr に出ています"
  else
    info "OK: $label (古い hostctl の拒否を出さない)"
  fi
}

AWT_TEST_MODE=success
AWT_TEST_AGENT="$work_dir/agent"

reset_hostctl_calls
pane_env=(TMUX_PANE=%22)
AWT_TEST_SESSION=from-pane-valid
sessions+=(from-pane-valid)
expect_exit 0 'TMUX_PANE を --from-pane で渡す' --directory "$work_dir" --prompt from-pane
expect_hostctl_calls 'TMUX_PANE を --from-pane で渡す' %22
expect_agent_prompt 'TMUX_PANE を --from-pane で渡す' from-pane

reset_hostctl_calls
pane_env=(-u TMUX_PANE)
AWT_TEST_SESSION=from-pane-unset
sessions+=(from-pane-unset)
expect_exit 0 'TMUX_PANE が無ければ --from-pane を足さない' --directory "$work_dir" --prompt from-pane
expect_hostctl_calls 'TMUX_PANE が無ければ --from-pane を足さない' ''
expect_agent_prompt 'TMUX_PANE が無ければ --from-pane を足さない' from-pane

invalid_index=0
for invalid_pane in 22 %2a ''; do
  invalid_index=$((invalid_index + 1))
  reset_hostctl_calls
  pane_env=("TMUX_PANE=$invalid_pane")
  AWT_TEST_SESSION="from-pane-invalid-$invalid_index"
  sessions+=("$AWT_TEST_SESSION")
  expect_exit 0 "不正な TMUX_PANE '${invalid_pane}' は渡さない" --directory "$work_dir" --prompt from-pane
  expect_hostctl_calls "不正な TMUX_PANE '${invalid_pane}' は渡さない" ''
  expect_agent_prompt "不正な TMUX_PANE '${invalid_pane}' は渡さない" from-pane
done

reset_hostctl_calls
AWT_TEST_HOSTCTL_KIND=old
pane_env=(TMUX_PANE=%22)
AWT_TEST_SESSION=from-pane-old
sessions+=(from-pane-old)
expect_exit 0 '古い hostctl には --from-pane を外して呼び直す' --directory "$work_dir" --prompt from-pane
expect_hostctl_calls '古い hostctl には --from-pane を外して呼び直す' %22 ''
expect_agent_prompt '古い hostctl には --from-pane を外して呼び直す' from-pane
expect_no_old_hostctl_error '古い hostctl には --from-pane を外して呼び直す'

reset_hostctl_calls
AWT_TEST_MODE=existing
expect_exit 3 '古い hostctl の呼び直しでも既存セッションには送らない' --directory "$work_dir" --prompt from-pane-existing
expect_hostctl_calls '古い hostctl の呼び直しでも既存セッションには送らない' %22 ''
expect_no_old_hostctl_error '古い hostctl の呼び直しでも既存セッションには送らない'
AWT_TEST_HOSTCTL_KIND=new

reset_hostctl_calls
AWT_TEST_MODE=unavailable
expect_exit 69 '--from-pane 付きの呼び出しの exit 69 を保つ' --directory "$work_dir" --prompt from-pane-unavailable
expect_hostctl_calls '--from-pane 付きの呼び出しの exit 69 を保つ' %22
checked=$((checked + 1))
if [[ ! -s "$work_dir/stdout" ]] && rg -q 'app is not running' "$work_dir/stderr"; then
  info 'OK: --from-pane 付きの呼び出しの失敗応答を stderr に出した'
else
  ng '--from-pane 付きの呼び出しの失敗応答が stderr にありません'
fi

reset_hostctl_calls
AWT_TEST_MODE=argument-error
pane_env=(-u TMUX_PANE)
expect_exit 1 '--from-pane 無しの exit 2 は呼び直さない' --directory "$work_dir" --prompt arguments
expect_hostctl_calls '--from-pane 無しの exit 2 は呼び直さない' ''

reset_hostctl_calls
pane_env=(TMUX_PANE=%22)
expect_exit 1 '呼び直しの exit 2 も exit 1 にする' --directory "$work_dir" --prompt arguments
expect_hostctl_calls '呼び直しの exit 2 も exit 1 にする' %22 ''
checked=$((checked + 1))
if [[ ! -s "$work_dir/stdout" && "$(cat "$work_dir/stderr")" == 'invalid arguments' ]]; then
  info 'OK: 呼び直しの出力だけを stderr に出した'
else
  ng '呼び直しの失敗時の出力が期待と異なります'
fi

# 送信 (exit 2 以外で終わった呼び出し) が1回だけで、その引数の組が期待どおりかを見る。
expect_send() {
  local label="$1" sends=-1
  checked=$((checked + 1))
  printf '%s\0%s\0%s\0%s\0' "$2" "$3" "$4" "$5" >"$work_dir/want-send"
  [[ ! -f "$work_dir/sends" ]] || sends=$(wc -l <"$work_dir/sends" | tr -d ' ')
  if [[ "$sends" -eq 1 ]] && cmp -s "$work_dir/want-send" "$work_dir/last-send"; then
    info "OK: $label (送信は1回で、引数の組が期待どおり)"
  else
    ng "$label: 送信が期待と異なります (送信 $sends 回)"
    tr '\0' '|' 2>/dev/null <"$work_dir/last-send" || true
    printf '\n'
  fi
}

expect_stderr_contains() {
  local label="$1" text="$2"
  checked=$((checked + 1))
  if rg -q -F -- "$text" "$work_dir/stderr"; then
    info "OK: $label (stderr に「${text}」がある)"
  else
    ng "$label: stderr に「${text}」がありません"
    cat "$work_dir/stderr"
  fi
}

AWT_TEST_MODE=success
AWT_TEST_AGENT="$work_dir/agent"
purpose_value='Issue #837 の目的'
for kind in new from-pane old; do
  for pane_kind in set unset; do
    for purpose_kind in set unset; do
      reset_hostctl_calls
      AWT_TEST_HOSTCTL_KIND="$kind"
      AWT_TEST_SESSION="purpose-$kind-pane-$pane_kind-purpose-$purpose_kind"
      sessions+=("$AWT_TEST_SESSION")
      label="hostctl=$kind TMUX_PANE=$pane_kind --purpose=$purpose_kind"
      arguments=(--directory "$work_dir" --prompt purpose-matrix)
      [[ "$purpose_kind" != set ]] || arguments+=(--purpose "$purpose_value")
      # 呼び出しごとの --from-pane の値。段は「両方 → --from-pane だけ → 無し」から付けるものが無い段を除いたもの。
      want_calls=()
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
      want_pane_set=0
      want_pane=''
      if [[ "$pane_kind" == set && "$kind" != old ]]; then
        want_pane_set=1
        want_pane=%22
      fi
      want_purpose_set=0
      want_purpose=''
      if [[ "$purpose_kind" == set && "$kind" == new ]]; then
        want_purpose_set=1
        want_purpose="$purpose_value"
      fi
      expect_exit 0 "$label" "${arguments[@]}"
      expect_hostctl_calls "$label" "${want_calls[@]}"
      expect_send "$label" "$want_pane_set" "$want_pane" "$want_purpose_set" "$want_purpose"
      expect_agent_prompt "$label" purpose-matrix
      expect_no_old_hostctl_error "$label"
    done
  done
done
AWT_TEST_HOSTCTL_KIND=new
pane_env=(-u TMUX_PANE)

long_purpose=$(python3 -I -c 'print("あ" * 341 + "a", end="")')
# shellcheck disable=SC2016 # 展開されずにそのまま hostctl へ届くことを検査する
quoted_purpose='目的 '"'"'single'"'"' "double" $(printf expanded) `printf expanded`'
purpose_index=0
for valid_purpose in "$long_purpose" "$quoted_purpose"; do
  purpose_index=$((purpose_index + 1))
  reset_hostctl_calls
  AWT_TEST_SESSION="purpose-valid-$purpose_index"
  sessions+=("$AWT_TEST_SESSION")
  expect_exit 0 "目的 $purpose_index はそのまま渡す" --directory "$work_dir" --prompt purpose-valid --purpose "$valid_purpose"
  expect_send "目的 $purpose_index はそのまま渡す" 0 '' 1 "$valid_purpose"
done
checked=$((checked + 1))
if [[ "$(printf '%s' "$long_purpose" | wc -c | tr -d ' ')" -eq 1024 ]]; then
  info 'OK: 1件目の目的は 1024 バイトちょうど'
else
  ng '1件目の目的が 1024 バイトではありません'
fi

reset_hostctl_calls
AWT_TEST_HOSTCTL_KIND=old
pane_env=(TMUX_PANE=%22 TMPDIR="$work_dir/missing-tmp")
AWT_TEST_SESSION=purpose-no-mktemp
sessions+=(purpose-no-mktemp)
expect_exit 0 'mktemp に失敗しても段を飛ばさずに呼び直す' --directory "$work_dir" --prompt purpose-no-mktemp --purpose "$purpose_value"
expect_hostctl_calls 'mktemp に失敗しても段を飛ばさずに呼び直す' %22 %22 ''
expect_send 'mktemp に失敗しても段を飛ばさずに呼び直す' 0 '' 0 ''
expect_agent_prompt 'mktemp に失敗しても段を飛ばさずに呼び直す' purpose-no-mktemp
# 一時ファイルに取れていれば出ない文言なので、mktemp が実際に失敗したことの確認になる。
expect_stderr_contains 'mktemp に失敗したときは exit 2 の段の stderr をそのまま出す' '不正な引数です: --from-pane'
AWT_TEST_HOSTCTL_KIND=new
pane_env=(-u TMUX_PANE)

too_long_purpose=$(python3 -I -c 'print("あ" * 341 + "ab", end="")')
reset_hostctl_calls
purpose_index=0
for invalid_purpose in $'a\nb' $'a\tb' $'a\xc2\x85b' $'a\xe2\x80\xa8b' $'a\xe2\x80\xa9b' 'a\b' '-purpose' '' '   ' \
  "$too_long_purpose" 'end;' $'a\xffb'; do
  purpose_index=$((purpose_index + 1))
  expect_exit 2 "不正な目的 $purpose_index を拒否する" --directory "$work_dir" --prompt purpose-invalid --purpose "$invalid_purpose"
  expect_no_call "不正な目的 $purpose_index"
  expect_stderr_contains "不正な目的 $purpose_index" '目的が不正です: '
done
pane_env=(TMUX_PANE=%22)
expect_exit 2 'TMUX_PANE があっても不正な目的を拒否する' --directory "$work_dir" --prompt purpose-invalid --purpose 'end;'
expect_no_call 'TMUX_PANE があっても不正な目的'
pane_env=(-u TMUX_PANE)

expect_exit 2 '--purpose の2回目の指定を拒否する' --directory "$work_dir" --prompt purpose-twice --purpose first --purpose second
expect_no_call '--purpose の2回目の指定'
expect_exit 2 '--purpose の値が無ければ拒否する' --directory "$work_dir" --prompt purpose-missing --purpose
expect_no_call '--purpose の値が無い'

pane_env=(-u TMUX_PANE)
AWT_TEST_MODE=success
AWT_TEST_SESSION=success
AWT_TEST_AGENT="$work_dir/agent"
rm -f "$work_dir/argv"

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

AWT_TEST_SESSION=short-lived-exec
AWT_TEST_AGENT="exec /bin/sh -c 'sleep 1; exit 1'"
sessions+=(short-lived-exec)
expect_exit 7 '短命の exec を Agent の起動と取り違えない' --directory "$work_dir" --prompt short
checked=$((checked + 1))
if T has-session -t '=short-lived-exec' 2>/dev/null; then
  ng '短命の exec の session が残っています'
else
  info 'OK: 短命の exec の session は消えた（cleanup の対象には残す）'
fi

AWT_TEST_SESSION=literal-command
AWT_TEST_AGENT=0x41
sessions+=(literal-command)
expect_exit 7 '16進数のキー表記を含む agentCommand を文字列として送る' --directory "$work_dir" --prompt x
checked=$((checked + 1))
if T capture-pane -p -t '=literal-command:' | rg -q -F "handoff> 0x41 'x'"; then
  info 'OK: pane に 0x41 が literal で届いた'
else
  ng 'pane に 0x41 が literal で届いていません'
fi

for shell_name in zsh fish; do
  if ! command -v "$shell_name" >/dev/null 2>&1; then
    if [[ "${CI:-}" == true ]]; then
      checked=$((checked + 1))
      ng "$shell_name がありません"
    else
      info "SKIP: $shell_name がありません"
    fi
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

AWT_TEST_MODE=missing-session
AWT_TEST_SESSION=gone
AWT_TEST_AGENT="$work_dir/agent"
sessions+=(gone-other)
T new-session -d -s gone-other -x 120 -y 24 \
  env PS1='handoff> ' AWT_TEST_ARGV="$work_dir/argv" /bin/bash --norc --noprofile -i
sleep 0.5
before=$(T capture-pane -p -t '=gone-other:')
expect_exit 5 '存在しない session の接頭辞が一致しても送らない' --directory "$work_dir" --prompt wrong-session
expect_unsent gone-other

AWT_TEST_MODE=changing-screen
AWT_TEST_SESSION=changing-screen
sessions+=(changing-screen)
expect_exit 5 'cursor が正でも画面が変わり続ける pane には送らない' --directory "$work_dir" --prompt changing-screen
checked=$((checked + 1))
cursor=$(T display-message -p -t '=changing-screen:' '#{cursor_x}')
if [[ "$cursor" =~ ^[0-9]+$ && "$cursor" -gt 0 ]]; then
  info 'OK: 変化する画面の cursor は0より大きい'
else
  ng '変化する画面の cursor が0より大きくありません'
fi
touch "$work_dir/screen-stop"
for ((attempt = 0; attempt < 50; attempt++)); do
  [[ ! -e "$work_dir/screen-stop.done" ]] || break
  sleep 0.1
done
checked=$((checked + 1))
if [[ -e "$work_dir/screen-stop.done" ]]; then
  info 'OK: 変化する画面の出力が止まった'
else
  ng '変化する画面の出力が止まりません'
fi
before=$(T capture-pane -p -t '=changing-screen:')
expect_unsent changing-screen

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
