#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: stop-tty-processes.sh <tty>...

計測用の pane の後始末 (Issue #540)。指定した tty の上のプロセスを pgid ごとに止め、
その tty の上にプロセスが 1 つも残っていないことを確かめる。

  1. tty の上のプロセスの pgid を全部列挙し、各 pgid へ SIGTERM を送る
  2. 0.5 秒待ち、まだ tty の上に残っている pgid へ SIGKILL を送る
  3. tty の上にプロセスが無いことを確かめる。残っていれば一覧を出して exit 1

<tty> は `#{pane_tty}` の値 (/dev/ttys006) でも ttys006 でもよい。

**tmux の session を消す前に、自分が作った pane の tty だけを渡すこと。** pane が消えた後の
tty の名前は、別の端末に再利用されうる。このスクリプトは tmux を呼ばず、tty の持ち主も
確かめない。渡す直前に、同じ `-L` の server の `list-panes -a -F '#{pane_tty}'` に
その tty がまだあることを確かめる。

  -h, --help  このヘルプを表示
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -ge 1 ]] || die "tty を 1 つ以上指定してください (-h で使い方)"

own_tty=$(ps -o tty= -p $$ | tr -d ' ')
ttys=()
for arg in "$@"; do
  tty="${arg#/dev/}"
  [[ "$tty" =~ ^tty[A-Za-z0-9]+$ ]] || die "tty の名前ではありません: $arg"
  # 自分の端末を渡すと、呼び出した shell ごと止める。
  [[ "$tty" != "$own_tty" ]] || die "このスクリプト自身の端末は指定できません: $arg"
  ttys+=("$tty")
done

# pid pgid tty の一覧から、指定した tty の上の行だけを出す。
# `ps -t` でも絞れるが (実測 macOS 27: ttys006 / s006 / /dev/ttys006 のどれも効いた)、
# `pgrep -t` は同じ綴りで何も返さなかったので、ps の全体を自分で絞る形に揃える。
on_ttys() {
  ps -A -o pid=,pgid=,tty= | awk -v list="${ttys[*]}" -v self=$$ '
    BEGIN { n = split(list, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    $1 != self && ($3 in want) { print $1, $2, $3 }'
}

pgids_on_ttys() {
  on_ttys | awk '{print $2}' | sort -un
}

signal_pgids() {
  local sig="$1" pgid
  for pgid in $(pgids_on_ttys); do
    info "kill -$sig -- -$pgid"
    kill "-$sig" -- "-$pgid" 2>/dev/null || true
  done
}

signal_pgids TERM
sleep 0.5
if [[ -n "$(on_ttys)" ]]; then
  signal_pgids KILL
  sleep 0.2
fi

left=$(on_ttys)
if [[ -n "$left" ]]; then
  info "tty の上にまだプロセスが残っています (pid pgid tty):"
  info "$left"
  exit 1
fi
info "tty の上にプロセスはありません: ${ttys[*]}"
