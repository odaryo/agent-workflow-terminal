---
name: worktree-handoff
description: Agent Workflow Terminal の Project Root で実装を指示されたとき、worktree を作り、新しいセッションの Agent に作業を渡して自分は終える手順。調査や質問には使わない。
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/handoff.sh *)
---

実装の指示を受け、カレントが Project Root（linked worktree ではない）のときだけ使う。
調査や質問への回答には使わない。

1. `git rev-parse --git-dir` と `git rev-parse --git-common-dir` を実行する。
   それぞれの結果をカレントディレクトリからの絶対パスに直して比較し、同じなら Project Root、
   違えば linked worktree と判定する。linked worktree ではこの手順を使わない。
2. `${CLAUDE_SKILL_DIR}/scripts/handoff.sh --check` が exit 0 になることを確認する。
   使えないときは、このセッションの中で通常どおり worktree を作って移動して作業する。
3. `CLAUDE.md` など Project の規則に従って worktree を作る。
4. 新しい Agent は今の会話を引き継がない。指示を単体で読める形で Issue コメントやファイルに書き出す。
   `--prompt` は Issue 番号やファイルパスを指す短い1行（空でなく、700 バイトまでの UTF-8）にする。
   backslash・制御文字（改行・タブなど）を入れず、`-` で始めない。
5. 次を実行する。

   ```bash
   ${CLAUDE_SKILL_DIR}/scripts/handoff.sh --directory <worktree の絶対パス> --prompt '指示の場所と実施内容'
   ```

6. 成功したら、出力されたセッション名を報告して自分の処理を終える。実装を続けない。

| 終了コード | 対応 |
| --- | --- |
| 0 | セッション名を報告して終える |
| 2 | 指示を直す。セッションはまだ作られていない |
| 3 | 既にセッションがある。送っていないので、`session=` の名前を報告して止まる |
| 69 | 窓口を使えない。既に作った worktree をもう一度作らず、その worktree へ移動してこのセッションの中で続ける。まだ作っていなければ、通常どおり作って移動する |
| 1 / 4 / 5 / 6 / 7 | `session=` があればセッションが残っている可能性がある。その名前を報告して止まる。実装を続けない。Agent が exec で終わるとセッションごと消える |
| その他 | 窓口との通信に失敗した。状況を報告して止まる |

exit 7 は起動を「確認できない」という意味で、起動の「失敗」を示すものではない。
たとえば shell の rc の組み込み処理が10秒を超えると、Agent が後から起動する場合がある。

exit 1 / 4 / 5 / 6 / 7 で `session=` があるときは、セッションが残っていて Agent が動いている場合もある。
Agent が exec で終わるとセッションごと消える。再実行で exit 3 になり送られないのは、セッションが
残っている間だけで、消えていれば作り直して送る。利用者に Overview でそのセッションの状態を確かめるよう伝える。
セッションが残っていて Agent が動いていなければ、手で起動するか、Close で
`docs/architecture.md` §3.4 の選択肢2「Inactive化し、tmux sessionも終了する」を選び、
worktree を残してセッションを終了してからやり直すよう伝える。

exit 1 で `session=` が無いときは、hostctl の失敗（出力の `code` と `message` を見る）または応答を
読めなかった場合（非 JSON や `session` キーの無い応答など）である。応答を読めなかったときだけ
セッションの有無が分からないので、名前を推測せず、Overview で確かめるよう利用者に伝える。
応答の原文から名前を取り出さない。
