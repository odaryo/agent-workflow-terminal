#!/usr/bin/env bash
# 1 シナリオを流し、生信号 (recorder.py) と ground truth ヒント (script 側の事実) を記録する。
# 使い方: driver.sh <agent: claude|codex> <scenario> <run-id>
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

agent="$1"; scenario="$2"; run_id="$3"
out_dir="$G3_EVIDENCE/runs/${agent}-${scenario}-${run_id}"
mkdir -p "$out_dir"
win="run$$"

truth() { # ground truth は「script が知っている事実」だけを書く (PLAN.md §6.1)
  printf '{"ts":%s,"event":"%s","note":"%s"}\n' \
    "$(perl -MTime::HiRes=time -e 'printf "%.3f", time()')" "$1" "${2:-}" >>"$out_dir/truth.jsonl"
}

send() { g3_tmux send-keys -t "$win" -l -- "$1"; sleep 0.4; g3_tmux send-keys -t "$win" Enter; }

screen() { g3_tmux capture-pane -p -t "$win" 2>/dev/null || true; }

start_agent() {
  case "$agent" in
    claude) cmd="claude --permission-mode default" ;;
    # approvals_reviewer=user を明示するのは、利用者の ~/.codex/config.toml が
    # auto_review だと承認が自動で通り Permission 状態が発生しないため (M1 実測)。
    codex)  cmd='codex -a on-request -s read-only -c approvals_reviewer="user"' ;;
    *) echo "unknown agent: $agent" >&2; exit 1 ;;
  esac
  # 画面幅は S2 の結論に直結するため固定して記録する (PLAN.md §4.2)。
  g3_tmux new-session -d -s "$win" -x 140 -y 45 -c "$G3_WORK" "/bin/bash --norc --noprofile"
  sleep 0.5
  g3_tmux send-keys -t "$win" "$cmd" Enter
}

# 起動直後の trust ダイアログを越えて「入力待ち」に到達させる。
# ここは計測対象ではないので recorder 開始前に済ませる。
wait_ready() {
  for _ in $(seq 1 60); do
    s="$(screen)"
    case "$agent" in
      claude)
        if printf '%s' "$s" | grep -q 'Yes, I trust this folder'; then
          g3_tmux send-keys -t "$win" Down; sleep 0.3; g3_tmux send-keys -t "$win" Enter; sleep 3; continue
        fi
        printf '%s' "$s" | grep -qE '(manual|auto|plan) mode on' && return 0 ;;
      codex)
        if printf '%s' "$s" | grep -q 'Yes, continue'; then
          g3_tmux send-keys -t "$win" Enter; sleep 3; continue
        fi
        printf '%s' "$s" | grep -qE 'Ask Codex|OpenAI Codex \(v' && return 0 ;;
    esac
    sleep 1
  done
  screen >"$out_dir/wait_ready-timeout-screen.txt"
  echo "wait_ready timed out ($agent)" >&2
  return 1
}

record_start() {
  python3 "$G3_ROOT/scripts/recorder.py" "$win" "$out_dir/signals.jsonl" 0.25 "$1" &
  RECORDER_PID=$!
  sleep 0.5
}

cleanup() {
  wait "${RECORDER_PID:-}" 2>/dev/null || true
  screen >"$out_dir/final-screen.txt"
  g3_tmux kill-session -t "$win" 2>/dev/null || true
}
trap cleanup EXIT

start_agent
wait_ready

