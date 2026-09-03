#!/usr/bin/env bash
# Agent でないものを pane で動かし、fallback が「Agent が居る」と誤認しないかを見る (§24 fallback時の誤判定)。
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
for target in "top -l 0" "vim -u NONE" "/bin/bash --norc --noprofile" "python3 -q -i"; do
  name="fb$(echo "$target" | tr -c 'a-z0-9' '-' | cut -c1-12)"
  out="$G3_EVIDENCE/runs/fallback-${name}"
  mkdir -p "$out"
  g3_tmux new-session -d -s "$name" -x 140 -y 45 -c "$G3_WORK" $target
  sleep 3
  printf '{"ts":%s,"event":"fallback_begin","note":"%s"}\n' \
    "$(perl -MTime::HiRes=time -e 'printf "%.3f", time()')" "$target" >"$out/truth.jsonl"
  python3 "$G3_ROOT/scripts/recorder.py" "$name" "$out/signals.jsonl" 0.25 20
  printf '{"ts":%s,"event":"run_end","note":""}\n' \
    "$(perl -MTime::HiRes=time -e 'printf "%.3f", time()')" >>"$out/truth.jsonl"
  g3_tmux kill-session -t "$name" 2>/dev/null || true
  echo "done $target"
done
