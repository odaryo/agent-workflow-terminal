#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: check-tmux-kill-guard.sh

scripts/guard_bash_tmux.py (PreToolUse フックの判定本体) を fixture で検査する。
fixture は scripts/tests/tmux-kill-guard/ 配下:

  deny-commands.txt   exit 2 (拒否) を期待するコマンド。`%%` 行で区切る
  allow-commands.txt  exit 0 (通過) を期待するコマンド。書式は同じ
  deny-payloads/      hook JSON そのものを与える異常系。すべて exit 2 を期待する

加えて次を検査する:

  - 拒否メッセージが次に取るべき行動を含むこと
  - .claude/settings.json の PreToolUse フックが、実在する実行可能ファイルを指していること
  - 大きな入力でも hook の timeout 内に判定が終わること (二次計算量への退行検出)

  -h, --help  このヘルプを表示
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || die "引数は指定できません"

require_cmd python3

GUARD="$SCRIPT_DIR/guard_bash_tmux.py"
FIXTURE_DIR="$SCRIPT_DIR/tests/tmux-kill-guard"
[[ -x "$GUARD" ]] || die "判定スクリプトが実行可能ではありません: $GUARD"

current_fixture_file=""
seen_separator=0
failures=0
checked=0

# フックへ渡される JSON を組み立てて判定を1回走らせる。標準エラーは caller が読めるよう返す。
run_guard() {
  local payload="$1" out rc
  set +e
  out=$(printf '%s' "$payload" | "$GUARD" 2>&1)
  rc=$?
  set -e
  GUARD_OUT="$out"
  return "$rc"
}

# 判定本体と同じく python3 で組み立てる。argv ではなく標準入力で渡すのは、1MB 級の
# fixture が ARG_MAX に当たるため (実測: jq --arg で Argument list too long)。
payload_for() {
  printf '%s' "$1" | python3 -c 'import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": sys.stdin.read()}}))'
}

expect_rc() {
  local want="$1" label="$2" payload="$3" rc=0
  checked=$((checked + 1))
  run_guard "$payload" || rc=$?
  if [[ "$rc" -ne "$want" ]]; then
    info "NG (期待 exit $want / 実際 exit $rc): $label"
    if [[ -n "$GUARD_OUT" ]]; then info "$GUARD_OUT"; fi
    failures=$((failures + 1))
    return 0
  fi
  info "OK (exit $rc): $label"
}

submit_block() {
  local want="$1" block="$2" started="$3" label
  # コメントだけのブロックは「無かったこと」にせず失敗させる。fixture を足したつもりで
  # 1 件も検査されない状態を、緑のまま見逃さないため (レビュー m4)。
  if [[ "$started" -eq 0 ]]; then
    [[ "$seen_separator" -eq 0 ]] || die "空の fixture ブロックがあります ($current_fixture_file)"
    return 0
  fi
  # 複数行の fixture も 1 行のラベルで見えるようにする (tr はバイト単位なので使わない)
  label="${block//$'\n'/⏎}"
  expect_rc "$want" "$label" "$(payload_for "$block")"
}

