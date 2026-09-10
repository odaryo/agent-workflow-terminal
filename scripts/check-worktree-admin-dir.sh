#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: check-worktree-admin-dir.sh

scripts/lib.sh の awt_worktree_admin_dir が、登録済み worktree の管理ディレクトリ
(設計書 §3.5 の安定 ID) を正しく返すことを、実際に git で組み立てたリポジトリ群で検査する。

これは session 名の導出 (check-session-name-parity.sh) とは別の段の検査である。名前の規則が
Swift と一致していても、**規則へ渡す安定 ID の取り方**がずれれば別の session を指す。

期待値の取り方:
  live   : 健全な worktree。`git -C <worktree> rev-parse --absolute-git-dir` と一致すること
           (アプリはこちらで安定 ID を得るため、両者が一致することが名前の一致条件)
  broken : `.git` が壊れている・作業ツリーが消えている worktree。rev-parse は使えない
           (親を遡って別のリポジトリを答える) ので、健全なうちに控えた管理ディレクトリと比較する

規則をわざとずらした複製でも回し、検査が落ちることまで確かめる。

  -h, --help  このヘルプを表示
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || die "引数は指定できません"

require_cmd git

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
cases_tsv="$work_dir/cases.tsv"
: >"$cases_tsv"

# 検査対象の外にある git config を持ち込まない。とくに worktree.useRelativePaths は
# 「未設定の環境で作った」ケースの前提そのものなので、ここを固定しないと検査が環境依存になる。
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# 呼び出し元の環境が指すリポジトリへ吸い寄せられないようにする。これらが残っていると
# `git -C <組み立てた repo>` すら別のリポジトリを見に行き、検査の意味が消える。
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
}

# $1=ラベル $2=cwd にするディレクトリ $3=worktree のパス $4=期待する管理ディレクトリ $5=live|broken
add_case() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"$cases_tsv"
}

admin_of() {
  git -C "$1" rev-parse --absolute-git-dir
}

root="$work_dir/lab"
mkdir -p "$root"

# 1. 通常配置。wt と wt2 は一方が他方の接頭辞になる組
new_repo "$root/plain/proj"
mkdir -p "$root/plain/wts"
git -C "$root/plain/proj" worktree add -q --detach "$root/plain/wts/wt" HEAD
git -C "$root/plain/proj" worktree add -q --detach "$root/plain/wts/wt2" HEAD
add_case "通常" "$root/plain/proj" "$root/plain/wts/wt" "$(admin_of "$root/plain/wts/wt")" live
add_case "通常 (接頭辞になる名前)" "$root/plain/proj" "$root/plain/wts/wt2" \
  "$(admin_of "$root/plain/wts/wt2")" live

# 2. symlink 経由のパスで作った worktree
new_repo "$root/symlink/real/proj"
mkdir -p "$root/symlink/real/wts"
ln -s "$root/symlink/real" "$root/symlink/link"
git -C "$root/symlink/real/proj" worktree add -q --detach "$root/symlink/link/wts/wt" HEAD
add_case "symlink 経由" "$root/symlink/real/proj" "$root/symlink/real/wts/wt" \
  "$(admin_of "$root/symlink/real/wts/wt")" live

# 3. git worktree move の後 (管理ディレクトリ名は作成時のまま残る)
new_repo "$root/moved/proj"
mkdir -p "$root/moved/wts"
git -C "$root/moved/proj" worktree add -q --detach "$root/moved/wts/before" HEAD
git -C "$root/moved/proj" worktree move "$root/moved/wts/before" "$root/moved/wts/after"
add_case "worktree move の後" "$root/moved/proj" "$root/moved/wts/after" \
  "$(admin_of "$root/moved/wts/after")" live

# 4. bare な共通 git dir
git init -q --bare -b main "$root/bare/proj.git"
git -C "$root/bare/proj.git" -c user.email=a@b -c user.name=a commit-tree -m init \
  "$(git -C "$root/bare/proj.git" hash-object -t tree /dev/null)" >"$work_dir/bare-oid"
git -C "$root/bare/proj.git" update-ref refs/heads/main "$(cat "$work_dir/bare-oid")"
mkdir -p "$root/bare/wts"
git -C "$root/bare/proj.git" worktree add -q --detach "$root/bare/wts/wt" main
add_case "bare な共通 git dir" "$root/bare/proj.git" "$root/bare/wts/wt" \
  "$(admin_of "$root/bare/wts/wt")" live

