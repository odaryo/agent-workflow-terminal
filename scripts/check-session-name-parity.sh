#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: check-session-name-parity.sh

scripts/lib.sh の awt_tmux_session_name (設計書 §3.5 の第二の実装) が、製品の
TerminalCore.TmuxSessionName と同じ答えを返すことを検査する。

  - 突き合わせは両実装の出力の diff で行う。期待値をベタ書きした表は使わない
    (両方が同時にずれたときに検出できないため)
  - bash 側の規則を 1 か所ずつ変異させた複製でも回し、diff が出ることを確かめる
    (落ちない検査は検査ではない)

入力は scripts/tests/session-name-parity/stable-ids.txt。Swift 側は同ディレクトリの
パッケージ (TerminalCore への path 依存) をビルドして実行する。

  -h, --help  このヘルプを表示
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || die "引数は指定できません"

require_cmd python3 swift

HARNESS_DIR="$SCRIPT_DIR/tests/session-name-parity"
FIXTURE="$HARNESS_DIR/stable-ids.txt"
[[ -f "$FIXTURE" ]] || die "安定 ID の一覧がありません: $FIXTURE"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# 入力が痩せると突き合わせは黙って通る。ずれうる形が並んでいることを先に確かめる。
info "--- 入力の形"
python3 - "$FIXTURE" <<'PY'
import sys

# バイトで読んでから lossy に直す。strict な UTF-8 読みにすると、検査したい入力クラスの 1 つ
# (不正な UTF-8 を含む安定 ID) を fixture に入れた瞬間に、この痩せ検査自身が落ちる。
raw = open(sys.argv[1], "rb").read()
lines = raw.split(b"\n")
entries = [line for line in lines if line and not line.startswith(b"#")]
decoded = [entry.decode("utf-8", "replace") for entry in entries]
problems = []
if not any(entry.decode("utf-8", "replace").encode("utf-8") != entry for entry in entries):
    problems.append("不正な UTF-8 を含む安定 ID が 1 件も無い")
entries = decoded
if len(entries) < 20:
    problems.append("件数が %d 件しかない (20 件以上)" % len(entries))
checks = {
    "Project Root (<repo>/.git)": lambda s: s.endswith("/.git"),
    "非 ASCII を含むパス": lambda s: any(ord(c) > 0x7F for c in s),
    "非 BMP (サロゲートペアになる) を含むパス": lambda s: any(ord(c) > 0xFFFF for c in s),
    "結合文字を含むパス": lambda s: "́" in s,
    ". を含むパス要素": lambda s: any("." in part for part in s.split("/")[1:]),
    ": を含むパス要素": lambda s: any(":" in part for part in s.split("/")),
    "32 スカラを超えるパス要素": lambda s: any(len(part) > 32 for part in s.split("/")),
    "空要素になる連続 / または末尾 /": lambda s: "//" in s or s.endswith("/"),
    # 許可文字クラスの端 (A / Z / a / z / 0 / 9) を slug へ通す入力。これが無いと
    # `"A" <= char <= "Y"` のような 1 文字ずらしの変異が黙って通る。
    "A/Z/a/z/0/9 をすべて含む末尾要素": lambda s: all(
        char in ([part for part in s.split("/") if part] or [""])[-1] for char in "AZaz09"
    ),
}
for label, predicate in checks.items():
    if not any(predicate(entry) for entry in entries):
        problems.append("%s が 1 件も無い" % label)
if problems:
    for problem in problems:
        sys.stderr.write("NG: " + problem + "\n")
    sys.exit(1)
sys.stderr.write("OK: %d 件・必要な形をすべて含む\n" % len(entries))
PY

info "--- Swift 実装 (TerminalCore.TmuxSessionName) を通す"
swift build --package-path "$HARNESS_DIR" >&2 || die "突き合わせ用パッケージのビルドに失敗しました"
bin_path=$(swift build --package-path "$HARNESS_DIR" --show-bin-path) \
  || die "実行ファイルのパスを取得できませんでした"
"$bin_path/SessionNameParity" "$FIXTURE" >"$work_dir/swift.txt" \
  || die "Swift 側の導出に失敗しました"
[[ -s "$work_dir/swift.txt" ]] || die "Swift 側の出力が空です"

# 変異させた複製も同じ経路で走らせるため、lib.sh のパスを引数に取る。出力は Swift 側と同じく
# `<何件目か>\t<session 名>`。安定 ID そのものを並べないのは、不正な UTF-8 を含む入力では
# Swift 側 (U+FFFD 化済み) と bash 側 (生バイト) が必ずバイト差になるため。
run_bash_side() {
  local lib="$1"
  (
    # shellcheck disable=SC1090 # 変異させた複製を含め、パスは実行時にしか決まらない
    source "$lib"
    index=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in '' | '#'*) continue ;; esac
      index=$((index + 1))
      printf '%s\t%s\n' "$index" "$(awt_tmux_session_name "$line")"
    done <"$FIXTURE"
  )
}

# 何件目が何だったかは、突き合わせが落ちたときだけ引ければよい。LC_ALL=C を付けるのは、
# 不正な UTF-8 を含む行を macOS の awk が黙って落とすため (実測: 該当行だけ空で出た)。
show_entry() {
  LC_ALL=C awk -v want="$1" \
    '!/^#/ && NF > 0 { n += 1; if (n == want) { print; exit } }' "$FIXTURE" | cat -v
}

