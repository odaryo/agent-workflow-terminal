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
checks がゼロ件の場合は check run 未登録ウィンドウを考慮して最大60秒待ってから受理する
(このフラグの有無によらない)。
  --wait-checks      checks が pending の場合、15秒間隔・最大15分ポーリングして待つ
  --delete-local     マージ後、ローカルの head ブランチを削除する
                     (作業ツリーが checkout 中の場合は警告を出してスキップする)
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
# wf-pr-create.sh を通らず作られた PR もここで捕捉する (Issue #43)。
require_conventional_title "$pr_title" "PR #$pr_number のタイトル (gh pr edit $pr_number --title で修正可)"

has_fail=0
has_pending=0
checks_reported=0
refresh_checks() {
  local buckets b
  has_fail=0
  has_pending=0
  checks_reported=0
  # --json 指定時の gh pr checks は checks を取得できた限り合否に関わらず exit 0
  # (fail/pending 用の特殊 exit code は JSON 出力時には返らない。gh の checks.go で確認)。
  # 非ゼロは「checks ゼロ件 (no checks reported)」か実エラーのどちらかで、前者だけを
  # 正常系として扱う。実エラーまで握り潰すと checks 未検証のままマージへ進んでしまう。
  if ! buckets=$(gh pr checks "$pr_number" --json bucket --jq '.[].bucket' 2>&1); then
    grep -qF "no checks reported" <<<"$buckets" \
      || die "PR #$pr_number の checks 取得に失敗しました: $buckets"
    return 0
  fi
  checks_reported=1
  if [[ -n "$buckets" ]]; then
    while IFS= read -r b; do
      case "$b" in
        fail | cancel) has_fail=1 ;;
        pending) has_pending=1 ;;
      esac
    done <<<"$buckets"
  fi
}

# ゼロ件は「paths-ignore で CI が起動しない (Spikes のみ等)」と「push 直後で check run
# 未登録」を API 上区別できない (Issue #46)。実測では未登録ウィンドウが PR 作成後
# 約3秒・既存 PR への push 後 約21秒あったため、ゼロ件は即受理せず実測値の約3倍を
# 上限に猶予リトライしてから受理する。
#
# 猶予は pending 待機中にも要る。待機中に head へ push されると rollup が新 head へ
# 切り替わって一度ゼロ件へ落ちるため、初回だけ猶予を入れる作りだと「pending を待って
# いたら CI 未検証の新しい head をそのままマージする」経路が残る。判定を1つのループに
# まとめて、どの時点のゼロ件にも同じ猶予が掛かるようにする。
#
# 猶予は累積で数える (ゼロ件へ戻るたびにリセットしない) — push を繰り返されたときに
# 待ち続けないための上限として機能させるため。
GRACE_LIMIT_SECONDS=60
PENDING_LIMIT_SECONDS=900
verify_checks() {
  local grace=0 waited=0
  refresh_checks
  while :; do
    [[ "$has_fail" -eq 0 ]] || die "PR #$pr_number の checks に失敗があります"

    if [[ "$checks_reported" -eq 0 ]]; then
      if [[ "$grace" -ge "$GRACE_LIMIT_SECONDS" ]]; then
        info "PR #$pr_number に checks がありません。CI が起動しない変更 (Spikes のみ等) とみなして checks 検証をスキップします"
        return 0
      fi
      [[ "$grace" -gt 0 ]] \
        || info "checks がゼロ件です。check run 未登録ウィンドウの可能性があるため最大${GRACE_LIMIT_SECONDS}秒待ちます (5秒間隔)"
      sleep 5
      grace=$((grace + 5))
      refresh_checks
      continue
    fi

    [[ "$has_pending" -eq 1 ]] || return 0
    [[ "$wait_checks" -eq 1 ]] || die "PR #$pr_number の checks が pending です (--wait-checks で待機できます)"
    [[ "$waited" -lt "$PENDING_LIMIT_SECONDS" ]] \
      || die "PR #$pr_number の checks が15分待っても完了しませんでした"
    [[ "$waited" -gt 0 ]] || info "checks の完了を待機します (最大15分, 15秒間隔)"
    sleep 15
    waited=$((waited + 15))
    refresh_checks
  done
}

verify_checks

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

# 指定ブランチを checkout している worktree のパスを返す (見つからなければ空)。
# これは best-effort — rebase / bisect が停止中の worktree は `branch` 行ではなく
# `detached` を出力するのにブランチは使用中と見なされる (実測。同じ制約が
# wf-cleanup-branches.sh にもある)。ブランチを書き換えられるかどうかの判定には
# 使わず、書き換えに失敗したあとで相手のパスを引くためだけに使う。
# awk を早期 exit させないのは、worktree が数十を超えると git が SIGPIPE で死に
# pipefail が 141 を伝播してマージ直後に中断するため。
worktree_for_branch() {
  git worktree list --porcelain | awk -v ref="refs/heads/$1" '
    $1 == "worktree" { path = substr($0, 10) }
    $1 == "branch" && $2 == ref && !found { print path; found = 1 }
  '
}

current_branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$current_branch" == "$pr_head" ]]; then
  # ref を直接書き換えられるかは git に訊く。1タスク = 1 worktree の運用では main は
  # 別の作業ツリーが checkout したままで、`git branch -f` は拒否される (Issue #131)。
  # 事前に判定せず試すのは、上記の通り porcelain の出力が使用中を取りこぼすため。
  # 拒否されても ref は動かない (実測) ので、失敗を検出手段として使ってよい。
  if branch_force_error=$(git branch -f main origin/main 2>&1); then
    # 陳腐化したローカル main へ直接 checkout すると、PR が変更したファイルに
    # 作業ツリーの未コミット差分がある場合に中断する (Issue #37)。先に main を
    # origin/main へ合わせれば、マージ済み内容と作業ツリーの間に差は生じない。
    git checkout main
    current_branch="main"
  else
    main_worktree=$(worktree_for_branch main)
    if [[ -z "$main_worktree" ]]; then
      info "警告: ローカル main を更新できませんでした: $branch_force_error"
    else
      # 別の作業ツリーが持つ main は ref を書き換えられないので、その作業ツリー側で
      # fast-forward する。無関係な未コミット差分があっても通り、更新対象のファイルに
      # 差分がある場合だけ git が拒否する (実測)。後処理を止める理由にはならない。
      git -C "$main_worktree" merge --ff-only origin/main \
        || info "警告: '$main_worktree' の main を fast-forward できませんでした。その作業ツリーで手動で更新してください"
    fi
    info "この作業ツリーは '$current_branch' を checkout したままです。用が済んだら 'git worktree remove' と scripts/wf-cleanup-branches.sh --yes で掃除してください"
  fi
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
      # checkout 中のブランチは git が削除を拒否する (rc=1、副作用なし。実測)。
      # main と同じ理由でここも事前判定せず、失敗を検出手段として使う。
      git branch -D "$pr_head" \
        || info "警告: ローカルブランチ '$pr_head' を削除できませんでした。作業ツリーが checkout 中の可能性があります (その作業ツリーを削除してから scripts/wf-cleanup-branches.sh --yes)"
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
