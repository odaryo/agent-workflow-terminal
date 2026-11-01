#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: check-ci-paths-ignored.sh

scripts/tests/ci-paths-ignored/cases.tsv の workflow・変更ファイル一覧を組にして、
ci_paths_ignored.py の終了コード (0/1/2) を検査する。
実物の ci.yml と、単一 * の規則を壊した複製でも検査する。

  -h, --help  このヘルプを表示
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || die "引数は指定できません"
require_cmd python3

FIXTURE_DIR="$SCRIPT_DIR/tests/ci-paths-ignored"
DETECTOR="$SCRIPT_DIR/ci_paths_ignored.py"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
failures=0
checked=0

expect_rc() {
  local detector="$1" want="$2" workflow="$3" files="$4" label="$5" rc=0
  checked=$((checked + 1))
  python3 "$detector" --workflow "$workflow" <"$files" >"$work_dir/out" 2>"$work_dir/err" || rc=$?
  if [[ "$rc" -ne "$want" ]] \
    || { [[ "$rc" -eq 2 ]] && [[ ! -s "$work_dir/err" || $(wc -l <"$work_dir/err") -ne 1 ]]; }; then
    info "NG (期待 exit $want / 実際 exit $rc): $label"
    cat "$work_dir/err" >&2
    failures=$((failures + 1))
  else
    info "OK (exit $rc): $label"
  fi
}

run_fixtures() {
  local detector="$1" want workflow files
  while IFS=$'\t' read -r want workflow files; do
    expect_rc "$detector" "$want" "$FIXTURE_DIR/$workflow" "$FIXTURE_DIR/$files" "$files ($workflow)"
  done <"$FIXTURE_DIR/cases.tsv"
}

run_fixtures "$DETECTOR"
[[ "$checked" -gt 0 ]] || die "fixture が空です"

printf '%s\n' 'AgentWorkflowTerminal/Sources/TerminalCore/Example.swift' >"$work_dir/swift.txt"
printf '%s\n' 'Spikes/gate1/Example.swift' >"$work_dir/spikes.txt"
expect_rc "$DETECTOR" 1 "$SCRIPT_DIR/../.github/workflows/ci.yml" "$work_dir/swift.txt" '実物 ci.yml: Swift'
expect_rc "$DETECTOR" 0 "$SCRIPT_DIR/../.github/workflows/ci.yml" "$work_dir/spikes.txt" '実物 ci.yml: Spikes'
printf '%s\n' 'docs/roadmap.md' 'CLAUDE.md' '.claude/agents/reviewer.md' >"$work_dir/docs.txt"
printf '%s\n' 'docs/roadmap.md' '.claude/settings.json' >"$work_dir/settings.txt"
expect_rc "$DETECTOR" 0 "$SCRIPT_DIR/../.github/workflows/ci.yml" "$work_dir/docs.txt" '実物 ci.yml: docs と md'
expect_rc "$DETECTOR" 1 "$SCRIPT_DIR/../.github/workflows/ci.yml" "$work_dir/settings.txt" '実物 ci.yml: settings.json を含む'

# 構文エラーを変異の検出成功に数えず、正常に動く複製の規則の違いで失敗することを確かめる。
python3 - "$DETECTOR" "$work_dir/mutant.py" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
before = 'pieces.append("[^/]*")'
after = 'pieces.append(".*")'
if source.count(before) != 1 or after in source:
    sys.exit("変異対象の規則が変わっています")
mutant = source.replace(before, after)
compile(mutant, sys.argv[2], "exec")
Path(sys.argv[2]).write_text(mutant, encoding="utf-8")
PY
original_failures=$failures
original_checked=$checked
failures=0
run_fixtures "$work_dir/mutant.py" >"$work_dir/mutant.log" 2>&1
mutant_failures=$failures
failures=$original_failures
checked=$((original_checked + 1))
if [[ "$mutant_failures" -eq 0 ]] || grep -q 'Traceback\|SyntaxError' "$work_dir/mutant.log"; then
  info "NG: 単一 * の変異を検出できないか、複製が異常終了しました"
  cat "$work_dir/mutant.log" >&2
  failures=$((failures + 1))
else
  info "OK: 単一 * の変異を fixture $mutant_failures 件で検出しました"
fi

[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