# fixture を `%%` 区切りのブロックとして読み、want の exit code を期待して 1 件ずつ流す。
# 行区切りにしないのは、行継続と heredoc が複数行のコマンドとして表現されるから
# (レビュー C1 / M3 の再現にはその形そのものが要る)。
run_fixture_file() {
  local file="$1" want="$2" line block="" started=0
  [[ -f "$file" ]] || die "fixture がありません: $file"
  current_fixture_file="$file"
  seen_separator=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "%%" ]]; then
      submit_block "$want" "$block" "$started"
      seen_separator=1
      block=""
      started=0
      continue
    fi
    # ブロック先頭の `#` 行と空行だけがコメント。2 行目以降は heredoc 本文でありうる。
    if [[ "$started" -eq 0 ]] && { [[ "$line" == \#* ]] || [[ -z "$line" ]]; }; then
      continue
    fi
    started=1
    if [[ -n "$block" ]]; then block="$block"$'\n'"$line"; else block="$line"; fi
  done <"$file"
  submit_block "$want" "$block" "$started"
}

info "--- 拒否を期待するコマンド"
run_fixture_file "$FIXTURE_DIR/deny-commands.txt" 2

info "--- 通過を期待するコマンド"
run_fixture_file "$FIXTURE_DIR/allow-commands.txt" 0

info "--- 判定できない hook JSON (fail-closed)"
for payload_file in "$FIXTURE_DIR"/deny-payloads/*.json; do
  expect_rc 2 "$(basename "$payload_file")" "$(cat "$payload_file")"
done

# 拒否メッセージが次に取るべき行動を示していること。文言が痩せると、拒否されたエージェントが
# 別綴りを試す方向へ流れる (Issue #314 の完了条件)。
info "--- 拒否メッセージの内容"
checked=$((checked + 1))
run_guard "$(payload_for "tmux kill-server")" || true
missing=""
for needle in "別綴り" "kill-session -t '=" "ユーザーに依頼"; do
  case "$GUARD_OUT" in
    *"$needle"*) ;;
    *) missing="$missing $needle" ;;
  esac
done
if [[ -n "$missing" ]]; then
  info "NG: 拒否メッセージに次の語が含まれていません:$missing"
  info "$GUARD_OUT"
  failures=$((failures + 1))
else
  info "OK: 拒否メッセージは次に取るべき行動を含む"
fi

# 大きな入力でも hook の timeout 内に終わること。判定本体を 1 文字ずつ組み立てていた
# bash 実装は入力長に対して二次で、20KB で 3〜34 秒かかっていた (実測 2026-09-09)。
# timeout を超えたフックはツール呼び出しを止めないため、これは拒否ではなく素通りとして現れる。
#
# **最速の形だけを測らないこと。** bash 実装は heredoc の一括ジャンプが効く形 (引用した
# 区切り語 + 特殊文字の少ない本文) では速く、他の 3 形で二次が残っていた。1 形しか測って
# いなかったせいで同じ Critical が 2 度出ている。
info "--- 大きな入力の所要時間 (二次計算量への退行検出)"
# 測定点は 125,000 字と、受理上限 (1,000,000 字) の直下 990,000 字。上限超過は長さ検査で
# 即 deny になり走査されないので、上限直下を測らないと「上限までは間に合う」を主張できない。
for perf_case in \
  "hd_quoted_plain 125000" "hd_unquoted_md 125000" "many_words 125000" "dquote_dollars 125000" \
  "many_words 990000"; do
  # shellcheck disable=SC2086 # 形とサイズの 2 語に分けるため意図的に quote しない
  set -- $perf_case
  perf_shape="$1"
  perf_size="$2"
  checked=$((checked + 1))
  perf_cmd=$(python3 "$FIXTURE_DIR/make-perf-command.py" "$perf_shape" "$perf_size")
  perf_start=$SECONDS
  perf_rc=0
  run_guard "$(payload_for "$perf_cmd")" || perf_rc=$?
  perf_elapsed=$((SECONDS - perf_start))
  if [[ "$perf_elapsed" -gt 5 ]]; then
    info "NG (5 秒以内を期待 / 実際 ${perf_elapsed} 秒): $perf_shape (${#perf_cmd} 文字)"
    failures=$((failures + 1))
  else
    info "OK (exit ${perf_rc}・${perf_elapsed} 秒): $perf_shape (${#perf_cmd} 文字)"
  fi
done

# 上限を超える入力は、黙って timeout させず拒否側に倒すこと。
info "--- 上限を超える長さ (fail-closed)"
checked=$((checked + 1))
huge_cmd=$(python3 -c '
import sys
unit = "事故の記録: tmux kill-server を打たない。"
sys.stdout.write("echo " + unit * (1000001 // len(unit) + 1))')
huge_rc=0
run_guard "$(payload_for "$huge_cmd")" || huge_rc=$?
if [[ "$huge_rc" -ne 2 ]]; then
  info "NG (期待 exit 2 / 実際 exit $huge_rc): ${#huge_cmd} 文字"
  failures=$((failures + 1))
elif [[ "$GUARD_OUT" != *"--body-file"* ]]; then
  info "NG: 長さ超過の拒否メッセージが回復手段 (--body-file) を示していません"
  info "$GUARD_OUT"
  failures=$((failures + 1))
else
  info "OK (exit 2): ${#huge_cmd} 文字"
fi

# フックの配線そのものを検査する。判定本体がいくら正しくても、settings.json のパスが
# typo・rebase 事故・exec bit 喪失で壊れていれば、ガードは黙って無効になる。
info "--- .claude/settings.json の配線"
settings="$(cd "$SCRIPT_DIR/.." && pwd)/.claude/settings.json"
checked=$((checked + 1))
if [[ ! -f "$settings" ]]; then
  info "NG: $settings がありません"
  failures=$((failures + 1))
else
  hook_commands=$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in data.get("hooks", {}).get("PreToolUse", []):
    if entry.get("matcher") != "Bash":
        continue
    for hook in entry.get("hooks", []):
        if hook.get("type") == "command":
            print(hook.get("command", ""))
' "$settings")
  if [[ -z "$hook_commands" ]]; then
    info "NG: PreToolUse / matcher \"Bash\" の command フックが登録されていません"
    failures=$((failures + 1))
  else
    wiring_bad=0
    while IFS= read -r hook_command; do
      # ${CLAUDE_PROJECT_DIR} はセッション起動時のプロジェクトルート。ここでは repo root。
      hook_path="${hook_command//\$\{CLAUDE_PROJECT_DIR\}/$(cd "$SCRIPT_DIR/.." && pwd)}"
      hook_path="${hook_path%\"}"
      hook_path="${hook_path#\"}"
      hook_path="${hook_path%% *}"
      if [[ ! -x "$hook_path" ]]; then
        info "NG: フックが実行可能ファイルを指していません: $hook_command -> $hook_path"
        wiring_bad=1
      fi
    done <<<"$hook_commands"
    if [[ "$wiring_bad" -eq 1 ]]; then
      failures=$((failures + 1))
    else
      info "OK: PreToolUse (Bash) のフックが実行可能ファイルを指している"
    fi
  fi
fi

info ""
[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
