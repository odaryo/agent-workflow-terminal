#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: check-var-multibyte.sh [ディレクトリ]

ディレクトリ (既定: scripts/) 配下の *.sh を再帰的に読み、`$` に続く変数名の直後に ASCII 以外の
文字が続く箇所を、ファイル:行:桁 で列挙する。1件でもあれば exit 1。*.sh が1件も無ければ exit 2。
`${名前}` の形は対象外。

字面だけで判定するので、bash が展開しない文脈 (`<<'EOF'` のヒアドキュメント・コメント・単一引用符・
`\$name`) も検出する。その場合も `${名前}` に直せば消える。逆に、算術の中で `$` を付けずに書いた名前
(`$(( count・ + 0 ))`) は検出しない。

  -h, --help  このヘルプを表示
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -le 1 ]] || die "引数が多すぎます"
root="${1:-$SCRIPT_DIR}"
[[ -d "$root" ]] || die "ディレクトリがありません: $root"

require_cmd python3

# bash 3.2 は UTF-8 のロケールで、変数名の直後のマルチバイト文字を名前の一部として読む (実測 3.2.57:
# en_US.UTF-8 / ja_JP.UTF-8 で再現、LC_ALL=C では再現しない)。set -u の下では未定義の変数の参照に
# なり、EXIT の trap があると exit 0 で止まる (docs/coding-guidelines.md §7)。
# 判定をバイト単位にしているのは、走査そのものをロケールと不正な UTF-8 に左右させないため。
python3 - "$root" <<'PY'
import pathlib
import re
import sys

PATTERN = re.compile(rb"\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]")

root = pathlib.Path(sys.argv[1])
files = sorted(p for p in root.rglob("*.sh") if p.is_file())
if not files:
    print(f"*.sh が見つかりません: {root}", file=sys.stderr)
    sys.exit(2)

hits = 0
for path in files:
    for lineno, line in enumerate(path.read_bytes().splitlines(), 1):
        for match in PATTERN.finditer(line):
            hits += 1
            column = len(line[: match.start()].decode("utf-8", "replace")) + 1
            shown = line.decode("utf-8", "replace").strip()
            print(f"{path}:{lineno}:{column}: {shown}", file=sys.stderr)

if hits:
    print(
        f"NG: {hits} 件。変数名を ${{名前}} で囲むこと"
        " (bash が展開しない文脈も検出する。その場合も ${名前} に直せば消える)",
        file=sys.stderr,
    )
    sys.exit(1)
print(f"{len(files)} 件の *.sh に該当はありません", file=sys.stderr)
PY
