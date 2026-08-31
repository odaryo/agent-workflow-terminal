#!/usr/bin/env bash
#
# Gate 1 PoC (M4) — 大量出力 / メモリ / 中期ソーク 検証ハーネス
#
# M2/M3 の隔離方式をそのまま再利用する (専用ソケット `-L gate1-spike`、
# `TERMINAL_SPIKE_CONTROL` 制御チャネル、`load-buffer` + `paste-buffer -p` 注入)。
# M4 で足すのは「計測」の 3 つだけ:
#
#   ping     … 制御チャネルの往復時間 = main thread の応答性
#   mem      … RSS / phys_footprint の 1 サンプル
#   sampler  … 上記の定期サンプリング (ソーク用。逐次ファイルへ追記する)
#
#   scripts/m4-harness.sh launch [WxH]        tmux attach で起動
#   scripts/m4-harness.sh launch-bare [WxH]   tmux 無しで bash を直起動
#   scripts/m4-harness.sh ctl '<cmd>' ...     制御チャネルへコマンド
#   scripts/m4-harness.sh shot <name>         evidence/m4-<name>.png
#   scripts/m4-harness.sh tmux <args...>      gate1-spike サーバへ tmux コマンド
#   echo 'cmd' | scripts/m4-harness.sh run    pane へ 1 行流して Enter
#   scripts/m4-harness.sh pid                 アプリの pid
#   scripts/m4-harness.sh ping [n]            往復レイテンシを n 回 (既定 5)
#   scripts/m4-harness.sh mem <label> [csv]   1 サンプルを CSV へ追記
#   scripts/m4-harness.sh sampler <sec> <csv> [label]  定期サンプリング開始
#   scripts/m4-harness.sh sampler-stop
#   scripts/m4-harness.sh footprint <label>   footprint 全文を evidence へ
#   scripts/m4-harness.sh stop | teardown
#
# 環境変数:
#   M4_CONFIG_FILE  … ghostty の設定ファイル (scrollback-limit の実験用)。
#                     ユーザーの ~/.config/ghostty/config は読まない。
#   M4_SOCKET_CMD   … launch 時の TERMINAL_SPIKE_COMMAND を上書きする
#
set -uo pipefail

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M3="${SPIKE_DIR}/scripts/m3-harness.sh"
RUN="${M2_RUN_DIR:-${TMPDIR:-/tmp}/gate1-m2}"
CTL="${RUN}/ctl"
LOG="${RUN}/app.log"
EV="${SPIKE_DIR}/evidence"
SAMPLER_PID="${RUN}/sampler.pid"

export M2_RUN_DIR="${RUN}"
export SPIKE_SHOT_PREFIX=m4
mkdir -p "${RUN}" "${EV}"

app_pid() { pgrep -f 'TerminalSpike.app/Contents/MacOS/TerminalSpike' | head -1; }

# phys_footprint を KB で返す。footprint(1) は "1712 KB" / "1.2 MB" の両方を出す。
footprint_kb() {
  local pid="$1"
  footprint -p "${pid}" 2>/dev/null | awk '
    /phys_footprint:/ {
      v=$2; u=$3;
      if (u ~ /^MB/) v=v*1024; else if (u ~ /^GB/) v=v*1024*1024;
      printf "%.0f", v; found=1
    }
    END { if (!found) printf "NA" }'
}

sample_line() {
  local label="$1" pid
  pid="$(app_pid)"
  if [ -z "${pid}" ]; then
    printf '%s,%s,%s,NA,NA,NA,NA\n' "$(date +%s)" "$(date +%FT%T)" "${label}"
    return
  fi
  local ps_out rss vsz cpu fp
  ps_out="$(ps -o rss=,vsz=,%cpu= -p "${pid}")"
  rss="$(echo "${ps_out}" | awk '{print $1}')"
  vsz="$(echo "${ps_out}" | awk '{print $2}')"
  cpu="$(echo "${ps_out}" | awk '{print $3}')"
  fp="$(footprint_kb "${pid}")"
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$(date +%s)" "$(date +%FT%T)" "${label}" \
    "${rss}" "${vsz}" "${cpu}" "${fp}"
}

csv_header() {
  [ -s "$1" ] || echo 'epoch,iso,label,rss_kb,vsz_kb,cpu_pct,footprint_kb' > "$1"
}

cmd="${1:-}"
shift || true

case "${cmd}" in
launch)
  [ -n "${M4_CONFIG_FILE:-}" ] && export TERMINAL_SPIKE_CONFIG_FILE="${M4_CONFIG_FILE}"
  exec "${M3}" launch "$@"
  ;;
launch-bare)
  [ -n "${M4_CONFIG_FILE:-}" ] && export TERMINAL_SPIKE_CONFIG_FILE="${M4_CONFIG_FILE}"
  exec "${M3}" launch-bare "$@"
  ;;
ctl | log | winid | tmux | inject | run | stop)
  exec "${M3}" "${cmd}" "$@"
  ;;
