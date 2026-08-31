#!/bin/bash
#
# Gate 1 PoC (M4) — 高速更新 TUI / 進捗バー (pane の中で実行する)
#
#   bash fastui.sh [秒]
#
# `\r` によるインプレース更新を 1 秒あたり数百回行い、その後 top を
# alternate screen で回す。描画が追いつかずに残像・欠けが出ないかを見る。
#
set -u
secs="${1:-15}"
end=$(( $(date +%s) + secs ))
n=0
while [ "$(date +%s)" -lt "$end" ]; do
  for i in $(seq 0 40); do
    bar=$(printf '#%.0s' $(seq 0 $i))
    printf '\r\033[K[%-41s] %3d%% frame=%d 日本語 🚀' "$bar" $(( i * 100 / 40 )) "$n"
    n=$(( n + 1 ))
  done
done
printf '\n===== M4 FASTUI frames=%d in %ss =====\n' "$n" "$secs"
top -l 10 -s 1 -n 20 > /dev/null   # 数値だけ回す (ウォームアップ)
echo '--- top (alternate screen) ---'
top -l 8 -s 1 -n 15
echo '===== M4 FASTUI COMPLETE ====='
