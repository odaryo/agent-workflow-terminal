#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: run-swift-test.sh --log <path> --timeout <seconds> -- <command> [args...]

コマンドを実行し、全出力を <path> へ保存したうえで標準出力へ流す。
<seconds> を超えても終わらない場合はスタックを採取してからプロセスグループごと停止し、
exit 124 で失敗する (ジョブのタイムアウトによる cancel と違い、ログが残る)。

  --log <path>        出力の保存先。親ディレクトリは自動で作る
  --timeout <seconds> 実行時間の上限 (秒)
  -h, --help          このヘルプを表示
EOF
}

log=""
timeout_seconds=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --log)
      require_value --log $#
      log=$2
      shift 2
      ;;
    --timeout)
      require_value --timeout $#
      timeout_seconds=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) die "不明な引数: $1" ;;
  esac
done

[[ -n "$log" ]] || die "--log は必須です"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || die "--timeout には正の秒数が必要です"
[[ $# -gt 0 ]] || die "-- の後に実行するコマンドを指定してください"

mkdir -p -- "$(dirname -- "$log")"
: >"$log"
stacks="$log.stacks.txt"
timeout_marker="$log.timed-out"
finished_marker="$log.finished"
rm -f -- "$stacks" "$timeout_marker" "$finished_marker"

# 子孫を親子関係で辿る。`swift test` が起動する `swiftpm-testing-helper` は自前の process
# group を持つため (実測: pgid が swift-test と異なる)、process group 単位で殺すと取り残される。
# GitHub Actions のログに出る "Terminate orphan process: (swiftpm-testing)" がその状態。
# 出力は子孫が先、親が後の順。停止も同じ順で行う。
descendants() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    descendants "$child"
  done
  echo "$pid"
}

# タイムアウト時に「どのテストで止まったか」を残す。並列実行では最後に出力されたテスト名が
# 停止箇所を指さないため、ログではなく生きているプロセスのスタックが唯一の手掛かりになる。
collect_stacks() {
  local root=$1 pid
  {
    echo "=== ps ==="
    for pid in $(descendants "$root"); do
      ps -o pid,ppid,etime,command -p "$pid" | tail -n +2
    done
    for pid in $(descendants "$root"); do
      echo
      echo "=== sample $pid ==="
      sample "$pid" 3 -mayDie 2>&1 || echo "(sample に失敗しました: pid $pid)"
    done
  } >"$stacks" 2>&1
}

stop_pids() {
  local signal=$1 pid
  shift
  for pid in "$@"; do
    kill "-$signal" "$pid" 2>/dev/null || true
  done
}

"$@" >"$log" 2>&1 &
child=$!
# 監視側は signal ではなく marker で終わらせる。kill で落とすと bash が "Terminated" を
# テスト出力の中へ書き込むため。出力を /dev/null へ向けるのは、GitHub Actions の step が
# 掴んだ fd を握る background job を残さないため。診断はファイルへ書く。
(
  waited=0
  while [[ "$waited" -lt "$timeout_seconds" ]]; do
    sleep 1
    waited=$((waited + 1))
    if [[ -f "$finished_marker" ]]; then exit 0; fi
    kill -0 "$child" 2>/dev/null || exit 0
  done
  touch -- "$timeout_marker"
  collect_stacks "$child"
  # 親を殺すと子孫は launchd へ里子に出され、親子関係から辿れなくなる。停止対象は先に確定する。
  doomed=$(descendants "$child")
  # shellcheck disable=SC2086 # pid の並びとして分割させるため意図的に quote しない
  stop_pids TERM $doomed
  sleep 10
  # shellcheck disable=SC2086 # 同上
  stop_pids KILL $doomed
) </dev/null >/dev/null 2>&1 &
watchdog=$!

status=0
wait "$child" || status=$?
touch -- "$finished_marker"
# タイムアウト時は KILL までの段階的停止を最後までやらせる。途中で打ち切ると orphan が残る。
wait "$watchdog" 2>/dev/null || true
rm -f -- "$finished_marker"

# ライブ表示ではなく完了後の一括出力。tee と比べた損得はほぼ無く、実装が単純なほうを取った。
# タイムアウト時のログが末尾を落とすのは、どちらを選んでも同じ (子の stdio はブロック
# バッファで、TERM/KILL では flush されない。実測: ハング1件だけの回のログは 98 バイトで、
# テスト進行の行は1行も残らなかった)。止まった箇所の手掛かりは、ログではなく下の
# スタック採取が担う (実測でハングしたテスト名と行番号まで出る)。
cat -- "$log"

if [[ -f "$timeout_marker" ]]; then
  rm -f -- "$timeout_marker"
  echo >&2
  cat -- "$stacks" >&2 || true
  echo "エラー: ${timeout_seconds}秒を超えても終了しないため停止しました: $*" >&2
  echo "スタック: $stacks / 出力: $log" >&2
  exit 124
fi

exit "$status"
