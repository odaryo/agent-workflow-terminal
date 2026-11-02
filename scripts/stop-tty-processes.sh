#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: stop-tty-processes.sh [--dry-run] -L <socket名> <tty>...

計測用の pane の後始末 (Issue #540)。指定した tty の上のプロセスを pgid ごとに止め、
最初に数えたプロセスがすべて止まったことを確かめる。

  1. tty の上のプロセスを数え、pid・pgid・開始時刻を記録する。記録した pgid へ SIGTERM を送る
  2. 0.5 秒待ち、記録したプロセスのうち同じ開始時刻でまだ生きているものの pgid へ SIGKILL を送る
     (別の group へ移ったものは、その pid だけへ送る)
  3. 記録したプロセスがすべて消えたことを確かめる。残っていれば一覧を出して exit 1
  4. 記録した pgid に記録に無いプロセスがいれば、止めずに一覧で出して exit 1。TERM の後に
     fork した子 (tty を失っていることがある) でありうるが、group が空になった後に番号が
     再利用された可能性を除外できないため、撃たない。自分が作ったと確かめてから止める
  5. tty の上に記録に無いプロセスがいれば、止めずに一覧で出す (それだけなら exit 0)。待ちの
     間に pane が閉じると、別の server の新しい pane が同じ tty を受け取りうるため、数え直して
     撃たない

宛先の判定は scripts/stop_tty_targets.py が行う (python3 が要る)。

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

環境変数 AWT_STOP_TTY_GRACE_SECONDS で 2 の待ち (既定 0.5、0〜10 秒) を変えられる。検査で
tty の再利用を起こすための口で、ふだんは使わない。
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

# 宛先の判定 (stop_tty_targets.py) は python3 で動く。
TARGETS="$SCRIPT_DIR/stop_tty_targets.py"
if ! command -v python3 >/dev/null 2>&1; then
  refuse "python3 が見つからないので、止める宛先を判定できません"
elif [[ ! -x "$TARGETS" ]]; then
  refuse "宛先の判定のスクリプトが実行可能ではありません: $TARGETS"
fi

# TERM と KILL の間の待ち。検査で tty の再利用を起こすためだけに延ばせる。
grace="${AWT_STOP_TTY_GRACE_SECONDS:-0.5}"
if [[ ! "$grace" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! awk -v g="$grace" 'BEGIN { exit !(g <= 10) }'; then
  refuse "AWT_STOP_TTY_GRACE_SECONDS は 0〜10 の秒数にしてください: '$grace'"
fi

if [[ "${#reasons[@]}" -gt 0 ]]; then
  info "何も止めません:"
  for reason in "${reasons[@]}"; do
    info "  - $reason"
  done
  exit 2
fi

# tty で絞るのは stop_tty_targets.py の側。`ps -t` でも絞れるが (実測 macOS 27: ttys006 / s006 /
# /dev/ttys006 のどれも効いた)、`pgrep -t` は同じ綴りで何も返さなかったので、ps の全体を取る。
# 全体を取るのは、tty を失った子を pgid で探すためでもある (#573)。
snapshot() {
  LC_ALL=C ps -A -o pid=,pgid=,tty=,lstart=,args=
}

# 宛先の判定は stop_tty_targets.py に置く。pid の再利用や group の移動は実プロセスでは起こせない
# ので、判定は scripts/check-stop-tty-targets.sh が ps の fixture で検査する (Issue #573)。ps を
# 差し替える口をこのスクリプトに作らないため、判定にだけ断面を文字列で渡す。
judge() {
  "$TARGETS" --self $$ --recorded <(printf '%s\n' "$recorded_snapshot") \
    --now <(printf '%s\n' "$1") "${names[@]}"
}

# judge の出力から、$1 の種類の行を、種類の語を外して出す。
section() {
  awk -v kind="$1" '$1 == kind { sub(/^[^ ]+ /, ""); print }' <<<"$2"
}

# 止める対象は、最初に数えたプロセスに固定する。TERM の後の待ちの間に pane が閉じて tty が
# 空くと、別の server の新しい pane が同じ tty を受け取る (実測: 隔離 server A を止めている
# 0.2 秒後に立てた C が ttys006 を受け取り、数え直していた版は C を SIGKILL した、#540)。
recorded_snapshot=$(snapshot)
if ! plan=$(judge "$recorded_snapshot"); then
  info "ps の出力を判定できないので、何も止めません"
  exit 2
fi
recorded=$(section recorded "$plan")

if [[ "$dry_run" -eq 1 ]]; then
  info "--dry-run: 確かめた結果は問題ありません。止める予定の pgid: $(section target "$plan" | sed 's/^-//' | tr '\n' ' ')"
  info "tty の上のプロセス (pid pgid tty 開始時刻 args):"
  info "$recorded"
  exit 0
fi

while read -r target; do
  [[ -n "$target" ]] || continue
  info "kill -TERM -- $target"
  kill -TERM -- "$target" 2>/dev/null || true
done <<<"$(section target "$plan")"
sleep "$grace"

if ! plan=$(judge "$(snapshot)"); then
  info "ps の出力を判定できないので、SIGKILL を送らずに終わります。止まったかどうかは確かめていません"
  exit 1
fi
kill_targets=$(section target "$plan")
if [[ -n "$kill_targets" ]]; then
  while read -r target; do
    [[ -n "$target" ]] || continue
    info "kill -KILL -- $target"
    kill -KILL -- "$target" 2>/dev/null || true
  done <<<"$kill_targets"
  sleep 0.2
fi

if ! plan=$(judge "$(snapshot)"); then
  info "ps の出力を判定できないので、止まったかどうかを確かめられません"
  exit 1
fi
status=0
left=$(section alive "$plan")
if [[ -n "$left" ]]; then
  info "最初に数えたプロセスがまだ残っています (pid 記録した pgid 今の pgid):"
  info "$left"
  status=1
else
  info "最初に数えたプロセスはすべて止まりました: ${names[*]}"
fi

# 記録した pgid に、記録に無いプロセスがいる。TERM の trap の中で fork した子は記録の後に
# 生まれ、pane が閉じると tty を失うので、tty の上だけを見ていると見逃す (#573 の m5)。
# 撃たないのは、group が空になった後に同じ番号が別の group に再利用された可能性を、ここからは
# 除外できないため。
group_strays=$(section group "$plan")
if [[ -n "$group_strays" ]]; then
  info "記録した process group に、記録の後に生まれたプロセスが残っています (TERM の後に fork した子の可能性)。止めていません。自分が作ったと確かめてから、kill -TERM -- -<pgid> を送り、0.5 秒待って残っていれば kill -KILL -- -<pgid> を送って止めてください (TERM を受け流す子がいる)。最後に ps で、その pgid のプロセスが無いことを確かめてください (pid pgid tty 開始時刻 args):"
  info "$group_strays"
  status=1
fi

# 確認の後に tty の上にいるもので、記録した pgid にいないものは、記録に無い別物として扱い、
# 止めない。pane の子が後から別の group で生まれた場合もここに出る。
others=$(section tty "$plan")
if [[ -n "$others" ]]; then
  info "記録に無いプロセスが tty の上にいます (tty が再利用された可能性)。止めていません (pid pgid tty 開始時刻 args):"
  info "$others"
fi
exit "$status"
