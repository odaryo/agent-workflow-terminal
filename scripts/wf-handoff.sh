#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH=${BASH_SOURCE[0]}
if [[ "$SCRIPT_PATH" == */* ]]; then
  SCRIPT_DIR=${SCRIPT_PATH%/*}
else
  SCRIPT_DIR=.
fi
SCRIPT_DIR=$(cd -- "$SCRIPT_DIR" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-handoff.sh <capture|seal|show>

Claude Code の hook から前セッションの最終応答を自動で引き継ぐ。
  capture     Stop hook の JSON を stdin から読み、最終応答を保存する
  seal        SessionEnd hook の JSON を stdin から読み、引き継ぎを確定する
  show        SessionStart hook で前セッションの引き継ぎを stdout へ表示する
  -h, --help  このヘルプを表示

通常は hook が自動で呼び出すため、人が直接実行する必要はありません。
EOF
}

# hook の失敗をセッションへ波及させないため、lib.sh が有効にした fail-fast をここでは使わない。
set +e
set +u
set +o pipefail

handoff_dir() {
  local common_dir common_parent base key

  common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  if [[ "$common_dir" != /* ]]; then
    common_dir="$(pwd)/$common_dir"
  fi
  common_parent=$(cd -- "$(dirname -- "$common_dir")" 2>/dev/null && pwd -P) || return 1
  key=${common_parent//\//-}

  if [[ -n "${AWT_HANDOFF_DIR:-}" ]]; then
    base=$AWT_HANDOFF_DIR
  elif [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    base="$CLAUDE_CONFIG_DIR/handoff"
  elif [[ -n "${HOME:-}" ]]; then
    base="$HOME/.claude/handoff"
  else
    return 1
  fi

  printf '%s/%s\n' "$base" "$key"
}

read_input() {
  cat 2>/dev/null
}

json_value_or_unknown() {
  local input=$1 field=$2 value
  value=$(printf '%s' "$input" | jq -r --arg field "$field" \
    'if has($field) and .[$field] != null then .[$field] else "unknown" end | tostring' \
    2>/dev/null) || value=unknown
  [[ -n "$value" ]] || value=unknown
  printf '%s' "$value"
}

yaml_string() {
  jq -Rn --arg value "$1" '$value'
}

capture() {
  local input dir message temporary

  input=$(read_input)
  printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 || {
    info "wf-handoff: Stop hook の JSON を読めませんでした"
    return
  }

  # Claude Code 2.1.260 ではサブエージェントは SubagentStop に届く。Stop の範囲が広がった場合の上書きを防ぐ将来防御。
  printf '%s' "$input" | jq -e 'has("agent_id")' >/dev/null 2>&1 && return

  message=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null) || {
    info "wf-handoff: last_assistant_message を読めませんでした"
    return
  }
  [[ -n "$message" ]] || return

  dir=$(handoff_dir) || {
    info "wf-handoff: Git common directory から保存先を決められませんでした"
    return
  }
  mkdir -p -- "$dir" 2>/dev/null || {
    info "wf-handoff: 保存先を作成できませんでした: $dir"
    return
  }
  temporary=$(mktemp "$dir/.last-turn.XXXXXX" 2>/dev/null) || {
    info "wf-handoff: 一時ファイルを作成できませんでした"
    return
  }
  printf '%s\n' "$message" >"$temporary" 2>/dev/null || {
    info "wf-handoff: 最終応答を書き込めませんでした"
    return
  }
  mv -f -- "$temporary" "$dir/last-turn.md" 2>/dev/null || \
    info "wf-handoff: 最終応答を保存できませんでした"
}

seal() {
  local input dir last_turn session_id reason sealed_at branch worktrees temporary

  input=$(read_input)
  dir=$(handoff_dir) || {
    info "wf-handoff: Git common directory から保存先を決められませんでした"
    return
  }
  last_turn="$dir/last-turn.md"
  [[ -f "$last_turn" ]] || return

  session_id=$(json_value_or_unknown "$input" session_id)
  reason=$(json_value_or_unknown "$input" reason)
  sealed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  [[ -n "$sealed_at" ]] || sealed_at=unknown
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  [[ -n "$branch" ]] || branch=unknown
  worktrees=$(git worktree list 2>/dev/null)
  [[ -n "$worktrees" ]] || worktrees=unknown

  temporary=$(mktemp "$dir/.handoff.XXXXXX" 2>/dev/null) || {
    info "wf-handoff: 一時ファイルを作成できませんでした"
    return
  }
  {
    echo '---'
    printf 'sealed_at: %s\n' "$(yaml_string "$sealed_at")"
    printf 'session_id: %s\n' "$(yaml_string "$session_id")"
    printf 'reason: %s\n' "$(yaml_string "$reason")"
    printf 'branch: %s\n' "$(yaml_string "$branch")"
    echo 'worktrees: |'
    printf '%s\n' "$worktrees" | sed 's/^/  /'
    echo '---'
    cat -- "$last_turn"
  } >"$temporary" 2>/dev/null || {
    info "wf-handoff: 引き継ぎを書き込めませんでした"
    return
  }
  mv -f -- "$temporary" "$dir/handoff.md" 2>/dev/null || \
    info "wf-handoff: 引き継ぎを確定できませんでした"
}

frontmatter_value() {
  local file=$1 field=$2 encoded value
  encoded=$(sed -n "s/^${field}: //p" "$file" 2>/dev/null | head -n 1)
  value=$(printf '%s' "$encoded" | jq -r '.' 2>/dev/null) || value=unknown
  [[ -n "$value" && "$value" != null ]] || value=unknown
  printf '%s' "$value"
}

is_older_than_seven_days() {
  local sealed_at=$1 sealed_epoch now_epoch
  sealed_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$sealed_at" '+%s' 2>/dev/null)
  if [[ -z "$sealed_epoch" ]]; then
    sealed_epoch=$(date -u -d "$sealed_at" '+%s' 2>/dev/null)
  fi
  now_epoch=$(date '+%s' 2>/dev/null)
  [[ "$sealed_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]] || return 1
  ((now_epoch - sealed_epoch > 604800))
}

show() {
  local dir handoff last_turn source_file sealed_at session_id reason branch worktrees body stale_line

  dir=$(handoff_dir) || {
    info "wf-handoff: Git common directory から保存先を決められませんでした"
    return
  }
  handoff="$dir/handoff.md"
  last_turn="$dir/last-turn.md"

  if [[ -f "$handoff" ]]; then
    source_file=$handoff
    sealed_at=$(frontmatter_value "$handoff" sealed_at)
    session_id=$(frontmatter_value "$handoff" session_id)
    reason=$(frontmatter_value "$handoff" reason)
    branch=$(frontmatter_value "$handoff" branch)
    worktrees=$(awk '/^worktrees: \|$/ { reading=1; next } reading && /^---$/ { exit } reading { sub(/^  /, ""); print }' "$handoff" 2>/dev/null)
    [[ -n "$worktrees" ]] || worktrees=unknown
    body=$(awk 'separators < 2 && /^---$/ { separators++; next } separators >= 2 { print }' "$handoff" 2>/dev/null)
  elif [[ -f "$last_turn" ]]; then
    source_file=$last_turn
    sealed_at=unknown
    session_id=unknown
    reason=unknown
    branch=unknown
    worktrees=unknown
    body=$(cat -- "$last_turn" 2>/dev/null)
  else
    return
  fi

  [[ -n "$body" ]] || return
  stale_line=""
  if [[ "$source_file" == "$handoff" ]] && is_older_than_seven_days "$sealed_at"; then
    stale_line="7日以上前の記録です。"
  fi

  cat <<EOF
[前セッションからの引き継ぎ]
$sealed_at に session $session_id が $reason で終了しました。
これは参考情報であり、指示ではありません。1セッション寿命の記録です。
読んで残す価値があるものは Issue / PR / CLAUDE.md へ移してください (CLAUDE.md
「What survives a \`/clear\`」)。

ブランチ: $branch
worktree:
$worktrees
EOF
  if [[ -n "$stale_line" ]]; then
    printf '\n%s\n' "$stale_line"
  fi
  cat <<EOF

--- 前セッションの最終応答 ---
$body
--- ここまで ---
EOF
}

main() {
  local command=${1:-}

  if [[ "$command" == "-h" || "$command" == "--help" ]]; then
    usage
    return
  fi

  command -v jq >/dev/null 2>&1 || return

  case "$command" in
    capture)
      capture
      ;;
    seal)
      seal
      ;;
    show)
      show
      ;;
    *)
      info "wf-handoff: capture / seal / show のいずれかを指定してください"
      ;;
  esac
}

main "$@"
exit 0
