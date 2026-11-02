#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: check-orphan-warning.sh

scripts/warn_orphan_processes.py (PostToolUse フックの判定本体) を fixture で検査する。
fixture は scripts/tests/orphan-warning/ 配下:

  cases/<名前>/ps-args.txt  `ps -A -o pid=,ppid=,pgid=,%cpu=,tty=,args=` の出力
  cases/<名前>/ps-comm.txt  `ps -A -o pid=,comm=` の出力
  cases/<名前>/case.txt     expect= (候補になる pid) / marked= (scratchpad の印が付く pid) /
                            cpu= (合計 %cpu)。expect が空なら何も出力しないことを期待する
  fake-ps.sh                上の 2 ファイルを返す ps の代役 (AWT_ORPHAN_WARNING_PS で差し込む)

加えて次を検査する:

  - 壊れた hook JSON・ps の失敗・ps の空の出力で、exit 0 かつ何も出力しないこと (fail-open)
  - scratchpad_dir が /tmp と /private/tmp のどちらで渡っても印が付くこと
  - 実際の ps に対して exit 0 で、hook の timeout (5 秒) 内に終わること
  - .claude/settings.json の PostToolUse フックが、実在する実行可能ファイルを指していること

  -h, --help  このヘルプを表示
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || die "引数は指定できません"

require_cmd python3

WARN="$SCRIPT_DIR/warn_orphan_processes.py"
FIXTURE_DIR="$SCRIPT_DIR/tests/orphan-warning"
FAKE_PS="$FIXTURE_DIR/fake-ps.sh"
[[ -x "$WARN" ]] || die "判定スクリプトが実行可能ではありません: $WARN"
[[ -x "$FAKE_PS" ]] || die "ps の代役が実行可能ではありません: $FAKE_PS"

# fixture を取った session の scratchpad。fixture の args に現れるパスと一致させる。
FIXTURE_SCRATCHPAD="/private/tmp/claude-501/-Users-odaryo-workspace-sample-agent-workflow-terminal/b88894b7-0d89-4dd2-9994-f4012300e1ae/scratchpad"

failures=0
checked=0

ng() {
  info "NG: $*"
  failures=$((failures + 1))
}

payload_with_scratchpad() {
  python3 -c 'import json, sys
print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash",
                  "tool_input": {"command": "true"}, "tool_response": {},
                  "scratchpad_dir": sys.argv[1]}))' "$1"
}

payload_without_scratchpad() {
  python3 -c 'import json
print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash",
                  "tool_input": {"command": "true"}, "tool_response": {}}))'
}

# 判定を1回走らせ、stdout を WARN_OUT、stderr を WARN_ERR、終了コードを WARN_RC に置く。
# $1 = ps に使うコマンド、$2 = fixture の case ディレクトリ (無ければ空)、$3 = stdin
run_warn() {
  local ps_cmd="$1" case_dir="$2" payload="$3" err_file
  err_file=$(mktemp)
  set +e
  WARN_OUT=$(printf '%s' "$payload" |
    AWT_ORPHAN_WARNING_PS="$ps_cmd" ORPHAN_FIXTURE_CASE="$case_dir" "$WARN" 2>"$err_file")
  WARN_RC=$?
  set -e
  WARN_ERR=$(cat "$err_file")
  rm -f "$err_file"
}

# stdout が PostToolUse の hookSpecificOutput であることを確かめ、additionalContext を返す。
context_of() {
  printf '%s' "$1" | python3 -c 'import json, sys
data = json.load(sys.stdin)
out = data["hookSpecificOutput"]
assert out["hookEventName"] == "PostToolUse", out
assert isinstance(out["additionalContext"], str) and out["additionalContext"], out
sys.stdout.write(out["additionalContext"])'
}

case_value() {
  local file="$1" key="$2"
  sed -n "s/^$key=//p" "$file"
}

contains_word() {
  local list="$1" word="$2" item
  for item in $list; do
    [[ "$item" == "$word" ]] && return 0
  done
  return 1
}

# 候補の一覧の行。判定スクリプトの出力の書式 `- pid <pid> (...)` に合わせている。
candidate_line() {
  printf '%s\n' "$1" | grep -E "^- pid $2 " || true
}

