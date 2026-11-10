#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

[[ $# -eq 0 ]] || die "引数は指定できません"
require_cmd tmux python3 git

HOOK="$SCRIPT_DIR/../plugins/awt-handoff/hooks/session-start.sh"
CONFIG="$SCRIPT_DIR/../plugins/awt-handoff/hooks/hooks.json"
STOP="$SCRIPT_DIR/stop-tty-processes.sh"
SOCK="awt-handoff-hook-$$-$RANDOM"
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

ng() {
  info "NG: $*"
  failures=$((failures + 1))
}

checked=$((checked + 1))
if python3 -I - "$CONFIG" "$HOOK" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
entries = config["hooks"]["SessionStart"]
assert len(entries) == 1
assert "matcher" not in entries[0]
assert entries[0]["hooks"] == [{
    "type": "command",
    "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh",
    "timeout": 10,
}]
assert os.path.isfile(sys.argv[2]) and os.access(sys.argv[2], os.X_OK)
PY
then
  info 'OK: SessionStart の設定と hook の実行権'
else
  ng 'SessionStart の設定または hook の実行権が期待と異なります'
fi

cat >"$work_dir/hostctl" <<'HOSTCTL'
#!/usr/bin/env bash
printf 'called\n' >>"$(dirname -- "$0")/calls"
exit 1
HOSTCTL
chmod +x "$work_dir/hostctl"

T -f /dev/null new-session -d -s anchor -x 120 -y 24 /bin/sleep 600
socket_path=$(T display-message -p '#{socket_path}')
[[ -n "$socket_path" ]] || die "隔離 server の socket path が読めません"
T set-environment -g AWT_HOSTCTL "$work_dir/hostctl"
T set-environment -g AWT_HOSTCTL_SOCKET test-socket

git -c init.defaultBranch=main init -q "$work_dir/project"
git -C "$work_dir/project" -c user.name='Handoff Hook Test' -c user.email=hook@example.invalid \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m 'test fixture'
git -C "$work_dir/project" worktree add -q -b linked "$work_dir/linked"
git init -q --bare "$work_dir/bare"
mkdir -p "$work_dir/project/subdir" "$work_dir/linked/subdir" "$work_dir/outside"

: >"$work_dir/empty"
printf '%s\n' 'このセッションは Agent Workflow Terminal の Project Root で動いている。実装を指示されたら、作業を始める前に awt-handoff:worktree-handoff Skill を使う。調査や質問には使わない。' >"$work_dir/instruction"
printf '\377\000not JSON\n' >"$work_dir/broken-input"

expect_hook() {
  local label="$1" directory="$2" expected="$3" input="${4:-$work_dir/input}"
  local rc=0
  python3 -I - "$directory" >"$work_dir/input" <<'PY'
import json
import sys

print(json.dumps({"hook_event_name": "SessionStart", "source": "startup", "cwd": sys.argv[1]}))
PY
  (
    cd -- "$directory" || exit 1
    env TMUX="$socket_path,0,0" AWT_HOSTCTL=/missing/hostctl AWT_HOSTCTL_SOCKET=wrong-socket \
      GIT_CEILING_DIRECTORIES="$work_dir" "$HOOK" <"$input"
  ) >"$work_dir/stdout" 2>"$work_dir/stderr" || rc=$?

  checked=$((checked + 1))
  if [[ "$rc" -eq 0 && ! -s "$work_dir/stderr" ]] && cmp -s "$expected" "$work_dir/stdout"; then
    info "OK: $label"
  else
    ng "$label: exit ${rc}、stdout または stderr が期待と異なります"
    cat "$work_dir/stdout" "$work_dir/stderr"
  fi
}

expect_hook 'git の外では出力しない' "$work_dir/outside" "$work_dir/empty"
expect_hook 'linked worktree のルートでは出力しない' "$work_dir/linked" "$work_dir/empty"
expect_hook 'linked worktree のサブディレクトリでは出力しない' "$work_dir/linked/subdir" "$work_dir/empty"

T set-environment -gu AWT_HOSTCTL
expect_hook '窓口が使えない Project Root では出力しない' "$work_dir/project" "$work_dir/empty"
T set-environment -g AWT_HOSTCTL "$work_dir/hostctl"

expect_hook 'Project Root のルートでは指示を出力する' "$work_dir/project" "$work_dir/instruction"
expect_hook 'Project Root のサブディレクトリでは指示を出力する' "$work_dir/project/subdir" "$work_dir/instruction"
expect_hook '壊れた stdin でも指示を出力する' "$work_dir/project" "$work_dir/instruction" "$work_dir/broken-input"
expect_hook 'bare リポジトリの中では出力しない' "$work_dir/bare" "$work_dir/empty"

checked=$((checked + 1))
if [[ -e "$work_dir/calls" ]]; then
  ng 'hostctl が呼ばれました'
else
  info 'OK: hostctl は一度も呼ばれない'
fi

[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
__awt_finished=1
