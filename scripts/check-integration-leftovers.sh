#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: check-integration-leftovers.sh

統合テストが実プロセス・実ファイルを残していないことを検査し、残っていれば失敗する。
検査対象は tmux socket、`-L awt-` で起動した tmux server プロセス、
fixture の一時ディレクトリ (awt-git-* / awt-rg-it-*)。

socket の残存を異常として扱うのは、テスト側が「server の停止を確認できたときだけ socket を
消す」設計だから (AgentWorkflowTerminal/README.md の tmux 統合テストの節)。socket が残って
いる = 停止を確認できなかった、であり、まさに検出したい状態にあたる。

  -h, --help  このヘルプを表示
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || die "引数は指定できません"

require_cmd pgrep id

socket_dir="${TMUX_TMPDIR:-/private/tmp}/tmux-$(id -u)"
found=0

if [[ -d "$socket_dir" ]]; then
  # 名前を awt-* に限定しない。CI の runner には tmux が最初から入っておらず、この job が
  # 入れて統合テストだけが使うため、どの socket が残っていても後始末漏れになる。
  sockets=$(find "$socket_dir" -mindepth 1 -maxdepth 1 2>/dev/null || true)
  if [[ -n "$sockets" ]]; then
    info "tmux socket が残っています ($socket_dir):"
    echo "$sockets" >&2
    found=1
  fi
fi

# tmux server は起動時の argv を保持する (実測: `tmux -f /dev/null -L awt-... new-session ...`)
# ため、`-L awt-` で統合テストの server だけを指せる。自分自身と親シェルは対象から外す。
servers=$(pgrep -fl -- '-L awt-' 2>/dev/null | grep -v -E "^($$|${PPID}) " || true)
if [[ -n "$servers" ]]; then
  info "統合テストの tmux server が残っています:"
  echo "$servers" >&2
  found=1
fi

for pattern in "/private/tmp/awt-git-" "${TMPDIR:-/private/tmp}/awt-rg-it-"; do
  dirs=$(find "$(dirname "$pattern")" -mindepth 1 -maxdepth 1 \
    -name "$(basename "$pattern")*" 2>/dev/null || true)
  if [[ -n "$dirs" ]]; then
    info "fixture の一時ディレクトリが残っています:"
    echo "$dirs" >&2
    found=1
  fi
done

[[ "$found" -eq 0 ]] || die "統合テストの後始末が完了していません"
info "残存する tmux socket / server / fixture はありません"
