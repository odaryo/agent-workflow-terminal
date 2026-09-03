#!/usr/bin/env bash
# 反復実行。1 run ごとに hook ログを退避してから次へ進む。
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
agent="$1"; scenario="$2"; n="${3:-5}"
for i in $(seq 1 "$n"); do
  : >"$G3_WORK/hook-events.jsonl"
  rm -f "$G3_WORK/notes.txt"
  bash "$G3_ROOT/scripts/driver.sh" "$agent" "$scenario" "r$i" || echo "run r$i failed" >&2
  cp "$G3_WORK/hook-events.jsonl" "$G3_EVIDENCE/runs/${agent}-${scenario}-r$i/hook-events.jsonl" 2>/dev/null || true
  echo "[$(date +%H:%M:%S)] done ${agent}-${scenario}-r$i"
done
