#!/usr/bin/env bash
# M4: pane / process の紐付けが操作を跨いで安定するか (§24「pane／processとの安定した紐付け」)。
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
out="$G3_EVIDENCE/m4-binding.tsv"
sess="m4bind"
g3_tmux kill-session -t "$sess" 2>/dev/null || true
g3_tmux new-session -d -s "$sess" -x 140 -y 45 -c "$G3_WORK" "/bin/bash --norc --noprofile"

obs() { # <step>
  local ids pid agentpid
  ids=$(g3_tmux list-panes -t "$sess" -F '#{pane_id}:#{pane_pid}:#{pane_current_command}:#{pane_dead}:#{pane_dead_status}' | tr '\n' ' ')
  pid=$(g3_tmux list-panes -t "$sess" -F '#{pane_pid}' | head -1)
  agentpid=$( { pgrep -P "$pid" 2>/dev/null || true; } | tr "\n" "," )
  printf '%s\t%s\t%s\t%s\n' "$1" "$ids" "$pid" "${agentpid:-none}" >>"$out"
}

printf 'step\tpanes(pane_id:pane_pid:cmd:dead:status)\tpane_pid\tchildren\n' >"$out"
obs "0-after-new-session"
g3_tmux send-keys -t "$sess" 'sleep 600' Enter; sleep 1; obs "1-long-running-child"
g3_tmux split-window -t "$sess" -c "$G3_WORK" "/bin/bash --norc --noprofile"; sleep 1; obs "2-after-split"
g3_tmux resize-pane -t "$sess" -Z; sleep 1; obs "3-after-zoom"
g3_tmux resize-pane -t "$sess" -Z; sleep 1; obs "4-after-unzoom"
# 実クライアントを繋いで外す。detach で pane や pid が変わらないことを確かめる。
g3_tmux new-session -d -s "${sess}-client" "/bin/bash --norc --noprofile"
g3_tmux send-keys -t "${sess}-client" "tmux -L $G3_SOCKET attach -t $sess" Enter; sleep 2; obs "5-client-attached"
g3_tmux detach-client -s "$sess" 2>/dev/null || true; sleep 1; obs "6-after-detach"
g3_tmux swap-pane -t "$sess" -U 2>/dev/null || true; sleep 1; obs "7-after-swap-pane"
g3_tmux respawn-pane -k -t "$sess" "/bin/bash --norc --noprofile"; sleep 1; obs "8-after-respawn"
g3_tmux send-keys -t "$sess" 'exit' Enter; sleep 2; obs "9-after-shell-exit"
g3_tmux kill-session -t "${sess}-client" 2>/dev/null || true
g3_tmux kill-session -t "$sess" 2>/dev/null || true
cat "$out"
