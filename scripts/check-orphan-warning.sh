#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: check-orphan-warning.sh

scripts/warn_orphan_processes.py (PostToolUse / PostToolUseFailure フックの判定本体) を fixture で
検査する。fixture は scripts/tests/orphan-warning/ 配下:

  cases/<名前>/ps-args.txt  `ps -A -o pid=,ppid=,pgid=,uid=,%cpu=,tty=,args=` の出力
  cases/<名前>/ps-comm.txt  `ps -A -o pid=,comm=` の出力
  cases/<名前>/case.txt     expect= (候補になる pid) / marked= (scratchpad の印が付く pid) /
                            cpu= (合計 %cpu)。expect が空なら何も出力しないことを期待する
  fake-ps.sh                上の 2 ファイルを返す ps の代役 (AWT_ORPHAN_WARNING_PS で差し込む)
  make-scale-case.py        候補が n 件ある fixture を作る (規模の検査用)

fixture は uid 501 で取ったので、fixture を使う検査では AWT_ORPHAN_WARNING_UID=501 を渡す。

加えて次を検査する:

  - 入力の hook_event_name を hookEventName に返すこと (PostToolUseFailure を含む)
  - 候補が 120 件・200,000 件でも additionalContext が 8,000 字以内で、先頭 2,000 字に件数と
    止め方が入ること (Claude Code は 10,000 字を超えると先頭 2,000 字しか見せない)
  - 壊れた hook JSON・ps の失敗・ps の空の出力で、exit 0 かつ何も出力しないこと (fail-open)
  - 遅い ps でも、2 回の ps の合計が期限 (3.5 秒) で打ち切られること
  - scratchpad_dir の綴りと、scratchpad_dir が無いときの印
  - 実際の ps に対して exit 0 で、hook の timeout (5 秒) 内に終わること
  - scripts/stop-tty-processes.sh が tty でない引数を拒否すること
  - .claude/settings.json の PostToolUse / PostToolUseFailure フックが、実行可能ファイルを指していること

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
STOP="$SCRIPT_DIR/stop-tty-processes.sh"
FIXTURE_DIR="$SCRIPT_DIR/tests/orphan-warning"
FAKE_PS="$FIXTURE_DIR/fake-ps.sh"
[[ -x "$WARN" ]] || die "判定スクリプトが実行可能ではありません: $WARN"
[[ -x "$FAKE_PS" ]] || die "ps の代役が実行可能ではありません: $FAKE_PS"

# fixture を取った session の scratchpad。fixture の args に現れるパスと一致させる。
FIXTURE_SCRATCHPAD="/private/tmp/claude-501/-Users-odaryo-workspace-sample-agent-workflow-terminal/b88894b7-0d89-4dd2-9994-f4012300e1ae/scratchpad"
FIXTURE_UID=501
CONTEXT_LIMIT=8000
PREVIEW_CHARS=2000

work_dir=$(mktemp -d)
# bash 3.2 は EXIT の trap があると、展開のエラーで止まっても exit 0 を返す。
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

ng() {
  info "NG: $*"
  failures=$((failures + 1))
}

# $1 = hook_event_name (空なら入れない)、$2 = scratchpad_dir (空なら入れない)
payload() {
  python3 -c 'import json, sys
data = {"tool_name": "Bash", "tool_input": {"command": "true"}, "tool_response": {}}
if sys.argv[1]:
    data["hook_event_name"] = sys.argv[1]
if sys.argv[2]:
    data["scratchpad_dir"] = sys.argv[2]
print(json.dumps(data))' "$1" "$2"
}

DEFAULT_PAYLOAD=$(payload PostToolUse "$FIXTURE_SCRATCHPAD")

# 判定を1回走らせ、stdout を WARN_OUT、stderr を WARN_ERR、終了コードを WARN_RC、所要秒を
# WARN_SECONDS に置く。$1 = ps に使うコマンド、$2 = fixture の case ディレクトリ (無ければ空)、
# $3 = stdin、$4 = 判定に使わせる uid (空なら判定スクリプト自身の uid)。
run_warn() {
  local ps_cmd="$1" case_dir="$2" stdin="$3" uid="${4-$FIXTURE_UID}" err_file started
  err_file="$work_dir/stderr"
  started=$(python3 -c 'import time; print(time.monotonic())')
  set +e
  WARN_OUT=$(printf '%s' "$stdin" |
    AWT_ORPHAN_WARNING_PS="$ps_cmd" AWT_ORPHAN_WARNING_UID="$uid" \
      ORPHAN_FIXTURE_CASE="$case_dir" "$WARN" 2>"$err_file")
  WARN_RC=$?
  set -e
  WARN_SECONDS=$(python3 -c 'import sys, time; print("%.2f" % (time.monotonic() - float(sys.argv[1])))' "$started")
  WARN_ERR=$(cat "$err_file")
}

