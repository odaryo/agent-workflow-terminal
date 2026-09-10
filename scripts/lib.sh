#!/usr/bin/env bash
# source 専用ライブラリ。実行ビットは付与しない。
set -euo pipefail

die() {
  echo "エラー: $*" >&2
  exit 1
}

info() {
  echo "$*" >&2
}

repo_root_cd() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "Git リポジトリの外です"
  cd "$root" || die "リポジトリルートへの移動に失敗しました: $root"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "必須コマンドが見つかりません: $cmd"
  done
}

# 値必須フラグの値欠落を bash の "unbound variable" ではなく日本語エラーにするためのガード。
# $1 = フラグ名 (エラー表示用), $2 = 呼び出し元の "$#" (シフト前の残り引数数)。
require_value() {
  [[ "$2" -ge 2 ]] || die "$1 には値が必要です"
}

# 現在ブランチ名を返す。detached HEAD の場合は日本語エラーで exit する。
current_branch_or_die() {
  local ref
  ref=$(git symbolic-ref --quiet HEAD) || die "detached HEAD 状態です。ブランチを checkout してから実行してください"
  echo "${ref#refs/heads/}"
}

# 登録済み worktree の管理ディレクトリ (設計書 §3.5 の安定 ID) を標準出力へ返す。
# $1 = `git worktree list --porcelain` が出した worktree のパス
# $2 = そのパス。実在するなら `cd && pwd -P` で正規化したもの (実在しなければ $1 と同じでよい)
# 呼び出し側の cwd は対象リポジトリの中であること。戻り値は 0=成功 / 1=見つからない /
# 2=複数一致 / 3=共通 git dir を取得できない。
#
# **対象ディレクトリの中で `rev-parse --absolute-git-dir` を引かないこと。** `.git` リンク
# ファイルが消えた worktree では git が親を遡り、祖先リポジトリの git dir を返す (実測
# git 2.50.1 / Apple Git-155)。登録は `prunable` として残るため呼び出し側は対象を見つけられて
# しまい、無関係な session — 典型的には Project Root の session — を指す名前が出る。
#
# 代わりに `<共通 git dir>/worktrees/*/gitdir` を走査する。このファイルは worktree の `.git` を
# 指しており、作業ツリーが消えても壊れても残る (実測: 同上)。中身は絶対パスとは限らず、実測で
# 観測できたのは次の 2 形 (git 2.50.1):
#   - 絶対パス (既定): `/private/tmp/…/wts/foo/.git`
#   - 管理ディレクトリからの相対パス: `../../../../wts/foo/.git`
#     (`worktree.useRelativePaths=true` または `git worktree add --relative-paths`。git 2.48 以降)
# 相対を cwd から解くと**別の登録済み worktree に着地して 1 件だけ match しうる**ので、必ず
# 管理ディレクトリを起点に解く。この 2 形以外は試していない。
awt_worktree_admin_dir() {
  local registered_path="$1" canonical_path="$2"
  local common_dir gitdir_file admin_dir linked resolved
  local found="" found_count=0
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 3
  for gitdir_file in "$common_dir"/worktrees/*/gitdir; do
    [[ -f "$gitdir_file" ]] || continue
    admin_dir=$(dirname -- "$gitdir_file")
    linked=$(dirname -- "$(cat "$gitdir_file")")
    resolved=$(awt_resolve_from "$admin_dir" "$linked") || continue
    if [[ "$resolved" == "$registered_path" ]] || [[ "$resolved" == "$canonical_path" ]]; then
      found="$admin_dir"
      found_count=$((found_count + 1))
    fi
  done
  [[ "$found_count" -ne 0 ]] || return 1
  [[ "$found_count" -eq 1 ]] || return 2
  printf '%s\n' "$found"
}

# $1 (実在するディレクトリ) を起点に $2 を解決し、絶対パスを返す。$2 が絶対なら起点は効かない。
# 作業ツリーが消えていても答えを出せるよう、末端が無ければ親まで解決して基底名を継ぎ足す。
# git 自身も同じ性質を持つ (実測: 作業ツリーを丸ごと消した後も `worktree list` は絶対パスを出す)。
awt_resolve_from() {
  local base="$1" path="$2" resolved parent leaf
  if resolved=$(cd -- "$base" 2>/dev/null && cd -- "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$resolved"
    return 0
  fi
  parent=$(dirname -- "$path")
  leaf=$(basename -- "$path")
  if resolved=$(cd -- "$base" 2>/dev/null && cd -- "$parent" 2>/dev/null && pwd -P); then
    printf '%s/%s\n' "${resolved%/}" "$leaf"
    return 0
  fi
  return 1
}

# 設計書 §3.5 の tmux session 名 `awt-<slug>-<安定IDのSHA-256先頭8桁>` を導出する。
# $1 = 安定 ID。本番の呼び出し元は awt_worktree_admin_dir が返す管理ディレクトリを渡す
# (アプリ側は worktree 内で引いた `rev-parse --absolute-git-dir` を使っており、正常な worktree
# ではこの 2 つが一致することを scripts/check-worktree-admin-dir.sh が検査している)。
# 与えられた文字列は正規化しない。表記が違えば別の ID として扱う (WorktreeIdentity と同じ)。
#
# これは Swift の TmuxSessionName (AgentWorkflowTerminal/Sources/TerminalCore) の**第二の実装**
# である。ずれれば wf-worktree-remove.sh が「残骸を見落とす」か「別の session を指す」に直結する
# ので、scripts/check-session-name-parity.sh が両者の出力を突き合わせ、CI で回している。
# 規則を変えるときは Swift 側と同時に変えること。
#
# 導出を python3 に出すのは、規則が Unicode スカラ単位で定義されているため。bash の文字クラスは
# ロケールの照合順に従い、UTF-8 ロケールの `[A-Za-z]` は非 ASCII 文字にも一致しうる。かといって
# LC_ALL=C にすると走査がバイト単位になり、1 スカラが複数の `_` になる。どちらも Swift とずれる。
awt_tmux_session_name() {
  python3 -c '
import hashlib
import os
import sys

SLUG_SCALAR_LIMIT = 32
EMPTY_SLUG_FALLBACK = "worktree"
PROJECT_ROOT_SLUG_MARKER = "_git"
SLUG_EXTRA_CHARS = "_-"
HASH_HEX_CHARS = 8


def normalize(component):
    out = []
    for char in component:
        allowed = ("A" <= char <= "Z") or ("a" <= char <= "z") or ("0" <= char <= "9")
        out.append(char if allowed or char in SLUG_EXTRA_CHARS else "_")
    return "".join(out)


# git の出力に不正な UTF-8 が混じった場合の U+FFFD 置換は、Swift 側が
# String(decoding:as:UTF8.self) で行う lossy デコードに合わせている。
identity = os.fsencode(sys.argv[1]).decode("utf-8", "replace")
digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:HASH_HEX_CHARS]
# 空の要素は落とす (Swift の split は omittingEmptySubsequences が既定)。
parts = [normalize(part) for part in identity.split("/") if part]
if not parts:
    slug = EMPTY_SLUG_FALLBACK
else:
    slug = parts[-1]
    if slug == PROJECT_ROOT_SLUG_MARKER and len(parts) >= 2:
        slug = parts[-2]
    slug = slug[:SLUG_SCALAR_LIMIT]
sys.stdout.write("awt-" + slug + "-" + digest + "\n")
' "$1"
}

WF_NWO=""
# gh repo view の結果をプロセス内でキャッシュする (同一スクリプト内で複数回呼ばれるため)。
nwo() {
  if [[ -z "$WF_NWO" ]]; then
    WF_NWO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) \
      || die "owner/repo の解決に失敗しました (gh repo view)"
  fi
  echo "$WF_NWO"
}

# squash マージは PR タイトルがそのまま main のコミットログになるため、
# commit と PR の両方に同じ形式を課す (Issue #43)。
WF_CONVENTIONAL_TYPES='feat|fix|docs|refactor|test|chore|ci|build|perf|style'
WF_CONVENTIONAL_PATTERN="^(${WF_CONVENTIONAL_TYPES})(\\([^)]+\\))?!?: .+"
# spike は Conventional Commits の type ではないが、検証作業用ブランチで使用する
# (実績: spike/issue-18-gate3-plan)。
WF_WORKTREE_BRANCH_PATTERN="^(${WF_CONVENTIONAL_TYPES}|spike)/[^/]+$"
require_worktree_branch() {
  [[ "$1" =~ $WF_WORKTREE_BRANCH_PATTERN ]] \
    || die "ブランチ名は <type>/<slug> 形式で指定してください: $1"
}
require_conventional_title() {
  [[ "$1" =~ $WF_CONVENTIONAL_PATTERN ]] \
    || die "$2が Conventional Commits 形式ではありません: $1"
}

WF_MERGED_HEAD_TSV=""
load_merged_pr_heads() {
  # squash マージではブランチ先端が origin/main の祖先にならないため、
  # `git branch --merged origin/main` はマージ済みブランチを検出できない
  # (squash-only 運用の本リポジトリでは削除候補が1件も出ない。Issue #45 で実測)。
  # 代わりにマージ済み PR の head を gh から取得し、ローカル/リモートの ref と突き合わせる。
  # 直近200件より古い PR のブランチは対象外だが、消しすぎ側には倒れない。
  # --base main は必須。base が main 以外の PR (stacked PR の子など) は、親が main に
  # 入らないまま閉じられると squash コミットが main から到達不能なままになるため。
  WF_MERGED_HEAD_TSV=$(gh pr list --state merged --limit 200 --base main \
    --json headRefName,headRefOid \
    --jq '.[] | .headRefName + "\t" + .headRefOid') \
    || die "マージ済み PR の取得に失敗しました (gh pr list)"
}

merged_pr_head_oids() {
  # `$1 ""` は文字列比較の強制。awk は -v 代入値が数値に見えると数値比較に切り替わり、
  # `007` と `7` のようなブランチ名が一致してしまう。
  awk -F '\t' -v name="$1" '$1 "" == name "" { print $2 }' <<<"$WF_MERGED_HEAD_TSV"
}
