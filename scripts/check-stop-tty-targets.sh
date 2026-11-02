#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: check-stop-tty-targets.sh

scripts/stop_tty_targets.py (scripts/stop-tty-processes.sh の宛先の判定、Issue #573) を fixture で
検査する。fixture は scripts/tests/stop-tty-targets/cases/<名前>/ 配下:

  recorded.txt  記録したときの `ps -A -o pid=,pgid=,tty=,lstart=,args=` の出力 (LC_ALL=C)
  now.txt       今の同じ形の出力
  case.txt      rc= (期待する終了コード) / self= (--self に渡す pid) / ttys= (空白区切りの tty)
  expected.txt  期待する標準出力 (rc が 0 以外なら空)

pid の再利用や group の移動は実プロセスでは起こせないので、宛先の判定はここで固定する。
tmux は要らない。

  -h, --help  このヘルプを表示
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || die "引数は指定できません"
require_cmd python3

TARGETS="$SCRIPT_DIR/stop_tty_targets.py"
CASES_DIR="$SCRIPT_DIR/tests/stop-tty-targets/cases"
[[ -d "$CASES_DIR" ]] || die "fixture がありません: $CASES_DIR"

work_dir=$(mktemp -d)
# bash 3.2 は EXIT の trap があると、set -u の未定義の変数の参照で止まっても exit 0 を返す。
# 最後まで走った印が無ければ非 0 で終わらせる (docs/coding-guidelines.md §7)。
__awt_finished=0
__awt_on_exit() {
  local rc=$?
  rm -rf "$work_dir"
  [[ $__awt_finished -eq 1 || $rc -ne 0 ]] || rc=1
  exit "$rc"
}
trap __awt_on_exit EXIT

failures=0
checked=0

case_value() {
  sed -n "s/^$2=//p" "$1"
}

for case_dir in "$CASES_DIR"/*/; do
  case_dir="${case_dir%/}"
  name="${case_dir##*/}"
  checked=$((checked + 1))
  want_rc=$(case_value "$case_dir/case.txt" rc)
  self=$(case_value "$case_dir/case.txt" self)
  ttys=$(case_value "$case_dir/case.txt" ttys)
  rc=0
  # ttys は空白区切りの一覧として、語に分けて渡す。
  # shellcheck disable=SC2086
  "$TARGETS" --self "$self" --recorded "$case_dir/recorded.txt" --now "$case_dir/now.txt" \
    $ttys >"$work_dir/out" 2>"$work_dir/err" || rc=$?
  if [[ "$rc" -ne "$want_rc" ]]; then
    info "NG (期待 exit ${want_rc} / 実際 exit ${rc}): $name"
    cat "$work_dir/err" >&2
    failures=$((failures + 1))
  elif [[ "$rc" -ne 0 && -s "$work_dir/out" ]]; then
    info "NG (exit ${rc} なのに標準出力がある): $name"
    cat "$work_dir/out" >&2
    failures=$((failures + 1))
  elif [[ "$rc" -ne 0 && ! -s "$work_dir/err" ]]; then
    info "NG (exit ${rc} なのに理由が出ていない): $name"
    failures=$((failures + 1))
  elif ! diff -u "$case_dir/expected.txt" "$work_dir/out" >"$work_dir/diff"; then
    info "NG (出力が期待と異なる): $name"
    cat "$work_dir/diff" >&2
    failures=$((failures + 1))
  else
    info "OK (exit ${rc}): $name"
  fi
done

[[ "$checked" -gt 0 ]] || die "fixture が 1 件もありません: $CASES_DIR"
[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
__awt_finished=1