case "$scenario" in
  # idle -> working -> permission -> working -> completed -> idle を1本で通す。
  # idle -> working(長考) -> completed -> working -> permission -> working -> completed -> 放置
  # を1本で通す。1 run で複数状態の真値区間が取れるので反復コストが下がる。
  composite)
    record_start 260
    truth idle_begin "起動後・無入力"
    sleep 25
    truth prompt_long_sent "ツール不要で出力が長いタスク"
    send '1 から 20 までの数字を、それぞれ日本語の読みと一言の豆知識つきで、1行ずつ列挙して。ファイルは読まないで。'
    sleep 75
    truth prompt_perm_sent "承認が要る書き込みを依頼"
    send 'notes.txt という新しいファイルを作り、中身に today と1行だけ書いて。'
    sleep 45
    truth approve_sent "承認を送る"
    g3_tmux send-keys -t "$win" Enter
    sleep 45
    truth quiesce "完了後の放置区間"
    sleep 55
    ;;
  question)
    record_start 90
    truth idle_begin ""
    sleep 15
    truth prompt_sent "利用者への質問を明示的に依頼"
    case "$agent" in
      claude) send 'AskUserQuestion ツールを使って、私に1つだけ質問して。' ;;
      codex)  send '作業を進める前に、私に確認したいことを1つ質問して。回答を待って。' ;;
    esac
    sleep 70
    ;;
  error)
    record_start 60
    truth idle_begin ""
    sleep 10
    truth error_induced "存在しないモデルへ切り替えてターンを投げる"
    case "$agent" in
      claude) send '/model no-such-model-xyz' ;;
      codex)  send '/model no-such-model-xyz' ;;
    esac
    sleep 5
    send 'こんにちは'
    sleep 40
    ;;
  # 信号を意図的に奪う。ここで Working / Idle を返したら §12.3 違反 (PLAN.md M2)。
  deprived)
    record_start 150
    truth idle_begin ""
    sleep 15
    truth prompt_long_sent "長考タスクを投げる"
    send '1 から 20 までの数字を、それぞれ日本語の読みと一言の豆知識つきで、1行ずつ列挙して。ファイルは読まないで。'
    sleep 10
    truth narrowed "画面幅を 40 桁へ縮めて S2 のパターンを壊す"
    g3_tmux resize-window -t "$win" -x 40 -y 12 2>/dev/null || true
    sleep 40
    truth copy_mode "copy-mode へ入れてライブ画面を隠す"
    g3_tmux copy-mode -t "$win"
    sleep 40
    truth restored "元へ戻す"
    g3_tmux send-keys -t "$win" -X cancel 2>/dev/null || true
    g3_tmux resize-window -t "$win" -x 140 -y 45 2>/dev/null || true
    sleep 30
    ;;
  # Agent 自身の失敗。/model への不正値ではどちらの Agent も通常応答を返し
  # Error にならなかった (error シナリオの実測) ので、確実に落ちる経路を使う。
  error-startup)
    record_start 40
    truth idle_begin ""
    sleep 5
    truth error_induced "存在しないモデルを指定して再起動する"
    g3_tmux send-keys -t "$win" C-c
    sleep 1
    g3_tmux send-keys -t "$win" 'exit' Enter
    sleep 2
    case "$agent" in
      claude) g3_tmux send-keys -t "$win" 'claude --model no-such-model-xyz; echo EXIT=$?' Enter ;;
      codex)  g3_tmux send-keys -t "$win" 'codex --model no-such-model-xyz; echo EXIT=$?' Enter ;;
    esac
    sleep 30
    ;;
  # Adapter の観測失敗ではなく Agent プロセスの死。§12.3 の区別の片側。
  error-killed)
    record_start 60
    truth idle_begin ""
    sleep 10
    truth prompt_sent "ターンを開始させる"
    send '1 から 20 までの数字を、それぞれ日本語の読みと一言の豆知識つきで、1行ずつ列挙して。'
    sleep 8
    truth killed "Agent プロセスを SIGKILL する"
    pane_pid=$(g3_tmux list-panes -t "$win" -F '#{pane_pid}' | head -1)
    for child in $( { pgrep -P "$pane_pid" || true; } ); do kill -9 "$child" 2>/dev/null || true; done
    sleep 35
    ;;
  *) echo "unknown scenario: $scenario" >&2; exit 1 ;;
esac

truth run_end ""
