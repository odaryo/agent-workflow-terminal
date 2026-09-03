#!/usr/bin/env bash
# M4/§6.3: ポーリング間隔ごとの観測コスト。#20 の polling/event 判断への材料。
# 実運用に合わせ pane ごとに 1 observer を回し、20 秒あたりの合計 CPU を測る。
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
out="$G3_EVIDENCE/m4-polling-cost.tsv"
printf 'panes\tinterval_s\tduration_s\tuser_cpu_s\tsys_cpu_s\tsamples_total\n' >"$out"
for panes in 1 5; do
  g3_tmux kill-session -t cost 2>/dev/null || true
  g3_tmux new-session -d -s cost -x 140 -y 45 "/bin/bash --norc --noprofile"
  for _ in $(seq 2 "$panes"); do g3_tmux split-window -t cost "/bin/bash --norc --noprofile"; done
  g3_tmux select-layout -t cost tiled >/dev/null
  ids=$(g3_tmux list-panes -t cost -F '#{pane_id}' | tr '\n' ' ')
  for iv in 0.25 1 2; do
    rm -f /tmp/g3cost.jsonl.*
    # /usr/bin/time -p は待ち終えた子プロセスの CPU も合算する。
    timing=$( { /usr/bin/time -p bash -c '
      for id in $1; do python3 "$2" "$id" "/tmp/g3cost.jsonl.$$-${id#%}" "$3" 20 & done; wait' \
      _ "$ids" "$G3_ROOT/scripts/recorder.py" "$iv" >/dev/null; } 2>&1 )
    printf '%s\t%s\t20\t%s\t%s\t%s\n' "$panes" "$iv" \
      "$(printf '%s' "$timing" | awk '/^user/{print $2}')" \
      "$(printf '%s' "$timing" | awk '/^sys/{print $2}')" \
      "$(cat /tmp/g3cost.jsonl.* 2>/dev/null | wc -l | tr -d ' ')" >>"$out"
  done
  g3_tmux kill-session -t cost 2>/dev/null || true
  rm -f /tmp/g3cost.jsonl.*
done
cat "$out"