# stdout が hookSpecificOutput であり、hookEventName が $2 であることを確かめ、additionalContext を返す。
context_of() {
  printf '%s' "$1" | python3 -c 'import json, sys
data = json.load(sys.stdin)
out = data["hookSpecificOutput"]
assert out["hookEventName"] == sys.argv[1], out["hookEventName"]
assert isinstance(out["additionalContext"], str) and out["additionalContext"], out
sys.stdout.write(out["additionalContext"])' "${2:-PostToolUse}"
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

seconds_below() {
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)' "$1" "$2"
}

check_case() {
  local case_dir="$1" name expect marked cpu context all_pids pid line count listed bad=0
  name=$(basename "$case_dir")
  checked=$((checked + 1))
  expect=$(case_value "$case_dir/case.txt" expect)
  marked=$(case_value "$case_dir/case.txt" marked)
  cpu=$(case_value "$case_dir/case.txt" cpu)
  run_warn "$FAKE_PS" "$case_dir" "$DEFAULT_PAYLOAD"

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
  # 「1 件」の部分一致だと「種類 A (1 件)」にも当たるので、見出しの書式で比べる。fixture の
  # 1 列目に無い pid (列が壊れた行を読み違えたもの) を見落とさないよう、一覧の行数も比べる。
  if [[ "$context" != *"が $count 件あります"* ]]; then
    info "  見出しの件数 (が $count 件あります) が無い"
    bad=1
  fi
  listed=$(printf '%s\n' "$context" | grep -c '^- pid ' || true)
  if [[ "$listed" -ne "$count" ]]; then
    info "  一覧の行数が $listed (期待 $count)"
    bad=1
  fi
  if [[ -n "$cpu" && "$context" != *"合計 %cpu $cpu"* ]]; then
    info "  合計 %cpu ($cpu) が無い"
    bad=1
  fi
  for needle in "自分が作ったと確かめられたものだけを止める" \
    "ほかのセッションやユーザーのプロセスには触らない" "このフックはプロセスを止めない"; do
    if [[ "$context" != *"$needle"* ]]; then
      info "  文面に「${needle}」が無い"
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

# 種類 A (端末あり) と種類 B (端末を失った高 CPU) を、文面の上でも分けていること。
info "--- 種類 A と種類 B の文面"
checked=$((checked + 1))
run_warn "$FAKE_PS" "$FIXTURE_DIR/cases/warn-mixed" "$DEFAULT_PAYLOAD"
if context=$(context_of "$WARN_OUT" 2>/dev/null) &&
  [[ "$context" == *"種類 A (3 件)"* && "$context" == *"種類 B (2 件)"* &&
    "$context" == *"正当な常駐の可能性もある"* ]] &&
  [[ "$(candidate_line "$context" 78871)" == *"端末なし"* ]] &&
  [[ "$(candidate_line "$context" 78858)" == *"ttys008"* ]]; then
  info "OK: 種類 A 3 件と種類 B 2 件を分けて書き、B の行に「端末なし」と書く"
else
  ng "種類 A と種類 B の書き分けが期待と異なる"
  info "$WARN_OUT"
fi

info "--- hookEventName"
for event in PostToolUse PostToolUseFailure; do
  checked=$((checked + 1))
  run_warn "$FAKE_PS" "$FIXTURE_DIR/cases/warn-a-orphan-absolute" "$(payload "$event" "$FIXTURE_SCRATCHPAD")"
  if context_of "$WARN_OUT" "$event" >/dev/null 2>&1; then
    info "OK: hook_event_name=$event → hookEventName=$event"
  else
    ng "hook_event_name=$event のとき hookEventName が $event ではない"
    info "$WARN_OUT"
  fi
done
checked=$((checked + 1))
run_warn "$FAKE_PS" "$FIXTURE_DIR/cases/warn-a-orphan-absolute" "$(payload "" "$FIXTURE_SCRATCHPAD")"
if context_of "$WARN_OUT" PostToolUse >/dev/null 2>&1; then
  info "OK: hook_event_name が無いとき hookEventName=PostToolUse"
else
  ng "hook_event_name が無いとき hookEventName が PostToolUse ではない"
  info "$WARN_OUT"
fi

# Claude Code は additionalContext が 10,000 字を超えるとファイルへ逃がし、先頭 2,000 字しか見せない
# (公式 hooks ドキュメント)。#517 では 120 件残った。
info "--- 候補が多いときの字数"
for scale in "warn-a-orphan-absolute 120" "warn-a-orphan-relative 200000"; do
  # shellcheck disable=SC2086 # 元の case と件数の 2 語に分けるため意図的に quote しない
  set -- $scale
  checked=$((checked + 1))
  scale_dir="$work_dir/scale-$2"
  python3 "$FIXTURE_DIR/make-scale-case.py" "$FIXTURE_DIR/cases/$1" "$2" "$scale_dir"
  run_warn "$FAKE_PS" "$scale_dir" "$DEFAULT_PAYLOAD"
  if [[ "$WARN_RC" -ne 0 ]] || ! context=$(context_of "$WARN_OUT" 2>/dev/null); then
    ng "$2 件: 警告が出ない (exit $WARN_RC)"
    [[ -z "$WARN_ERR" ]] || info "$WARN_ERR"
    continue
  fi
  length=${#context}
  preview="${context:0:$PREVIEW_CHARS}"
  missing=""
  for needle in "$2 件" "kill -TERM -- -100000" "kill -KILL" "自分が作ったと確かめられたものだけを止める"; do
    [[ "$preview" == *"$needle"* ]] || missing="${missing}「${needle}」"
  done
  if [[ "$length" -gt "$CONTEXT_LIMIT" ]]; then
    ng "$2 件: additionalContext が $length 字 (${CONTEXT_LIMIT} 字以内を期待)"
  elif [[ -n "$missing" ]]; then
    ng "$2 件: 先頭 $PREVIEW_CHARS 字に $missing が無い"
    info "$preview"
  elif [[ "$context" != *"ほか "*" 件"* ]]; then
    ng "$2 件: 載せきれなかった件数 (ほか N 件) が無い"
  else
    info "OK ($length 字・${WARN_SECONDS} 秒): $2 件"
  fi
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
    info "OK (exit 0・出力なし・${WARN_SECONDS} 秒): $label"
  fi
}

info "--- 判定できないとき (fail-open)"
WARN_CASE="$FIXTURE_DIR/cases/warn-a-orphan-absolute"
run_warn "$FAKE_PS" "$WARN_CASE" '{"hook_event_name": "PostToolUse", "tool_na'
expect_silent "壊れた hook JSON"
run_warn "$FAKE_PS" "$WARN_CASE" '["PostToolUse"]'
expect_silent "オブジェクトではない hook JSON"
run_warn "$FAKE_PS" "$WARN_CASE" ''
expect_silent "空の stdin"
run_warn /usr/bin/false "$WARN_CASE" "$DEFAULT_PAYLOAD"
expect_silent "ps の失敗 (exit 1)"
run_warn "$FIXTURE_DIR/no-such-ps" "$WARN_CASE" "$DEFAULT_PAYLOAD"
expect_silent "ps を起動できない"
run_warn /usr/bin/true "$WARN_CASE" "$DEFAULT_PAYLOAD"
expect_silent "ps の空の出力"

# 期限は 2 回の ps で共有する。1 回ごとの期限だと、3 秒かかる ps が 2 回で 6 秒になり、hook の
# timeout (5 秒) を超えて出力ごと捨てられる。
info "--- 遅い ps (期限 3.5 秒を 2 回で共有)"
checked=$((checked + 1))
FAKE_PS_SLEEP=3 run_warn "$FAKE_PS" "$WARN_CASE" "$DEFAULT_PAYLOAD"
if [[ "$WARN_RC" -ne 0 || -n "$WARN_OUT" ]]; then
  ng "遅い ps: exit ${WARN_RC}・出力 ${#WARN_OUT} 文字 (期待: exit 0・出力なし)"
elif seconds_below "$WARN_SECONDS" 4.5; then
  info "OK (exit 0・出力なし・${WARN_SECONDS} 秒): 1 回 3 秒かかる ps"
else
  ng "遅い ps: ${WARN_SECONDS} 秒 (4.5 秒未満を期待)"
fi
checked=$((checked + 1))
FAKE_PS_SLEEP=1 run_warn "$FAKE_PS" "$WARN_CASE" "$DEFAULT_PAYLOAD"
if [[ "$WARN_RC" -eq 0 ]] && context_of "$WARN_OUT" >/dev/null 2>&1; then
  info "OK (exit 0・警告あり・${WARN_SECONDS} 秒): 1 回 1 秒かかる ps は期限内に終わる"
else
  ng "1 回 1 秒かかる ps で警告が出ない (exit $WARN_RC)"
fi

info "--- scratchpad の印"
# Claude Code が /tmp で渡しても ps の args は /private/tmp で現れうる (macOS の /tmp は symlink)。
# 逆向き (args が /tmp) は fixture の warn-tmp-spelling が見る。
checked=$((checked + 1))
run_warn "$FAKE_PS" "$WARN_CASE" "$(payload PostToolUse "${FIXTURE_SCRATCHPAD#/private}")"
if [[ "$WARN_RC" -eq 0 ]] && context=$(context_of "$WARN_OUT" 2>/dev/null) &&
  [[ "$(candidate_line "$context" 78858)" == *"[scratchpad]"* ]]; then
  info "OK: scratchpad_dir が /tmp/... で渡っても印が付く"
else
  ng "scratchpad_dir が /tmp/... のとき印が付かない (exit $WARN_RC)"
  info "$WARN_OUT"
fi

# scratchpad_dir が無い版 (Claude Code v2.1.257 より前) では /private/tmp/claude-<uid>/*/*/scratchpad/
# で代用する。uid は AWT_ORPHAN_WARNING_UID で fixture の 501 に揃えている。
checked=$((checked + 1))
run_warn "$FAKE_PS" "$WARN_CASE" "$(payload PostToolUse "")"
if [[ "$WARN_RC" -eq 0 ]] && context=$(context_of "$WARN_OUT" 2>/dev/null) &&
  [[ "$(candidate_line "$context" 78858)" == *"[scratchpad]"* ]]; then
  info "OK: scratchpad_dir が無くても /private/tmp/claude-501/*/*/scratchpad/ で印が付く"
else
  ng "scratchpad_dir が無いとき、既定の scratchpad の形で印が付かない (exit $WARN_RC)"
  info "$WARN_OUT"
fi

# 実際の ps で走らせる。候補があるかは環境次第なので、終了コードと出力の形と所要時間だけを見る。
# timeout を超えたフックは出力を捨てられ、警告が黙って消える。
info "--- 実際の ps"
checked=$((checked + 1))
run_warn /bin/ps "" "$DEFAULT_PAYLOAD" ""
if [[ "$WARN_RC" -ne 0 ]]; then
  ng "実際の ps: exit $WARN_RC"
  info "$WARN_ERR"
elif [[ -n "$WARN_OUT" ]] && ! context_of "$WARN_OUT" >/dev/null 2>&1; then
  ng "実際の ps: stdout が PostToolUse の hookSpecificOutput ではない"
  info "$WARN_OUT"
elif seconds_below "$WARN_SECONDS" 5; then
  info "OK (exit 0・${WARN_SECONDS} 秒・出力 ${#WARN_OUT} 文字): 実際の ps"
else
  ng "実際の ps: ${WARN_SECONDS} 秒 (hook の timeout 5 秒以内を期待)"
fi

# 後始末のスクリプトは、tty でないものを渡されたら何も止めずに断ること。`??` を通すと、
# 端末を持たないプロセス全部 (このシェルを含む) の pgid へ signal を送る。
info "--- stop-tty-processes.sh の引数"
for bad_arg in "" "??" "-1" "0" "/dev/null"; do
  checked=$((checked + 1))
  if [[ -z "$bad_arg" ]]; then
    stop_rc=0
    "$STOP" >/dev/null 2>&1 || stop_rc=$?
  else
    stop_rc=0
    "$STOP" "$bad_arg" >/dev/null 2>&1 || stop_rc=$?
  fi
  if [[ "$stop_rc" -eq 0 ]]; then
    ng "stop-tty-processes.sh が '$bad_arg' を受け付けた"
  else
    info "OK (exit $stop_rc): stop-tty-processes.sh は '$bad_arg' を拒否する"
  fi
done

# フックの配線そのものを検査する。判定本体がいくら正しくても、settings.json のパスが
# typo・rebase 事故・exec bit 喪失で壊れていれば、警告は黙って消える。
info "--- .claude/settings.json の配線"
repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"
settings="$repo_root/.claude/settings.json"
for event in PostToolUse PostToolUseFailure; do
  checked=$((checked + 1))
  if [[ ! -f "$settings" ]]; then
    ng "$settings がありません"
    continue
  fi
  hook_commands=$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in data.get("hooks", {}).get(sys.argv[2], []):
    if entry.get("matcher") != "Bash":
        continue
    for hook in entry.get("hooks", []):
        if hook.get("type") == "command" and "warn_orphan_processes" in hook.get("command", ""):
            print(hook.get("command", ""))
' "$settings" "$event")
  if [[ -z "$hook_commands" ]]; then
    ng "$event / matcher \"Bash\" に warn_orphan_processes.py のフックが登録されていません"
    continue
  fi
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
    info "OK: $event (Bash) のフックが実行可能ファイルを指している"
  fi
done

info ""
[[ "$failures" -eq 0 ]] || die "$checked 件中 $failures 件が期待と異なります"
info "$checked 件すべて期待どおりです"
__awt_finished=1
