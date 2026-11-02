#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: stop-tty-processes.sh [--dry-run] -L <socket名> <tty>...

計測用の pane の後始末 (Issue #540)。指定した tty の上のプロセスを pgid ごとに止め、
その tty の上にプロセスが 1 つも残っていないことを確かめる。

  1. tty の上のプロセスの pgid を全部列挙し、各 pgid へ SIGTERM を送る
  2. 0.5 秒待ち、まだ tty の上に残っている pgid へ SIGKILL を送る
  3. tty の上にプロセスが無いことを確かめる。残っていれば一覧を出して exit 1

止める前に次をすべて確かめ、1 つでも満たさなければ何も止めずに exit 2 で終わる。

  - -L の socket 名が既定 server を指さない (空・default (大文字小文字を問わない)・'/' を含む
    ものを拒否する。scripts/guard_bash_tmux.py の kill-session の判定と同じ規則)
  - 渡した各 tty が、その server の `list-panes -a -F '#{pane_tty}'` にある
  - 渡した各 tty が、このスクリプトの祖先 (自分から親を pid 1 まで辿る) の端末ではない
  - /dev/<tty> が存在する

<tty> は `#{pane_tty}` の値 (/dev/ttys006) でも ttys006 でもよい。呼ぶ tmux は list-panes
だけで、session を消すのは呼び出し側 (`kill-session -t '=<名前>'`) の仕事である。

  -L <socket名>  pane を作った隔離 server の socket 名 (必須)
  --dry-run      確かめた後、止める予定の pgid とプロセスを出すだけで何も止めない
  -h, --help     このヘルプを表示
EOF
}

dry_run=0
socket=""
socket_set=0
ttys=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -L)
      require_value -L "$#"
      socket="$2"
      socket_set=1
      shift 2
      ;;
    --)
      shift
      ttys+=("$@")
      break
      ;;
    -*) die "不明なオプションです: $1 (-h で使い方)" ;;
    *)
      ttys+=("$1")
      shift
      ;;
  esac
done

reasons=()
refuse() {
  reasons+=("$*")
}

# 既定 server を指す socket 名は、guard_bash_tmux.py の kill-session の判定と同じ規則で拒否する。
# APFS は socket 名の大文字小文字を区別しないので DEFAULT も既定 server に届き、'/' を含む値は
# socket ディレクトリからの相対パスとして解決される (どちらも guard の注釈の実測)。
socket_lower=$(printf '%s' "$socket" | tr '[:upper:]' '[:lower:]')
socket_ok=0
if [[ "$socket_set" -eq 0 ]]; then
  refuse "-L <socket名> がありません。pane を作った隔離 server の socket 名を渡してください"
elif [[ -z "$socket" || "$socket_lower" == "default" ]]; then
  refuse "-L '$socket' は既定 server を指します"
elif [[ "$socket" == */* ]]; then
  refuse "-L '$socket' にパス区切り '/' が含まれています (socket ディレクトリからの相対パスとして既定 server へ届きうる)"
else
  socket_ok=1
fi
[[ "${#ttys[@]}" -ge 1 ]] || refuse "tty を 1 つ以上指定してください"

names=()
for arg in ${ttys[@]+"${ttys[@]}"}; do
  tty="${arg#/dev/}"
  if [[ ! "$tty" =~ ^tty[A-Za-z0-9]+$ ]]; then
    refuse "tty の名前ではありません: '$arg'"
    continue
  fi
  names+=("$tty")
done

# 祖先の端末を拒否する。Bash ツールから呼ぶとこのスクリプト自身の tty は ?? だが、祖先の
# Claude Code と、それを動かすユーザーの shell は端末を持つ (実測: claude と fish が ttys015)。
# 自分の tty だけを見ると、ユーザーの端末を渡されても通してしまう。
ancestor_ttys=""
pid=$$
while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; do
  row=$(ps -o ppid=,tty=,comm= -p "$pid" 2>/dev/null || true)
  [[ -n "$row" ]] || break
  read -r ppid ptty pcomm <<<"$row"
  if [[ "$ptty" != "??" && "$ptty" != "?" ]]; then
    ancestor_ttys="$ancestor_ttys $ptty:$pid:$pcomm"
  fi
  pid="$ppid"
done

for tty in ${names[@]+"${names[@]}"}; do
  if [[ ! -c "/dev/$tty" ]]; then
    refuse "/dev/$tty がありません (存在しない tty)"
  fi
  for entry in $ancestor_ttys; do
    if [[ "${entry%%:*}" == "$tty" ]]; then
      rest="${entry#*:}"
      refuse "$tty はこのスクリプトの祖先 (pid ${rest%%:*} ${rest#*:}) の端末です"
    fi
  done
done

# pane の照合。pane が消えた後の tty の名前はすぐに再利用される (レビューアの計測: 7 つの隔離
# server が続けて ttys006 を受け取った) ので、今その server の pane のものであることを確かめる。
if [[ "$socket_ok" -eq 1 && "${#names[@]}" -ge 1 ]]; then
  if ! command -v tmux >/dev/null 2>&1; then
    refuse "tmux が見つからないので、-L $socket の pane と照合できません"
  elif ! pane_ttys=$(env -u TMUX tmux -L "$socket" list-panes -a -F '#{pane_tty}' 2>&1); then
    refuse "-L $socket の server の list-panes を読めません ($pane_ttys)"
  else
    for tty in ${names[@]+"${names[@]}"}; do
      if ! grep -Fxq "/dev/$tty" <<<"$pane_ttys"; then
        refuse "$tty は -L $socket の server の pane の tty ではありません"
      fi
    done
  fi
fi

if [[ "${#reasons[@]}" -gt 0 ]]; then
  info "何も止めません:"
  for reason in "${reasons[@]}"; do
    info "  - $reason"
  done
  exit 2
fi

# pid pgid tty の一覧から、指定した tty の上の行だけを出す。
# `ps -t` でも絞れるが (実測 macOS 27: ttys006 / s006 / /dev/ttys006 のどれも効いた)、
# `pgrep -t` は同じ綴りで何も返さなかったので、ps の全体を自分で絞る形に揃える。
on_ttys() {
  ps -A -o pid=,pgid=,tty=,args= | awk -v list="${names[*]}" -v self=$$ '
    BEGIN { n = split(list, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    $1 != self && ($3 in want) { print }'
}

pgids_on_ttys() {
  on_ttys | awk '{print $2}' | sort -un
}

if [[ "$dry_run" -eq 1 ]]; then
  info "--dry-run: 確かめた結果は問題ありません。止める予定の pgid: $(pgids_on_ttys | tr '\n' ' ')"
  info "tty の上のプロセス (pid pgid tty args):"
  info "$(on_ttys)"
  exit 0
fi

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
  info "tty の上にまだプロセスが残っています (pid pgid tty args):"
  info "$left"
  exit 1
fi
info "tty の上にプロセスはありません: ${names[*]}"