check_case() {
  local case_dir="$1" name expect marked cpu context all_pids pid line count bad=0
  name=$(basename "$case_dir")
  checked=$((checked + 1))
  expect=$(case_value "$case_dir/case.txt" expect)
  marked=$(case_value "$case_dir/case.txt" marked)
  cpu=$(case_value "$case_dir/case.txt" cpu)
  run_warn "$FAKE_PS" "$case_dir" "$(payload_with_scratchpad "$FIXTURE_SCRATCHPAD")"

  if [[ "$WARN_RC" -ne 0 ]]; then
    ng "$name: exit $WARN_RC (期待 exit 0)"
    [[ -z "$WARN_ERR" ]] || info "$WARN_ERR"
    return 0
  fi
  if [[ -z "$expect" ]]; then
    if [[ -n "$WARN_OUT" ]]; then
      ng "$name: 候補 0 件のはずが出力がある"
      info "$WARN_OUT"
    else
      info "OK (exit 0・出力なし): $name"
    fi
    return 0
  fi
  if [[ -z "$WARN_OUT" ]]; then
    ng "$name: 警告を期待したが何も出力されない"
    [[ -z "$WARN_ERR" ]] || info "$WARN_ERR"
    return 0
  fi
  if ! context=$(context_of "$WARN_OUT" 2>&1); then
    ng "$name: stdout が PostToolUse の hookSpecificOutput ではない"
    info "$WARN_OUT"
    info "$context"
    return 0
  fi

  all_pids=$(awk '{print $1}' "$case_dir/ps-args.txt")
  for pid in $all_pids; do
    line=$(candidate_line "$context" "$pid")
    if contains_word "$expect" "$pid"; then
      if [[ -z "$line" ]]; then
        info "  pid $pid が候補の一覧に無い"
        bad=1
        continue
      fi
      if [[ "$context" != *"kill -TERM -- -$pid"* ]]; then
        info "  pid $pid を止めるコマンド (kill -TERM -- -$pid) が無い"
        bad=1
      fi
      if contains_word "$marked" "$pid"; then
        [[ "$line" == *"[scratchpad]"* ]] || {
          info "  pid $pid に scratchpad の印が無い"
          bad=1
        }
      else
        [[ "$line" != *"[scratchpad]"* ]] || {
          info "  pid $pid に scratchpad の印が付いている"
          bad=1
        }
      fi
    elif [[ -n "$line" || "$context" == *"kill -TERM -- -$pid"* ]]; then
      info "  候補ではない pid $pid が警告に現れた"
      bad=1
    fi
  done

  count=$(wc -w <<<"$expect" | tr -d ' ')
  if [[ "$context" != *"$count 件"* ]]; then
    info "  件数 ($count 件) が無い"
    bad=1
  fi
  if [[ -n "$cpu" && "$context" != *"合計 %cpu $cpu"* ]]; then
    info "  合計 %cpu ($cpu) が無い"
    bad=1
  fi
  for needle in "自分が作ったと確かめられたものだけを止める" \
    "ほかのセッションやユーザーのプロセスには触らない" "このフックはプロセスを止めない"; do
    if [[ "$context" != *"$needle"* ]]; then
      info "  文面に「$needle」が無い"
      bad=1
    fi
  done

  if [[ "$bad" -eq 1 ]]; then
    ng "$name"
    info "$context"
  else
    info "OK (exit 0・警告 $count 件): $name"
  fi
}

info "--- fixture の判定"
for case_dir in "$FIXTURE_DIR"/cases/*/; do
  check_case "${case_dir%/}"
done

# 警告用のフックなので、判定できないときは止める側ではなく黙る側へ倒す。PreToolUse の
# guard_bash_tmux.py とは逆向きである。どれも候補のある fixture で回し、黙ったことが
# 「候補が無かったから」ではないようにする。
expect_silent() {
  local label="$1"
  checked=$((checked + 1))
  if [[ "$WARN_RC" -ne 0 ]]; then
    ng "$label: exit $WARN_RC (期待 exit 0)"
    [[ -z "$WARN_ERR" ]] || info "$WARN_ERR"
  elif [[ -n "$WARN_OUT" ]]; then
    ng "$label: 出力がある (期待: 何も出さない)"
    info "$WARN_OUT"
  else
    info "OK (exit 0・出力なし): $label"
  fi
}

info "--- 判定できないとき (fail-open)"
WARN_CASE="$FIXTURE_DIR/cases/warn-orphan-absolute"
run_warn "$FAKE_PS" "$WARN_CASE" '{"hook_event_name": "PostToolUse", "tool_na'
expect_silent "壊れた hook JSON"
run_warn "$FAKE_PS" "$WARN_CASE" '["PostToolUse"]'
expect_silent "オブジェクトではない hook JSON"
run_warn "$FAKE_PS" "$WARN_CASE" ''
expect_silent "空の stdin"
run_warn /usr/bin/false "$WARN_CASE" "$(payload_with_scratchpad "$FIXTURE_SCRATCHPAD")"
expect_silent "ps の失敗 (exit 1)"
run_warn "$FIXTURE_DIR/no-such-ps" "$WARN_CASE" "$(payload_with_scratchpad "$FIXTURE_SCRATCHPAD")"
expect_silent "ps を起動できない"
run_warn /usr/bin/true "$WARN_CASE" "$(payload_with_scratchpad "$FIXTURE_SCRATCHPAD")"
expect_silent "ps の空の出力"

info "--- scratchpad の印"
# Claude Code が /tmp で渡しても ps の args は /private/tmp で現れる (macOS の /tmp は symlink)。
checked=$((checked + 1))
run_warn "$FAKE_PS" "$WARN_CASE" "$(payload_with_scratchpad "${FIXTURE_SCRATCHPAD#/private}")"
if [[ "$WARN_RC" -eq 0 ]] && context=$(context_of "$WARN_OUT" 2>/dev/null) &&
  [[ "$(candidate_line "$context" 42110)" == *"[scratchpad]"* ]]; then
  info "OK: scratchpad_dir が /tmp/... で渡っても印が付く"
else
  ng "scratchpad_dir が /tmp/... のとき印が付かない (exit $WARN_RC)"
  info "$WARN_OUT"
fi

# scratchpad_dir が無い版 (Claude Code v2.1.257 より前) では /private/tmp/claude-<uid>/*/*/scratchpad/
# で代用する。fixture は uid 501 で取ったので、uid が違う環境では印の有無を検査できない。
checked=$((checked + 1))
run_warn "$FAKE_PS" "$WARN_CASE" "$(payload_without_scratchpad)"
if [[ "$WARN_RC" -ne 0 ]] || ! context=$(context_of "$WARN_OUT" 2>/dev/null); then
  ng "scratchpad_dir が無いとき警告が出ない (exit $WARN_RC)"
  info "$WARN_OUT"
