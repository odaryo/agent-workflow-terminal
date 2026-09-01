#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-pr-merge.sh <PR番号> [--wait-checks] [--delete-local] [--no-wait-main-ci] [--dry-run]

前提条件 (OPEN かつ non-draft / base=main / mergeable が CONFLICTING でない /
checks が完了かつ成功) を検証したうえで squash マージする。
  --wait-checks      checks が pending の場合、15秒間隔・最大15分ポーリングして待つ
  --delete-local     マージ後、ローカルの head ブランチを削除する
  --no-wait-main-ci  マージ後の main CI 完了待ちを省略する
  --dry-run          実行せず、実行するはずの内容を表示する
  -h, --help         このヘルプを表示
EOF
}

pr_number=""
wait_checks=0
delete_local=0
no_wait_main_ci=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait-checks)
      wait_checks=1
      shift
      ;;
    --delete-local)
      delete_local=1
      shift
      ;;
    --no-wait-main-ci)
      no_wait_main_ci=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      [[ -z "$pr_number" ]] || die "引数が多すぎます: $1"
      pr_number="$1"
      shift
      ;;
  esac
done

repo_root_cd
require_cmd git gh

[[ -n "$pr_number" ]] || die "PR番号を指定してください"
[[ "$pr_number" =~ ^[0-9]+$ ]] || die "PR番号は数値で指定してください: $pr_number"

pr_line=$(gh pr view "$pr_number" \
  --json state,isDraft,baseRefName,mergeable,title,headRefName,headRefOid \
  --jq '[.state, (.isDraft|tostring), .baseRefName, .mergeable, .title, .headRefName, .headRefOid] | join("\t")') \
  || die "PR #$pr_number の情報取得に失敗しました"
IFS=$'\t' read -r pr_state pr_is_draft pr_base pr_mergeable pr_title pr_head pr_head_oid <<<"$pr_line"

[[ "$pr_state" == "OPEN" ]] || die "PR #$pr_number は OPEN ではありません (state=$pr_state)"
[[ "$pr_is_draft" == "false" ]] || die "PR #$pr_number は draft です"
[[ "$pr_base" == "main" ]] || die "PR #$pr_number の base が main ではありません (base=$pr_base、stacked PR はベース変更後にマージする運用)"
[[ "$pr_mergeable" != "CONFLICTING" ]] || die "PR #$pr_number はコンフリクトしています (mergeable=CONFLICTING)"

has_fail=0
has_pending=0
refresh_checks() {
  local buckets b
  buckets=$(gh pr checks "$pr_number" --json bucket --jq '.[].bucket' 2>/dev/null || true)
  has_fail=0
  has_pending=0
  if [[ -n "$buckets" ]]; then
    while IFS= read -r b; do
      case "$b" in
        fail | cancel) has_fail=1 ;;
        pending) has_pending=1 ;;
      esac
    done <<<"$buckets"
  fi
}

refresh_checks
[[ "$has_fail" -eq 0 ]] || die "PR #$pr_number の checks に失敗があります"

if [[ "$has_pending" -eq 1 ]]; then
  [[ "$wait_checks" -eq 1 ]] || die "PR #$pr_number の checks が pending です (--wait-checks で待機できます)"
  info "checks の完了を待機します (最大15分, 15秒間隔)"
  waited=0
  while [[ "$has_pending" -eq 1 && "$waited" -lt 900 ]]; do
    sleep 15
    waited=$((waited + 15))
    refresh_checks
    [[ "$has_fail" -eq 0 ]] || die "PR #$pr_number の checks に失敗があります"
  done
  [[ "$has_pending" -eq 0 ]] || die "PR #$pr_number の checks が15分待っても完了しませんでした"
fi

repo_nwo=$(nwo)
commit_title="${pr_title} (#${pr_number})"

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] gh api -X PUT repos/$repo_nwo/pulls/$pr_number/merge -f merge_method=squash -f commit_title=\"$commit_title\""
  exit 0
fi

merge_sha=$(gh api -X PUT "repos/$repo_nwo/pulls/$pr_number/merge" \
  -f merge_method=squash \
  -f commit_title="$commit_title" \
  --jq '.sha') || die "マージに失敗しました"

info "マージしました (sha=$merge_sha)"

# ここから先が失敗してもリモートのマージは完了している。中断時にその事実が
# exit コードだけで誤読されないよう明示する (Issue #37)。
trap 'info "注意: マージ自体は成功しています (sha=$merge_sha)。失敗したのはマージ後のローカル後処理です"' ERR

git fetch --prune origin

current_branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$current_branch" == "$pr_head" ]]; then
  # 陳腐化したローカル main へ直接 checkout すると、PR が変更したファイルに
  # 作業ツリーの未コミット差分がある場合に中断する (Issue #37)。先に main を
  # origin/main へ合わせれば、マージ済み内容と作業ツリーの間に差は生じない。
  git branch -f main origin/main
  git checkout main
  current_branch="main"
fi

if [[ "$current_branch" == "main" ]]; then
  git pull --ff-only
fi

if [[ "$delete_local" -eq 1 ]]; then
  # squash マージ後は上流とコミットが一致しないため `git branch -d` が通らない。
  # merged は直前の API 応答 (sha 取得) で確認済みという前提で -D を使うが、
  # ローカルの head が PR の headRefOid (前提条件検証時点で取得) と一致する場合に限る。
  # 不一致 = マージ後にローカルへ積まれた未 push コミットがあるということで、
  # -D はそれらを到達不能にしてしまうため削除をスキップする。
  if git show-ref --verify --quiet "refs/heads/$pr_head"; then
    local_head_oid=$(git rev-parse "refs/heads/$pr_head" 2>/dev/null || true)
    if [[ -n "$local_head_oid" && "$local_head_oid" == "$pr_head_oid" ]]; then
      git branch -D "$pr_head"
    else
      info "警告: ローカルブランチ '$pr_head' はマージした PR の head と一致しないため削除をスキップしました (local=$local_head_oid, pr_head=$pr_head_oid)"
    fi
  fi
fi

if [[ "$no_wait_main_ci" -eq 1 ]]; then
  info "main の CI 確認をスキップしました (--no-wait-main-ci)"
  exit 0
fi

info "main の CI を確認します (該当 run を最大60秒探索)"
run_id=""
searched=0
while [[ "$searched" -lt 60 ]]; do
  run_id=$(gh run list --branch main --commit "$merge_sha" --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
  [[ -z "$run_id" ]] || break
  sleep 5
  searched=$((searched + 5))
done

if [[ -z "$run_id" ]]; then
  info "CI 未トリガーです (paths-ignore の可能性があります)"
  exit 0
fi

info "main の CI (run $run_id) の完了を待機します (最大15分, 15秒間隔)"
waited=0
run_status=""
conclusion=""
while [[ "$waited" -lt 900 ]]; do
  status_line=$(gh run view "$run_id" --json status,conclusion --jq '[.status, (.conclusion // "")] | join("\t")')
  IFS=$'\t' read -r run_status conclusion <<<"$status_line"
  [[ "$run_status" == "completed" ]] && break
  sleep 15
  waited=$((waited + 15))
done

info "main CI の結果: status=$run_status conclusion=$conclusion"
[[ "$conclusion" == "success" ]] || die "main CI が success ではありません (conclusion=$conclusion)"