info "--- bash 実装 (scripts/lib.sh の awt_tmux_session_name) と突き合わせる"
run_bash_side "$SCRIPT_DIR/lib.sh" >"$work_dir/bash.txt" || die "bash 側の導出に失敗しました"
if ! diff -u "$work_dir/swift.txt" "$work_dir/bash.txt" >"$work_dir/diff.txt"; then
  info "NG: bash 側と Swift 側の導出がずれています (- が Swift / + が bash)"
  cat "$work_dir/diff.txt" >&2
  info "--- ずれた行の安定 ID (非表示文字は cat -v 表記)"
  while IFS= read -r changed; do
    info "  $changed 件目: $(show_entry "$changed")"
  done < <(awk '/^[+-][0-9]+\t/ { sub(/^[+-]/, ""); sub(/\t.*/, ""); print }' "$work_dir/diff.txt" \
    | sort -nu)
  die "設計書 §3.5 の実装が 2 つに分かれています。両方を直すこと"
fi
info "OK: $(wc -l <"$work_dir/bash.txt" | tr -d ' ') 件すべて一致"

# 変異させた規則を検出できることまで確かめる。ここが無いと、入力の欠落や比較の書き間違いで
# 「何も比べていない検査」が緑のまま残る。
#
# 各行は `ラベル|sed 式|変異後に現れるはずの文字列`。3 列目まで見るのは、ファイルが変わったこと
# (cmp) では「狙った規則が変わったこと」を保証できないため。変異させた側が異常終了した場合も
# 検出成功に数えない — 差分の出どころが規則の違いではなくエラーになってしまう。
info "--- 規則を 1 か所変異させた複製で、差分が出ること"
mutants=(
  "slug の上限 32 スカラ|s/SLUG_SCALAR_LIMIT = 32/SLUG_SCALAR_LIMIT = 31/|SLUG_SCALAR_LIMIT = 31"
  "slug に許す記号 _-|s/SLUG_EXTRA_CHARS = \"_-\"/SLUG_EXTRA_CHARS = \"_\"/|SLUG_EXTRA_CHARS = \"_\""
  "Project Root の目印 _git|s/MARKER = \"_git\"/MARKER = \"_gitx\"/|MARKER = \"_gitx\""
  "hash の桁数 8|s/HASH_HEX_CHARS = 8/HASH_HEX_CHARS = 7/|HASH_HEX_CHARS = 7"
  "接頭辞 awt-|s/write(\"awt-\"/write(\"awt_\"/|write(\"awt_\""
  "空のパス要素を落とす|s/ if part]/]/|identity.split(\"/\")]"
  "Unicode スカラ単位の走査|s/decode(\"utf-8\", \"replace\")/decode(\"latin-1\")/|decode(\"latin-1\")"
  # 許可文字クラスの端。1 文字ずらしただけの変異は、その文字を通す入力が fixture に無いと
  # 黙って通る (痩せ検査の `A/Z/a/z/0/9 をすべて含む末尾要素` がその入力を要求している)。
  "許可文字 A の下端|s/(\"A\" <= char <= \"Z\")/(\"B\" <= char <= \"Z\")/|(\"B\" <= char <= \"Z\")"
  "許可文字 Z の上端|s/(\"A\" <= char <= \"Z\")/(\"A\" <= char <= \"Y\")/|(\"A\" <= char <= \"Y\")"
  "許可文字 a の下端|s/(\"a\" <= char <= \"z\")/(\"b\" <= char <= \"z\")/|(\"b\" <= char <= \"z\")"
  "許可文字 z の上端|s/(\"a\" <= char <= \"z\")/(\"a\" <= char <= \"y\")/|(\"a\" <= char <= \"y\")"
  "許可文字 0 の下端|s/(\"0\" <= char <= \"9\")/(\"1\" <= char <= \"9\")/|(\"1\" <= char <= \"9\")"
  "許可文字 9 の上端|s/(\"0\" <= char <= \"9\")/(\"0\" <= char <= \"8\")/|(\"0\" <= char <= \"8\")"
)
failures=0
for mutant in "${mutants[@]}"; do
  # sed 式が `|` を含んでも切り出せるよう、ラベルと期待文字列は両端から取る。
  label=${mutant%%|*}
  expected=${mutant##*|}
  expression=${mutant%|*}
  expression=${expression#*|}
  mutant_lib="$work_dir/lib-mutant.sh"
  sed "$expression" "$SCRIPT_DIR/lib.sh" >"$mutant_lib"
  if grep -qF -- "$expected" "$SCRIPT_DIR/lib.sh"; then
    info "NG: 変異後に現れるはずの文字列が変異前から在ります (変異の定義が古い): $label"
    failures=$((failures + 1))
    continue
  fi
  if ! grep -qF -- "$expected" "$mutant_lib"; then
    info "NG: 狙った規則が変わっていません (規則の綴りが変わった?): $label"
    failures=$((failures + 1))
    continue
  fi
  if ! run_bash_side "$mutant_lib" >"$work_dir/mutant.txt" 2>"$work_dir/mutant.err"; then
    info "NG: 変異させた複製が異常終了しました (差分の出どころが規則の違いではありません): $label"
    cat "$work_dir/mutant.err" >&2
    failures=$((failures + 1))
    continue
  fi
  if diff -q "$work_dir/swift.txt" "$work_dir/mutant.txt" >/dev/null; then
    info "NG: 変異させても差分が出ません (この規則は検査できていない): $label"
    failures=$((failures + 1))
  else
    info "OK: 変異を検出した: $label"
  fi
done

info ""
[[ "$failures" -eq 0 ]] || die "${#mutants[@]} 件中 $failures 件の変異を検出できませんでした"
info "bash 実装と Swift 実装は一致し、${#mutants[@]} 件の変異はすべて検出できます"