elif [[ "$(id -u)" != "501" ]]; then
  info "OK: scratchpad_dir が無くても警告は出る (uid $(id -u) のため印の有無は検査しない)"
elif [[ "$(candidate_line "$context" 42110)" == *"[scratchpad]"* ]]; then
  info "OK: scratchpad_dir が無くても /private/tmp/claude-501/*/*/scratchpad/ で印が付く"
else
  ng "scratchpad_dir が無いとき、既定の scratchpad の形で印が付かない"
  info "$context"
fi

# 実際の ps で走らせる。候補があるかは環境次第なので、終了コードと出力の形と所要時間だけを見る。
# timeout を超えたフックは出力を捨てられ、警告が黙って消える。
info "--- 実際の ps"
checked=$((checked + 1))
real_start=$(python3 -c 'import time; print(time.monotonic())')
run_warn /bin/ps "" "$(payload_with_scratchpad "$FIXTURE_SCRATCHPAD")"
real_elapsed=$(python3 -c 'import sys, time; print("%.2f" % (time.monotonic() - float(sys.argv[1])))' "$real_start")
if [[ "$WARN_RC" -ne 0 ]]; then
  ng "実際の ps: exit $WARN_RC"
  info "$WARN_ERR"
elif [[ -n "$WARN_OUT" ]] && ! context_of "$WARN_OUT" >/dev/null 2>&1; then
  ng "実際の ps: stdout が PostToolUse の hookSpecificOutput ではない"
  info "$WARN_OUT"
elif python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 5 else 1)' "$real_elapsed"; then
  info "OK (exit 0・${real_elapsed} 秒・出力 ${#WARN_OUT} 文字): 実際の ps"
else
  ng "実際の ps: ${real_elapsed} 秒 (hook の timeout 5 秒以内を期待)"
fi

# フックの配線そのものを検査する。判定本体がいくら正しくても、settings.json のパスが
# typo・rebase 事故・exec bit 喪失で壊れていれば、警告は黙って消える。
info "--- .claude/settings.json の配線"
repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"
settings="$repo_root/.claude/settings.json"
checked=$((checked + 1))
if [[ ! -f "$settings" ]]; then
  ng "$settings がありません"
else
  hook_commands=$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in data.get("hooks", {}).get("PostToolUse", []):
    if entry.get("matcher") != "Bash":
        continue
    for hook in entry.get("hooks", []):
        if hook.get("type") == "command" and "warn_orphan_processes" in hook.get("command", ""):
            print(hook.get("command", ""))
' "$settings")
  if [[ -z "$hook_commands" ]]; then
    ng "PostToolUse / matcher \"Bash\" に warn_orphan_processes.py のフックが登録されていません"
  else
    wiring_bad=0
    while IFS= read -r hook_command; do
      # ${CLAUDE_PROJECT_DIR} はセッション起動時のプロジェクトルート。ここでは repo root。
      hook_path="${hook_command//\$\{CLAUDE_PROJECT_DIR\}/$repo_root}"
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
      info "OK: PostToolUse (Bash) のフックが実行可能ファイルを指している"
    fi
  fi
fi

info ""
[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
