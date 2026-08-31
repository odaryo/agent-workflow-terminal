#!/usr/bin/env bash
#
# Gate 1 PoC (M3) — Agent TUI / VT互換性 / 日本語・絵文字 検証ハーネス
#
# M2 の `m2-harness.sh` をそのまま再利用し (専用ソケット `-L gate1-spike` +
# `TERMINAL_SPIKE_CONTROL` 制御チャネル)、M3 で必要になった操作だけを足す。
#
#   scripts/m3-harness.sh launch [WxH]        起動して gate1-spike に attach
#   scripts/m3-harness.sh launch-bare [WxH]   tmux を挟まず bash を直接起動する
#                                             (tmux と libghostty の grapheme 処理の切り分け用)
#   scripts/m3-harness.sh ctl '<cmd>' ...     制御チャネルへコマンド (m2 と同じ)
#                                             M3 追加: preedit / ime / keydown
#   scripts/m3-harness.sh shot <name>         evidence/m3-<name>.png (撮れるまで3回リトライ)
#   scripts/m3-harness.sh log [n]             アプリログ末尾
#   scripts/m3-harness.sh tmux <args...>      gate1-spike サーバへ tmux コマンド
#   scripts/m3-harness.sh inject <file>       ファイル内容を pane へ貼り付け
#                                             (load-buffer + paste-buffer -p)
#   echo 'cmd' | scripts/m3-harness.sh run [待ち秒]
#                                             1行を貼り付けて Enter を送る
#   scripts/m3-harness.sh stop | teardown
#
# 方針 (M2 から継続):
#   - ユーザーの既定 tmux サーバには一切触れない。
#   - `open -na Ghostty` は使わない (M2 で既定サーバを汚染した前例あり)。
#   - テキスト注入は `load-buffer` + `paste-buffer -p`。`send-keys -l` は
#     改行がそのまま Enter になるため複数行では使わない (M2 §8.8)。
#   - ディスプレイがスリープしていると surface 生成も screencapture も失敗するため、
#     launch / shot の前に毎回 caffeinate -u を新規に起動して叩き起こす (README §9.3)。
#
set -uo pipefail

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M2="${SPIKE_DIR}/scripts/m2-harness.sh"
RUN="${M2_RUN_DIR:-${TMPDIR:-/tmp}/gate1-m2}"
SOCK=gate1-spike
SESSION=gate1-spike

export SPIKE_SHOT_PREFIX=m3
export M2_RUN_DIR="${RUN}"
mkdir -p "${RUN}"

t() { tmux -L "${SOCK}" "$@"; }
naptime() { perl -e "select(undef,undef,undef,$1)"; }

cmd="${1:-}"
shift || true

# ディスプレイがスリープすると CGGetActiveDisplayList が 0 個を返し、
# libghostty の surface 生成 (CVDisplayLink) も screencapture も失敗する。
# 起動前・撮影前にユーザー操作アサーションを立てて叩き起こす。
# NOTE: 既に走っている caffeinate があってもスリープしたディスプレイは起きない。
# 「今ユーザー操作があった」と宣言し直す必要があるので、毎回新しく起動する。
wake() {
  nohup caffeinate -u -t 30 >/dev/null 2>&1 &
  naptime 2.0
}

case "${cmd}" in
launch)
  wake
  exec "${M2}" "${cmd}" "$@"
  ;;
shot)
  # ディスプレイが再びスリープすると screencapture が空振りするので、
  # 出力ファイルができるまで最大 3 回まで叩き起こしてリトライする。
  out="${SPIKE_DIR}/evidence/m3-${1}.png"
  rm -f "${out}"
  for _ in 1 2 3; do
    wake
    "${M2}" shot "$@" >/dev/null 2>&1
    [ -s "${out}" ] && break
  done
  [ -s "${out}" ] && echo "${out}" || { echo "CAPTURE FAILED: ${out}" >&2; exit 1; }
  ;;
ctl | log | winid | stop | teardown)
  exec "${M2}" "${cmd}" "$@"
  ;;
launch-bare)
  # tmux を挟まずに直接シェルを起動する。
  # 「tmux の grapheme clustering」と「libghostty の grapheme clustering」を
  # 切り分けるために必要 (M3 §11.3)。
  wake
  size="${1:-1400x900}"
  w="${size%x*}"; h="${size#*x}"
  rm -f "${RUN}/ctl"; : > "${RUN}/ctl"; : > "${RUN}/app.log"
  TERMINAL_SPIKE_COMMAND="/bin/bash --norc --noprofile" \
  TERMINAL_SPIKE_CONTROL="${RUN}/ctl" \
  nohup "${SPIKE_DIR}/build/TerminalSpike.app/Contents/MacOS/TerminalSpike" \
    > "${RUN}/app.log" 2>&1 &
  echo "app pid=$!"
  naptime 2.5
  echo "resize ${w} ${h}" >> "${RUN}/ctl"
  naptime 1.0
  ;;
tmux)
  t "$@"
  ;;
inject)
  # ファイルをそのまま pane へ貼り付ける (bracketed paste。勝手に実行されない)
  target="${2:-${SESSION}}"
  t load-buffer -b m3 "${1}"
  t paste-buffer -p -b m3 -t "${target}"
  ;;
run)
  # stdin (1行想定) を貼り付けてから Enter を送る
  tmpfile="${RUN}/run.txt"
  cat > "${tmpfile}"
  t load-buffer -b m3 "${tmpfile}"
  t paste-buffer -p -b m3 -t "${SESSION}"
  naptime 0.2
  t send-keys -t "${SESSION}" Enter
  naptime "${1:-0.6}"
  ;;
*)
  sed -n '2,31p' "${BASH_SOURCE[0]}"
  ;;
esac
