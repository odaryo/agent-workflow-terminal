#!/usr/bin/env python3
"""性能 fixture のコマンド文字列を作る。

判定本体の走査が入力長に対して線形であることを確かめるための入力を、形ごとに作る。
形を 1 つしか測らないと二次計算量が残っていても見えない — bash 実装では
`hd_quoted_plain` だけが速く、他の 3 形で 20KB あたり 3〜7 秒かかっていた (実測 2026-09-09)。

使い方: make-perf-command.py <形> <おおよその文字数>

  hd_quoted_plain  区切り語を引用した heredoc + 特殊文字の少ない本文 (最速の経路)
  hd_unquoted_md   区切り語を引用しない heredoc + 本文にバッククォートと `$`
  many_words       素の語が大量
  dquote_dollars   ダブルクォート内に `$` が大量

いずれも `kill-se` を含む — 含まないと足切りで素通りし、走査の速さを測れない。
"""

import sys


def repeat(unit, target):
    return unit * (target // len(unit) + 1)


def build(shape, target):
    if shape == "hd_quoted_plain":
        body = repeat("事故の記録: tmux kill-server を打たない。\n", target)
        return (
            "scripts/wf-issue-comment.sh 314 --body \"$(cat <<'MSG'\n"
            + body
            + "MSG\n)\""
        )
    if shape == "hd_unquoted_md":
        body = repeat("`tmux` と $HOME の話。事故: kill-server を打つな。\n", target)
        return "cat <<EOF\n" + body + "EOF"
    if shape == "many_words":
        return "echo " + repeat("word ", target) + "; tmux kill-server"
    if shape == "dquote_dollars":
        return 'echo "' + repeat("$x kill-server ", target) + '"'
    raise SystemExit("未知の形: %s" % shape)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    sys.stdout.write(build(sys.argv[1], int(sys.argv[2])))
