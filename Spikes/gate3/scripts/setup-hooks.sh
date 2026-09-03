#!/usr/bin/env bash
# S3 (Tier B) 計測用に、作業ディレクトリ側へ hook 設定を置く。
# アプリがユーザーの設定を書き換えてよいかは設計判断であり、ここでは可否だけを見る (PLAN.md §4.3)。
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

log="$G3_WORK/hook-events.jsonl"
: >"$log"

emit="$G3_WORK/emit-hook.sh"
cat >"$emit" <<'SH'
#!/bin/sh
# stdin の payload をそのまま残す。どの状態へ写像できるかは後段で決める。
payload=$(cat)
printf '{"ts":%s,"event":"%s","payload":%s}\n' \
  "$(perl -MTime::HiRes=time -e 'printf "%.3f", time()')" "$1" \
  "$(printf '%s' "$payload" | python3 -c 'import json,sys; d=sys.stdin.read(); print(json.dumps(d))')" \
  >>"$2"
exit 0
SH
chmod +x "$emit"

mkdir -p "$G3_WORK/.claude"
python3 - "$G3_WORK/.claude/settings.json" "$emit" "$log" <<'PY'
import json, sys
out, emit, log = sys.argv[1:4]
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "PermissionRequest", "Notification", "Stop", "SessionEnd"]
hooks = {e: [{"hooks": [{"type": "command", "command": f"{emit} {e} {log}"}]}] for e in events}
json.dump({"hooks": hooks}, open(out, "w"), indent=2)
PY

mkdir -p "$G3_WORK/.codex"
python3 - "$G3_WORK/.codex/hooks.json" "$emit" "$log" <<'PY'
import json, sys
out, emit, log = sys.argv[1:4]
# codex のバイナリ内では hook イベント名は Claude Code と同じ CamelCase で持たれている (M1 調査)。
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "PermissionRequest", "Stop", "SessionEnd"]
hooks = {e: [{"type": "command", "command": [emit, e, log]}] for e in events}
json.dump({"hooks": hooks}, open(out, "w"), indent=2)
PY

echo "hook log: $log"
cat "$G3_WORK/.claude/settings.json" | head -12
