#!/usr/bin/env bash
#
# Gate 1 PoC (M2) — tmux attach 検証ハーネス
#
#   scripts/m2-harness.sh launch [WxH]   スパイクアプリを起動して gate1-spike に attach
#   scripts/m2-harness.sh ctl '<cmd>'    アプリの制御チャネルへコマンドを送る
#   scripts/m2-harness.sh shot <name>    ウィンドウのみを evidence/m2-<name>.png へ
#   scripts/m2-harness.sh log [n]        アプリのログ末尾
#   scripts/m2-harness.sh winid          ウィンドウ番号 (CGWindowID)
#   scripts/m2-harness.sh stop           アプリ終了 (tmux セッションは残す)
#   scripts/m2-harness.sh teardown       アプリ終了 + tmux サーバ破棄
#
# 方針:
#   - **専用の tmux サーバソケット `-L gate1-spike` を使う。**
#     ユーザーの既定サーバには一切触れない。`tmux set -g ...` を撃っても
#     ユーザーの digi-plus / personal 等のセッションに波及しない。
#     `~/.tmux.conf` は読み込むので設定内容は本番同等。
#   - キー・マウスは `TERMINAL_SPIKE_CONTROL` 経由でアプリ内から libghostty の
#     入力 API を直接叩く。この環境には cliclick もアクセシビリティ権限も無く、
#     CGEvent / System Events による物理入力の合成ができないため。
#
set -uo pipefail

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${SPIKE_DIR}/build/TerminalSpike.app/Contents/MacOS/TerminalSpike"
EV="${SPIKE_DIR}/evidence"
RUN="${M2_RUN_DIR:-${TMPDIR:-/tmp}/gate1-m2}"
CTL="${RUN}/ctl"
LOG="${RUN}/app.log"
SOCK=gate1-spike
SESSION=gate1-spike

mkdir -p "${RUN}" "${EV}"

t() { tmux -L "${SOCK}" "$@"; }
naptime() { perl -e "select(undef,undef,undef,$1)"; }

case "${1:-}" in
launch)
  size="${2:-1100x700}"
  w="${size%x*}"; h="${size#*x}"
  rm -f "${CTL}"; : > "${CTL}"; : > "${LOG}"
  TERMINAL_SPIKE_COMMAND="tmux -L ${SOCK} new-session -A -s ${SESSION}" \
  TERMINAL_SPIKE_CONTROL="${CTL}" \
  nohup "${APP}" > "${LOG}" 2>&1 &
  echo "app pid=$!"
  for _ in $(seq 1 40); do
    t has-session -t "${SESSION}" 2>/dev/null && break
    naptime 0.25
  done
  naptime 1.0
  echo "resize ${w} ${h}" >> "${CTL}"
  naptime 0.8
  t list-clients -F 'client #{client_name} term=#{client_termname} size=#{client_width}x#{client_height}'
  ;;
ctl)
  shift
  printf '%s\n' "$@" >> "${CTL}"
  naptime 0.5
  ;;
winid)
  echo 'report winid' >> "${CTL}"; naptime 0.5
  grep -o 'window=[0-9]*' "${LOG}" | tail -1 | cut -d= -f2
  ;;
shot)
  id="$(grep -o 'window=[0-9]*' "${LOG}" | tail -1 | cut -d= -f2)"
  if [ -z "${id}" ]; then echo 'report shot' >> "${CTL}"; naptime 0.6
     id="$(grep -o 'window=[0-9]*' "${LOG}" | tail -1 | cut -d= -f2)"; fi
  [ -n "${id}" ] || { echo "no window id" >&2; exit 1; }
  screencapture -x -o -l "${id}" "${EV}/m2-${2}.png"
  echo "${EV}/m2-${2}.png"
  ;;
log)
  tail -n "${2:-40}" "${LOG}"
  ;;
stop)
  echo 'quit' >> "${CTL}" 2>/dev/null || true
  naptime 1.0
  pkill -f 'TerminalSpike.app/Contents/MacOS/TerminalSpike' 2>/dev/null || true
  ;;
teardown)
  "${BASH_SOURCE[0]}" stop
  t kill-server 2>/dev/null || true
  echo "torn down"
  ;;
*)
  sed -n '2,30p' "${BASH_SOURCE[0]}"
  ;;
esac