# 5. worktree.useRelativePaths=true (git 2.48 以降)。gitdir ファイルが管理ディレクトリからの
#    相対パスになるため、cwd を起点に解くと別の worktree に着地しうる
new_repo "$root/relcfg/proj"
mkdir -p "$root/relcfg/wts"
git -C "$root/relcfg/proj" config worktree.useRelativePaths true
git -C "$root/relcfg/proj" worktree add -q --detach "$root/relcfg/wts/wt" HEAD
git -C "$root/relcfg/proj" worktree add -q --detach "$root/relcfg/wts/wt2" HEAD
add_case "useRelativePaths=true" "$root/relcfg/proj" "$root/relcfg/wts/wt" \
  "$(admin_of "$root/relcfg/wts/wt")" live
add_case "useRelativePaths=true (接頭辞になる名前)" "$root/relcfg/proj" "$root/relcfg/wts/wt2" \
  "$(admin_of "$root/relcfg/wts/wt2")" live

# 6. --relative-paths を明示した worktree (config 未設定の repo でも relative になる)
new_repo "$root/relflag/proj"
mkdir -p "$root/relflag/wts"
git -C "$root/relflag/proj" worktree add -q --detach --relative-paths "$root/relflag/wts/wt" HEAD
git -C "$root/relflag/proj" worktree add -q --detach "$root/relflag/wts/abs" HEAD
add_case "--relative-paths" "$root/relflag/proj" "$root/relflag/wts/wt" \
  "$(admin_of "$root/relflag/wts/wt")" live
add_case "--relative-paths と絶対の混在" "$root/relflag/proj" "$root/relflag/wts/abs" \
  "$(admin_of "$root/relflag/wts/abs")" live

# 7. 非 ASCII と空白を含むパス
new_repo "$root/nonascii/リポジトリ"
mkdir -p "$root/nonascii/作業 ツリー"
git -C "$root/nonascii/リポジトリ" worktree add -q --detach "$root/nonascii/作業 ツリー/枝 1" HEAD
add_case "非 ASCII と空白" "$root/nonascii/リポジトリ" "$root/nonascii/作業 ツリー/枝 1" \
  "$(admin_of "$root/nonascii/作業 ツリー/枝 1")" live

# 8. `.git` リンクファイルが消えた worktree (rev-parse は親を遡るので期待値には使えない)
new_repo "$root/broken/proj"
mkdir -p "$root/broken/wts"
git -C "$root/broken/proj" worktree add -q --detach "$root/broken/wts/wt" HEAD
broken_admin=$(admin_of "$root/broken/wts/wt")
rm -f "$root/broken/wts/wt/.git"
add_case ".git が消えた worktree" "$root/broken/proj" "$root/broken/wts/wt" "$broken_admin" broken

# 9. 作業ツリーが丸ごと消えた worktree (相対 gitdir でも解けること)
new_repo "$root/gone/proj"
mkdir -p "$root/gone/wts"
git -C "$root/gone/proj" config worktree.useRelativePaths true
git -C "$root/gone/proj" worktree add -q --detach "$root/gone/wts/wt" HEAD
gone_admin=$(admin_of "$root/gone/wts/wt")
rm -rf "$root/gone/wts/wt"
add_case "作業ツリーが消えた worktree (相対 gitdir)" "$root/gone/proj" "$root/gone/wts/wt" \
  "$gone_admin" broken

# 10. worktree move の後に作業ツリーを消したもの。管理ディレクトリ名 (before) と作業ツリーの
#     基底名 (after) がずれるので、実在しないパスを親まで解いて継ぎ足す処理が「どちらの基底名を
#     使うか」を取り違えていると落ちる。
new_repo "$root/movedgone/proj"
mkdir -p "$root/movedgone/wts"
git -C "$root/movedgone/proj" worktree add -q --detach "$root/movedgone/wts/before" HEAD
git -C "$root/movedgone/proj" worktree move "$root/movedgone/wts/before" "$root/movedgone/wts/after"
movedgone_admin=$(admin_of "$root/movedgone/wts/after")
rm -rf "$root/movedgone/wts/after"
add_case "move してから作業ツリーを消した (管理名と基底名がずれる)" "$root/movedgone/proj" \
  "$root/movedgone/wts/after" "$movedgone_admin" broken

# 11. 作成後に親ディレクトリを symlink へ差し替えたもの (絶対 gitdir)。実測 (git 2.50.1):
#     `git worktree list` は記録した文字列をそのまま出すため、登録パスと `pwd -P` の正規化結果が
#     食い違う。gitdir を解いた値が一致するのは正規化した側だけなので、比較の腕が 1 本でも
#     欠けると引けなくなる。
new_repo "$root/symlinked-after/proj"
mkdir -p "$root/symlinked-after/wts"
git -C "$root/symlinked-after/proj" worktree add -q --detach "$root/symlinked-after/wts/wt" HEAD
symlinked_admin=$(admin_of "$root/symlinked-after/wts/wt")
mv "$root/symlinked-after/wts" "$root/symlinked-after/wts-real"
ln -s "$root/symlinked-after/wts-real" "$root/symlinked-after/wts"
add_case "事後に symlink 化 (登録パスと正規化パスが食い違う)" "$root/symlinked-after/proj" \
  "$root/symlinked-after/wts-real/wt" "$symlinked_admin" live

