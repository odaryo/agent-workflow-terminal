#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: check-stop-tty-processes.sh

scripts/stop-tty-processes.sh (計測用の pane の後始末、Issue #540) を、隔離した tmux server を
立てて検査する。次の形で、何も止めずに非 0 で終わることを確かめる:

  -L が無い / -L default・DEFAULT / socket 名に '/' を含む / server が無い /
  tty がその server の pane に無い / 存在しない tty / 祖先の tty (pane の中から自分の tty を渡す)

加えて --dry-run が何も止めないことと、正しく渡せば pane の tty の上のプロセスが止まることを
確かめる。隔離 server は `-L awt-stoptty-*` で立て、最後に session を名前で消して socket を消す
(scripts/check-integration-leftovers.sh が残りを検出する)。tmux が要る。

  -h, --help  このヘルプを表示
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || die "引数は指定できません"

require_cmd tmux

STOP="$SCRIPT_DIR/stop-tty-processes.sh"
[[ -x "$STOP" ]] || die "後始末のスクリプトが実行可能ではありません: $STOP"

SOCK="awt-stoptty-$$"
SOCK2="awt-stoptty-other-$$"
SOCK_NONE="awt-stoptty-none-$$"
socket_dir="${TMUX_TMPDIR:-/private/tmp}/tmux-$(id -u)"
work_dir=$(mktemp -d)

T() { env -u TMUX tmux -L "$SOCK" "$@"; }
T2() { env -u TMUX tmux -L "$SOCK2" "$@"; }

cleanup() {
  local sock name
  for sock in "$SOCK" "$SOCK2"; do
    for name in target inpane other; do
      env -u TMUX tmux -L "$sock" kill-session -t "=$name" >/dev/null 2>&1 || true
    done
    # server が止まったと確かめられたときだけ socket を消す (統合テストと同じ設計)。
    if ! env -u TMUX tmux -L "$sock" list-sessions >/dev/null 2>&1; then
      rm -f "$socket_dir/$sock"
    fi
  done
  rm -rf "$work_dir"
}

# bash 3.2 (macOS の /bin/bash) は、EXIT の trap があると set -u の unbound variable で exit 0 を
# 返す (実測)。最後まで走ったかどうかを印で持ち、途中で止まったら失敗にする。
finished=0
trap 'cleanup; [[ $finished -eq 1 ]] || exit 1' EXIT

failures=0
checked=0

ng() {
  info "NG: $*"
  failures=$((failures + 1))
}

# $1 = 期待する理由の一部 (空なら問わない)、残り = stop-tty-processes.sh の引数
expect_refused() {
  local want="$1" out rc=0
  shift
  checked=$((checked + 1))
  out=$("$STOP" "$@" 2>&1) || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ng "受け付けた (期待: 非 0): $*"
    info "$out"
  elif [[ -n "$want" && "$out" != *"$want"* ]]; then
    ng "exit $rc だが理由に「${want}」が無い: $*"
    info "$out"
  else
    info "OK (exit $rc): $*"
  fi
}

pane_tty_of() {
  env -u TMUX tmux -L "$1" list-panes -t "=$2" -F '#{pane_tty}'
}

alive() {
  ps -p "$1" >/dev/null 2>&1
}

info "--- 隔離 server を立てる"
T -f /dev/null new-session -d -s target -x 80 -y 24 "sleep 600"
T2 -f /dev/null new-session -d -s other -x 80 -y 24 "sleep 600"
target_tty=$(pane_tty_of "$SOCK" target)
target_pid=$(T list-panes -t '=target' -F '#{pane_pid}')
other_tty=$(pane_tty_of "$SOCK2" other)
info "target: pid $target_pid $target_tty (-L $SOCK) / other: $other_tty (-L $SOCK2)"

# 存在しない tty の名前。/dev に無いことを確かめてから使う。
missing_tty=""
for n in $(seq 990 999); do
  if [[ ! -e "/dev/ttys$n" ]]; then
    missing_tty="ttys$n"
    break
  fi
done
[[ -n "$missing_tty" ]] || die "存在しない tty の名前を作れません (/dev/ttys990〜999 が全部ある)"

info "--- 拒否されること (何も止めない)"
expect_refused "-L <socket名> がありません" "$target_tty"
expect_refused "既定 server を指します" -L default "$target_tty"
expect_refused "既定 server を指します" -L DEFAULT "$target_tty"
expect_refused "既定 server を指します" -L "" "$target_tty"
expect_refused "'/' が含まれています" -L "a/$SOCK" "$target_tty"
expect_refused "'/' が含まれています" -L ./default "$target_tty"
expect_refused "list-panes を読めません" -L "$SOCK_NONE" "$target_tty"
expect_refused "pane の tty ではありません" -L "$SOCK" "$other_tty"
expect_refused "存在しない tty" -L "$SOCK" "$missing_tty"
expect_refused "tty の名前ではありません" -L "$SOCK" "??"
expect_refused "tty を 1 つ以上" -L "$SOCK"
expect_refused "" -L

# 祖先の tty。pane の中で動く shell から、その pane 自身の tty を渡す。tty はその server の pane に
# あり存在もするので、拒否されるなら祖先の判定による。CI の runner では Bash の祖先が端末を
# 持たないので、端末を持つ祖先をここで作る。
checked=$((checked + 1))
inpane_out="$work_dir/inpane.out"
# $(tty) と $? は pane の中の shell で展開させるので、ここでは引用したまま渡す。
# shellcheck disable=SC2016
inpane_cmd=$(printf '%q -L %q "$(tty)" >%q 2>&1; echo "rc=$?" >>%q; sleep 600' \
  "$STOP" "$SOCK" "$inpane_out" "$inpane_out")
T new-session -d -s inpane -x 80 -y 24 "bash -c $(printf '%q' "$inpane_cmd")"
inpane_pid=$(T list-panes -t '=inpane' -F '#{pane_pid}')
for _ in $(seq 1 50); do
  grep -q '^rc=' "$inpane_out" 2>/dev/null && break
  sleep 0.1
done
inpane_result=$(cat "$inpane_out" 2>/dev/null || true)
if [[ "$inpane_result" == *"rc=2"* && "$inpane_result" == *"祖先"* ]] && alive "$inpane_pid"; then
  info "OK (exit 2・pane の shell は生きている): pane の中から自分の tty を渡すと祖先として拒否する"
else
  ng "pane の中から自分の tty を渡したときの結果が期待と異なる (pane の shell: $(alive "$inpane_pid" && echo 生存 || echo 停止))"
  info "$inpane_result"
fi

checked=$((checked + 1))
if alive "$target_pid"; then
  info "OK: 拒否の間、target の pane のプロセス ($target_pid) は止まっていない"
else
  ng "拒否したはずなのに target の pane のプロセス ($target_pid) が止まった"
fi

info "--- --dry-run は何も止めない"
checked=$((checked + 1))
dry_rc=0
dry_out=$("$STOP" --dry-run -L "$SOCK" "$target_tty" 2>&1) || dry_rc=$?
if [[ "$dry_rc" -eq 0 && "$dry_out" == *"止める予定の pgid: $target_pid "* ]] && alive "$target_pid"; then
  info "OK (exit 0・止める予定に pgid ${target_pid}・プロセスは生きている): --dry-run"
else
  ng "--dry-run の結果が期待と異なる (exit $dry_rc)"
  info "$dry_out"
fi

info "--- 正しく渡せば止まる"
checked=$((checked + 1))
stop_rc=0
stop_out=$("$STOP" -L "$SOCK" "$target_tty" 2>&1) || stop_rc=$?
if [[ "$stop_rc" -eq 0 ]] && ! alive "$target_pid" &&
  [[ -z "$(ps -A -o tty= | awk -v t="${target_tty#/dev/}" '$1==t')" ]]; then
  info "OK (exit 0): target の tty の上にプロセスは無い"
else
  ng "正しく渡したのに止まらない (exit $stop_rc)"
  info "$stop_out"
fi

finished=1
info ""
[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