shot)
  # m3-harness の shot は接頭辞 m3 を固定してしまうので、ここで m4 用に撮り直す。
  # ディスプレイスリープ対策の叩き起こし (README §9.3) は同じ。
  out="${EV}/m4-${1}.png"
  rm -f "${out}"
  for _ in 1 2 3; do
    nohup caffeinate -u -t 30 >/dev/null 2>&1 &
    sleep 1
    SPIKE_SHOT_PREFIX=m4 "${SPIKE_DIR}/scripts/m2-harness.sh" shot "$@" >/dev/null 2>&1
    [ -s "${out}" ] && break
  done
  [ -s "${out}" ] && echo "${out}" || { echo "CAPTURE FAILED: ${out}" >&2; exit 1; }
  ;;
teardown)
  "${BASH_SOURCE[0]}" sampler-stop >/dev/null 2>&1
  exec "${M3}" teardown
  ;;
pid)
  app_pid
  ;;
ping)
  # 制御チャネル (main thread の 100ms Timer) の往復時間を測る。
  # 大量出力で main thread が詰まると、この値がそのまま伸びる。
  n="${1:-5}"
  perl -MTime::HiRes -e '
    my ($ctl, $log, $n) = @ARGV;
    for my $i (1 .. $n) {
      my $id = "PING-$$-$i-" . int(Time::HiRes::time() * 1000);
      my $t0 = Time::HiRes::time();
      open(my $fh, ">>", $ctl) or die $!; print $fh "log $id\n"; close $fh;
      my $found = 0;
      while (Time::HiRes::time() - $t0 < 60) {
        if (open(my $lf, "<", $log)) { local $/; my $c = <$lf>; close $lf;
          if (index($c, $id) >= 0) { $found = 1; last } }
        Time::HiRes::sleep(0.005);
      }
      printf("%s %.1f\n", $found ? "ok" : "TIMEOUT", (Time::HiRes::time() - $t0) * 1000);
      Time::HiRes::sleep(0.2);
    }' "${CTL}" "${LOG}" "${n}"
  ;;
mem)
  label="${1:-sample}"
  csv="${2:-${RUN}/mem.csv}"
  csv_header "${csv}"
  line="$(sample_line "${label}")"
  echo "${line}" >> "${csv}"
  echo "${line}"
  ;;
sampler)
  interval="${1:-15}"
  csv="${2:-${RUN}/mem.csv}"
  label="${3:-soak}"
  csv_header "${csv}"
  # 中断されても途中まで残るように、1 サンプルごとに追記して flush する
  (
    while :; do
      line="$(sample_line "${label}")"
      echo "${line}" >> "${csv}"
      sleep "${interval}"
    done
  ) >/dev/null 2>&1 &
  echo $! > "${SAMPLER_PID}"
  echo "sampler pid=$(cat "${SAMPLER_PID}") interval=${interval}s -> ${csv}"
  ;;
soak-sampler)
  # ソーク用: スパイクアプリと gate1-spike の tmux サーバを 1 行ずつ記録する。
  # セッションが切れても途中まで残るよう、1 サンプルごとに追記する。
  interval="${1:-15}"
  csv="${2:-${EV}/m4-soak-samples.csv}"
  [ -s "${csv}" ] || echo 'epoch,iso,proc,rss_kb,footprint_kb,cpu_pct' > "${csv}"
  (
    while :; do
      ts="$(date +%s)"; iso="$(date +%FT%T)"
      ap="$(app_pid)"
      if [ -n "${ap}" ]; then
        set -- $(ps -o rss=,%cpu= -p "${ap}")
        echo "${ts},${iso},app,${1:-NA},$(footprint_kb "${ap}"),${2:-NA}" >> "${csv}"
      fi
      sp="$(tmux -L gate1-spike display -p '#{pid}' 2>/dev/null)"
      if [ -n "${sp}" ]; then
        set -- $(ps -o rss=,%cpu= -p "${sp}")
        echo "${ts},${iso},tmux-server,${1:-NA},$(footprint_kb "${sp}"),${2:-NA}" >> "${csv}"
      fi
      sleep "${interval}"
    done
  ) >/dev/null 2>&1 &
  echo $! > "${SAMPLER_PID}"
  echo "soak sampler pid=$(cat "${SAMPLER_PID}") interval=${interval}s -> ${csv}"
  ;;
sampler-stop)
  if [ -f "${SAMPLER_PID}" ]; then
    kill "$(cat "${SAMPLER_PID}")" 2>/dev/null
    rm -f "${SAMPLER_PID}"
    echo "sampler stopped"
  fi
  ;;
footprint)
  pid="$(app_pid)"
  [ -n "${pid}" ] || { echo "no app" >&2; exit 1; }
  out="${EV}/m4-footprint-${1:-x}.txt"
  { echo "# $(date +%FT%T) pid=${pid} label=${1:-x}"; footprint -p "${pid}"; } > "${out}"
  echo "${out}"
  ;;
*)
  sed -n '2,40p' "${BASH_SOURCE[0]}"
  ;;
esac
