#!/bin/bash
#
# Gate 1 PoC (M4) — 大量出力スループット計測 (pane の中で実行する)
#
#   bash throughput.sh <結果CSV> <ラベル> [workload ...]
#
# 各ワークロードについて
#   1) 一度 `| wc -c` へ流してバイト数と行数を確定させる (端末へは出さない)
#   2) 同じコマンドを端末へ流し、その所要時間を測る
# を行い、CSV へ 1 行追記する。端末側のスループットだけを見るため、
# 生成側 (seq / cat / base64) の生成コストは (1) の値からおおよそ差し引ける。
#
# CSV: label,workload,bytes,lines,gen_sec,term_sec,term_MBps
#
set -u
out="${1:?結果CSV}"; label="${2:?ラベル}"; shift 2
BIG="${M4_BIGFILE:-/tmp/gate1-m4/big.txt}"

now() { perl -MTime::HiRes -e 'printf "%.3f\n", Time::HiRes::time()'; }
elapsed() { perl -e 'printf "%.3f\n", $ARGV[1] - $ARGV[0]' "$1" "$2"; }
mbps() { perl -e 'printf "%.2f\n", $ARGV[1] > 0 ? $ARGV[0] / 1048576 / $ARGV[1] : 0' "$1" "$2"; }

wl_cmd() {
  case "$1" in
    seq)     echo 'seq 1 1000000' ;;
    yes)     echo 'yes | head -n 3000000' ;;
    catbig)  echo "cat ${BIG}" ;;
    base64)  echo 'head -c 37500000 /dev/urandom | base64 -b 76' ;;
    base64raw) echo 'head -c 7500000 /dev/urandom | base64' ;;   # 改行なしの 10MB 単一行
    findusr) echo 'find /usr -print 2>/dev/null' ;;
    *) echo '' ;;
  esac
}

[ -s "$out" ] || echo 'label,workload,bytes,lines,gen_sec,term_sec,term_MBps' > "$out"

for wl in "$@"; do
  cmd="$(wl_cmd "$wl")"
  [ -n "$cmd" ] || { echo "unknown workload: $wl"; continue; }

  g0=$(now)
  read -r lines bytes < <(eval "$cmd" | wc -lc | awk '{print $1, $2}')
  g1=$(now)
  gen=$(elapsed "$g0" "$g1")

  printf '\n===== M4 %s / %s : %s bytes =====\n' "$label" "$wl" "$bytes"
  t0=$(now)
  eval "$cmd"
  t1=$(now)
  term=$(elapsed "$t0" "$t1")
  printf '\n===== M4 DONE %s / %s : %s bytes / %s lines / %s s =====\n' \
    "$label" "$wl" "$bytes" "$lines" "$term"

  echo "$label,$wl,$bytes,$lines,$gen,$term,$(mbps "$bytes" "$term")" >> "$out"
done

echo "===== M4 THROUGHPUT COMPLETE ($label) ====="