# 12. 同じく事後 symlink だが gitdir が相対のもの。相対を論理パスのまま (`pwd` に落として)
#     解くと symlink を辿った表記になり、git が出す登録パス (物理) と一致しなくなる。
new_repo "$root/symlinked-rel/proj"
mkdir -p "$root/symlinked-rel/wts"
git -C "$root/symlinked-rel/proj" config worktree.useRelativePaths true
git -C "$root/symlinked-rel/proj" worktree add -q --detach "$root/symlinked-rel/wts/wt" HEAD
symlinked_rel_admin=$(admin_of "$root/symlinked-rel/wts/wt")
mv "$root/symlinked-rel/wts" "$root/symlinked-rel/wts-real"
ln -s "$root/symlinked-rel/wts-real" "$root/symlinked-rel/wts"
add_case "事後に symlink 化 (相対 gitdir・物理パスで解く必要)" "$root/symlinked-rel/proj" \
  "$root/symlinked-rel/wts-real/wt" "$symlinked_rel_admin" live

# 13. 同じ worktree を指す管理ディレクトリが 2 つある状態。過去 2 巡の Critical (別の worktree に
#     着地する) を最後に止めるのは「ちょうど 1 件」の要求なので、それが効いていることを見る。
#     git 自身がこの状態を作る経路は見つかっていないため、管理ディレクトリを複製して作る。
new_repo "$root/dup/proj"
mkdir -p "$root/dup/wts"
git -C "$root/dup/proj" worktree add -q --detach "$root/dup/wts/wt" HEAD
dup_common=$(git -C "$root/dup/proj" rev-parse --path-format=absolute --git-common-dir)
cp -R "$dup_common/worktrees/wt" "$dup_common/worktrees/wt-copy"
add_case "同じ worktree を指す管理ディレクトリが 2 つ" "$root/dup/proj" "$root/dup/wts/wt" \
  "(取得できません: rc=2)" ambiguous

# 検査本体。$1 に与えた lib.sh を読み込んで回すので、変異させた複製でも同じ経路を通せる。
# 失敗した件数を終了コードではなく標準出力の最終行で返す (行数を数える側が分かりやすいため)。
run_cases() {
  local lib="$1" verbose="$2"
  (
    # shellcheck disable=SC1090 # 変異させた複製を含め、パスは実行時にしか決まらない
    source "$lib"
    failures=0
    while IFS=$'\t' read -r label cwd worktree expected mode; do
      [[ -n "$label" ]] || continue
      cd -- "$cwd"
      # スクリプト本体と同じ形で「登録されたパス」と「正規化したパス」を用意する。登録は必ず
      # `git worktree list` の出力から取る (本体もそうしている)。検査対象の関数には頼らずに
      # 探せるよう、親ディレクトリだけ自前で realpath 化して突き合わせる。
      want_real="$(cd -- "$(dirname -- "$worktree")" && pwd -P)/$(basename -- "$worktree")"
      # 登録パスは正規化されているとは限らない (実測: 作成後に親を symlink へ差し替えると、
      # `git worktree list` は記録した文字列をそのまま出す)。突き合わせは正規化した形で行い、
      # 返すのは登録されたままの文字列にする。本体が受け取るのもその文字列である。
      # `head -1` を挟まないのは、pipefail 下で SIGPIPE が伝わり検査ごと黙って死ぬため
      # (実測: 1 件も検査されないまま終わった)。先頭行は展開で取る。
      registered_all=$(git worktree list --porcelain \
        | awk 'substr($0,1,9) == "worktree " { print substr($0,10) }' \
        | while IFS= read -r listed; do
          listed_canonical=$(cd -- "$listed" 2>/dev/null && pwd -P || printf '%s' "$listed")
          [[ "$listed_canonical" != "$want_real" ]] || printf '%s\n' "$listed"
        done)
      registered=${registered_all%%$'\n'*}
      if [[ -z "$registered" ]]; then
        echo "NG: $label — 検査の組み立てが誤っています ($want_real が登録されていません)" >&2
        failures=$((failures + 1))
        continue
      fi
      canonical=$(cd -- "$registered" 2>/dev/null && pwd -P || printf '%s' "$registered")
      actual=$(awt_worktree_admin_dir "$registered" "$canonical") || actual="(取得できません: rc=$?)"
      if [[ "$actual" != "$expected" ]]; then
        failures=$((failures + 1))
        [[ "$verbose" -eq 0 ]] || {
          echo "NG: $label" >&2
          echo "    worktree : $worktree" >&2
          echo "    期待     : $expected" >&2
          echo "    実際     : $actual" >&2
        }
        continue
      fi
      if [[ "$mode" == "live" ]]; then
        live=$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null || echo "(引けません)")
        if [[ "$live" != "$expected" ]]; then
          failures=$((failures + 1))
          [[ "$verbose" -eq 0 ]] || {
            echo "NG: $label — rev-parse --absolute-git-dir と一致しません" >&2
            echo "    rev-parse: $live" >&2
            echo "    期待     : $expected" >&2
          }
          continue
        fi
      fi
      [[ "$verbose" -eq 0 ]] || echo "OK: $label" >&2
    done <"$cases_tsv"
    echo "$failures"
  )
}

