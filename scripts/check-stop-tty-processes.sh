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

加えて --dry-run が何も止めないこと、正しく渡せば pane の tty の上のプロセスが止まること、
止めている途中に tty が別の server の pane に再利用されても、その新しい持ち主を止めずに一覧で
出すことを確かめる (AWT_STOP_TTY_GRACE_SECONDS で TERM と KILL の間を延ばして再利用を起こす。
同じ tty を受け取れなかったときは「飛ばした」と出す)。TERM の trap の中で子を fork して終わる
偽エージェントでは、その子を記録した pgid に残るものとして撃たずに一覧に出し、exit 1 で終わる
ことを確かめる (子は検査の最後に止める)。隔離 server は `-L awt-stoptty-*` で立て、最後に session を名前で消して socket を消す
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
SOCK_REUSE_A="awt-stoptty-reuse-a-$$"
SOCK_REUSE_C="awt-stoptty-reuse-c-$$"
SOCK_FORK="awt-stoptty-fork-$$"
socket_dir="${TMUX_TMPDIR:-/private/tmp}/tmux-$(id -u)"
work_dir=$(mktemp -d)

T() { env -u TMUX tmux -L "$SOCK" "$@"; }
T2() { env -u TMUX tmux -L "$SOCK2" "$@"; }

# TERM の後に fork した子 (下の検査で作る) が残っていれば止める。止めるのは、pgid が pane の
# pid で、args がこの検査の作った偽エージェントのものに限る。子は TERM も HUP も受け流すので KILL。
stop_forked_children() {
  local pid
  [[ -n "$fork_pgid" ]] || return 0
  for pid in $(ps -A -o pid=,pgid=,args= |
    awk -v g="$fork_pgid" -v f="$fork_agent" '$2 == g && index($0, f) { print $1 }'); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

cleanup() {
  local sock name
  stop_forked_children
  for sock in "$SOCK" "$SOCK2" "$SOCK_REUSE_A" "$SOCK_REUSE_C" "$SOCK_FORK"; do
    for name in target inpane other a c fork; do
      env -u TMUX tmux -L "$sock" kill-session -t "=$name" >/dev/null 2>&1 || true
    done
    # server が止まったと確かめられたときだけ socket を消す (統合テストと同じ設計)。
    if ! env -u TMUX tmux -L "$sock" list-sessions >/dev/null 2>&1; then
      rm -f "$socket_dir/$sock"
    fi
  done
  rm -rf "$work_dir"
}

fork_pgid=""
fork_agent="$work_dir/fork-agent.sh"

# bash 3.2 は EXIT の trap があると、set -u の未定義の変数の参照で止まっても exit 0 を返す。
# 最後まで走った印が無ければ非 0 で終わらせる (docs/coding-guidelines.md §7)。
__awt_finished=0
__awt_on_exit() {
  local rc=$?
  cleanup
  [[ $__awt_finished -eq 1 || $rc -ne 0 ]] || rc=1
  exit "$rc"
}
trap __awt_on_exit EXIT

failures=0
checked=0
skipped=0

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
AWT_STOP_TTY_GRACE_SECONDS=11 expect_refused "AWT_STOP_TTY_GRACE_SECONDS" -L "$SOCK" "$target_tty"
AWT_STOP_TTY_GRACE_SECONDS=abc expect_refused "AWT_STOP_TTY_GRACE_SECONDS" -L "$SOCK" "$target_tty"

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

# 止めている途中に tty が再利用される形 (#540 のレビュー M-B)。A の pane を止める TERM の後の
# 待ちの間に A の pane が閉じて tty が空き、別の server C の新しい pane が同じ tty を受け取る。
# 待ちの後に数え直すと C を SIGKILL する。最初に数えたものだけを撃つなら C は生き残り、
# 「記録に無いプロセス」として一覧に出る。
# 既定の待ち (0.5 秒) での再利用の窓は固定しない (#577)。窓の大きさは TERM から pane が閉じるまでの
# 時間 (Python の起動を含む) と tty の割り当ての順で決まり、runner で安定して再現できない。安全性は
# 待ちの長さによらず「記録したものにだけ KILL を送る」ことで決まり、それを待ち 3 秒のこの検査で固定する。
info "--- 止めている途中に tty が再利用される"
checked=$((checked + 1))
env -u TMUX tmux -L "$SOCK_REUSE_A" -f /dev/null new-session -d -s a -x 80 -y 24 "sleep 600"
reuse_a_tty=$(pane_tty_of "$SOCK_REUSE_A" a)
reuse_a_pid=$(env -u TMUX tmux -L "$SOCK_REUSE_A" list-panes -t '=a' -F '#{pane_pid}')
reuse_out="$work_dir/reuse.out"
AWT_STOP_TTY_GRACE_SECONDS=3 "$STOP" -L "$SOCK_REUSE_A" "$reuse_a_tty" >"$reuse_out" 2>&1 &
reuse_stop=$!
for _ in $(seq 1 30); do
  alive "$reuse_a_pid" || break
  sleep 0.1
done
env -u TMUX tmux -L "$SOCK_REUSE_C" -f /dev/null new-session -d -s c -x 80 -y 24 "sleep 600"
reuse_c_tty=$(pane_tty_of "$SOCK_REUSE_C" c)
reuse_c_pid=$(env -u TMUX tmux -L "$SOCK_REUSE_C" list-panes -t '=c' -F '#{pane_pid}')
reuse_rc=0
wait "$reuse_stop" || reuse_rc=$?
if [[ "$reuse_c_tty" != "$reuse_a_tty" ]]; then
  info "SKIP (飛ばした): C が A と同じ tty を受け取らなかった (A: $reuse_a_tty / C: $reuse_c_tty)"
  skipped=$((skipped + 1))
elif [[ "$reuse_rc" -eq 0 ]] && alive "$reuse_c_pid" &&
  grep -q "記録に無いプロセス" "$reuse_out" && grep -q "^$reuse_c_pid " "$reuse_out" &&
  ! grep -q -- "-$reuse_c_pid\$" "$reuse_out"; then
  info "OK (exit 0・C (${reuse_c_pid}、$reuse_c_tty) は生きていて、記録に無いプロセスとして出た): 再利用"
else
  ng "tty を再利用した C の扱いが期待と異なる (exit ${reuse_rc}・C: $(alive "$reuse_c_pid" && echo 生存 || echo 停止))"
  info "$(cat "$reuse_out")"
fi

# TERM の trap の中で子を fork して終わる偽エージェント (#573 の m5、レビューアの偽エージェントと
# 同じ形)。子は記録の後に生まれ、pane が閉じると tty を失うので、tty の上だけを見ると見逃す。
# 記録した pgid に残る記録外のプロセスとして一覧に出し、撃たずに exit 1 で終わることを確かめる。
info "--- TERM の後に fork した子が記録した pgid に残る"
checked=$((checked + 1))
cat >"$fork_agent" <<'AGENT'
trap '' HUP
trap '( trap "" HUP TERM; while :; do read -r -t 1 x; done ) & exit 0' TERM
while :; do sleep 0.2; done
AGENT
env -u TMUX tmux -L "$SOCK_FORK" -f /dev/null new-session -d -s fork -x 80 -y 24 \
  "exec bash $(printf '%q' "$fork_agent")"
fork_tty=$(pane_tty_of "$SOCK_FORK" fork)
fork_pgid=$(env -u TMUX tmux -L "$SOCK_FORK" list-panes -t '=fork' -F '#{pane_pid}')
fork_rc=0
fork_out=$("$STOP" -L "$SOCK_FORK" "$fork_tty" 2>&1) || fork_rc=$?
fork_children=$(ps -A -o pid=,pgid=,args= |
  awk -v g="$fork_pgid" -v f="$fork_agent" '$2 == g && index($0, f) { print $1 }')
fork_listed=1
[[ -n "$fork_children" ]] || fork_listed=0
for pid in $fork_children; do
  grep -q "^$pid $fork_pgid " <<<"$fork_out" || fork_listed=0
done
if [[ "$fork_rc" -eq 1 && "$fork_listed" -eq 1 && "$fork_out" == *"記録した process group に"* ]] &&
  ! grep -q -- "^kill -KILL" <<<"$fork_out"; then
  info "OK (exit 1・子 ($(echo "$fork_children" | tr '\n' ' ')) は pgid $fork_pgid に残っていて一覧に出た): TERM の後の fork"
else
  ng "TERM の後に fork した子の扱いが期待と異なる (exit ${fork_rc}・pgid $fork_pgid の子: ${fork_children:-無し})"
  info "$fork_out"
fi
stop_forked_children

info ""
[[ "$skipped" -eq 0 ]] || info "飛ばした検査が $skipped 件あります"
[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
__awt_finished=1
