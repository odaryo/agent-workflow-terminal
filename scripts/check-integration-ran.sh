#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: check-integration-ran.sh --log <path> --min-tests <n> --suites <n>

統合テストが実際に実行されたことを swift test の出力から確認する。
環境変数が渡っていないと `.enabled(if:)` の suite は skip されるが、実行は成功で終わる
(実測: フラグ無しでも "Test run with 63 tests in 8 suites passed")。GREEN だけでは
「走った」と言えないため、skip が1件も無いことと件数の下限をここで検査する。

  --log <path>       swift test の出力ファイル
  --min-tests <n>    実行されたテスト件数の下限
  --suites <n>       実行された suite 数 (完全一致)
  -h, --help         このヘルプを表示
EOF
}

log=""
min_tests=""
suites=""
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
    --min-tests)
      require_value --min-tests $#
      min_tests=$2
      shift 2
      ;;
    --suites)
      require_value --suites $#
      suites=$2
      shift 2
      ;;
    *) die "不明な引数: $1" ;;
  esac
done

[[ -n "$log" ]] || die "--log は必須です"
[[ -f "$log" ]] || die "ログが見つかりません: $log"
[[ "$min_tests" =~ ^[0-9]+$ ]] || die "--min-tests には件数が必要です"
[[ "$suites" =~ ^[0-9]+$ ]] || die "--suites には suite 数が必要です"

# パイプの終端が tail なので grep の空振りは終了コードに出ない。値の有無で判定する。
summary=$(grep -E 'Test run with [0-9]+ tests? in [0-9]+ suites?' "$log" | tail -1 || true)
[[ -n "$summary" ]] || die "実行結果の要約行がログにありません: $log"

ran_tests=$(echo "$summary" | sed -E 's/.*Test run with ([0-9]+) tests? in .*/\1/')
ran_suites=$(echo "$summary" | sed -E 's/.*in ([0-9]+) suites?.*/\1/')

skipped=$(grep -c ' skipped\.' "$log" || true)

failures=0
if [[ "$skipped" -ne 0 ]]; then
  info "skip されたテストが $skipped 件あります (統合テストのフラグが渡っていない可能性):"
  grep ' skipped\.' "$log" >&2 || true
  failures=1
fi
if [[ "$ran_tests" -lt "$min_tests" ]]; then
  info "実行件数が下限を下回りました: $ran_tests < $min_tests"
  failures=1
fi
if [[ "$ran_suites" -ne "$suites" ]]; then
  info "suite 数が一致しません: $ran_suites != $suites"
  failures=1
fi

[[ "$failures" -eq 0 ]] || die "統合テストが期待どおりに実行されていません: $summary"
info "統合テストの実行を確認しました: $summary"
