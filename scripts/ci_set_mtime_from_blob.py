#!/usr/bin/env python3
"""追跡しているファイルの mtime を、その blob の SHA から決めた時刻に揃える (CI 専用、Issue #851)。

actions/checkout は全ファイルの mtime を checkout した時刻にする。swift-driver はソースの mtime が
ビルド記録と違えば変更とみなすので、復元した `.build` があってもほぼ全部を再コンパイルする
(CI の Swift 6.1.2 の実測: cold の Build 126s に対して 102s、run 42967335184)。内容が同じなら
同じ mtime になるようにすれば、変わったファイルだけが再コンパイルされる (変更なしで 5s、
run 42969024871)。

コミット時刻ではなく blob の SHA を使うのは、checkout の既定の fetch-depth: 1 では各ファイルの
最終コミットを辿れないため。時刻は 2000-01-01 から SHA の先頭 7 桁 (16 進) 秒後で、内容が変わった
ファイルが偶然同じ時刻になる確率は 2^-28 である。

引数は git ls-files に渡す pathspec。symlink と submodule は触らない。
依存は標準ライブラリのみ。
"""

import os
import subprocess
import sys

EPOCH_2000 = 946684800


def main(pathspecs):
    listing = subprocess.run(
        ["git", "ls-files", "-s", "-z", "--", *pathspecs],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    count = 0
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        meta, path = entry.split(b"\t", 1)
        mode, sha, _stage = meta.split(b" ")
        if mode not in (b"100644", b"100755"):
            continue
        seconds = EPOCH_2000 + int(sha[:7], 16)
        nanoseconds = seconds * 1_000_000_000
        os.utime(path, ns=(nanoseconds, nanoseconds))
        count += 1
    print(f"mtime を揃えたファイル: {count} 件", file=sys.stderr)
    if count == 0:
        print("対象のファイルが 1 件もありません", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
