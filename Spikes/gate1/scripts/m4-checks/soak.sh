#!/bin/bash
#
# Gate 1 PoC (M4) — 中期稼働ソーク (pane の中で実行する)
#
#   bash soak.sh [分] [進捗ログ]
#
# 5 秒ごとに時刻 + カラー + 日本語 + 絵文字を 1 行出し、60 秒ごとに 2 万行の
# burst を出す。`/tmp/gate1-m4/soak.stop` を作れば途中で止まる。
# 進捗は逐次ファイルへも書くので、セッションが切れても再開・集計できる。
#
set -u
mins="${1:-35}"
progress="${2:-/tmp/gate1-m4/soak-progress.log}"
stop=/tmp/gate1-m4/soak.stop
rm -f "$stop"
end=$(( $(date +%s) + mins * 60 ))
i=0
echo "start $(date +%FT%T) mins=${mins}" >> "$progress"
while [ "$(date +%s)" -lt "$end" ]; do
  [ -f "$stop" ] && break
  i=$((i + 1))
  printf '\033[36m[soak %04d]\033[0m %s \033[32m●\033[0m \033[1;33m日本語テスト\033[0m 🚀 \033[4m%s\033[0m\n' \
    "$i" "$(date +%T)" "$(printf '=%.0s' $(seq 1 $(( i % 40 + 1 ))))"
  if [ $(( i % 12 )) -eq 0 ]; then
    printf '\033[35m--- burst #%d (20000 lines) ---\033[0m\n' "$i"
    seq 1 20000
    echo "burst $(date +%FT%T) i=$i" >> "$progress"
  fi
  sleep 5
done
echo "end $(date +%FT%T) iterations=$i" >> "$progress"
echo "===== M4 SOAK COMPLETE ($i iterations) ====="