info "--- 構成したリポジトリで管理ディレクトリを引く ($(wc -l <"$cases_tsv" | tr -d ' ') 件)"
failures=$(run_cases "$SCRIPT_DIR/lib.sh" 1)
[[ "$failures" -eq 0 ]] || die "$failures 件が期待と異なります"

# 規則をずらした複製でも回し、この検査が落ちることを確かめる。落ちない検査は検査ではない。
# 各行は `ラベル|sed 式|変異後に現れるはずの文字列`。
info "--- 規則を 1 か所変異させた複製で、検査が落ちること"
mutants=(
  "相対 gitdir を cwd から解く|s/awt_resolve_from \"\$admin_dir\"/awt_resolve_from \"\$PWD\"/|awt_resolve_from \"\$PWD\""
  "gitdir の起点を共通 git dir にする|s/admin_dir=\$(dirname -- \"\$gitdir_file\")/admin_dir=\$common_dir/|admin_dir=\$common_dir"
  "末端が無いときの親フォールバックを外す|s/parent=\$(dirname -- \"\$path\")/parent=\$path/|parent=\$path"
  "パスの一致を前方一致にする|s/== \"\$registered_path\" \]\]/== \"\$registered_path\"* ]]/|== \"\$registered_path\"* ]]"
  # ここから下は「誤射を止める安全弁」そのものへの変異。上の 4 つと違って、対応する形の
  # リポジトリが 1 つも無いと黙って通る (実際、追加前は 4 つとも未検出だった)。
  "「ちょうど 1 件」の要求を外す|s/\[\[ \"\$found_count\" -eq 1 \]\] || return 2/: # 変異: 複数一致を許す/|: # 変異: 複数一致を許す"
  "正規化したパスとの比較を落とす|s/ || \[\[ \"\$resolved\" == \"\$canonical_path\" \]\]//|== \"\$registered_path\" ]]; then"
  "実在しないときの基底名を取り違える|s/leaf=\$(basename -- \"\$path\")/leaf=\$(basename -- \"\$base\")/|leaf=\$(basename -- \"\$base\")"
  "パスの解決を論理パスにする|s/pwd -P)/pwd)/g|&& pwd); then"
)
mutant_failures=0
for mutant in "${mutants[@]}"; do
  # sed 式そのものが `|` を含む (`||` を書き換える変異がある) ので、両端から切り出す。
  label=${mutant%%|*}
  expected=${mutant##*|}
  expression=${mutant%|*}
  expression=${expression#*|}
  mutant_lib="$work_dir/lib-mutant.sh"
  sed "$expression" "$SCRIPT_DIR/lib.sh" >"$mutant_lib"
  if grep -qF -- "$expected" "$SCRIPT_DIR/lib.sh"; then
    info "NG: 変異後に現れるはずの文字列が変異前から在ります (変異の定義が古い): $label"
    mutant_failures=$((mutant_failures + 1))
    continue
  fi
  if ! grep -qF -- "$expected" "$mutant_lib"; then
    info "NG: 狙った規則が変わっていません (規則の綴りが変わった?): $label"
    mutant_failures=$((mutant_failures + 1))
    continue
  fi
  mutant_result=$(run_cases "$mutant_lib" 0 2>/dev/null) || mutant_result=0
  if [[ "$mutant_result" -eq 0 ]]; then
    info "NG: 変異させても検査が通ります (この規則は検査できていない): $label"
    mutant_failures=$((mutant_failures + 1))
  else
    info "OK: 変異を検出した ($mutant_result 件が不一致): $label"
  fi
done

info ""
[[ "$mutant_failures" -eq 0 ]] \
  || die "${#mutants[@]} 件中 $mutant_failures 件の変異を検出できませんでした"
info "全ケースが一致し、${#mutants[@]} 件の変異はすべて検出できます"
