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
| 1 / 4 / 5 / 6 / 7 | セッションが残っているので、`session=` の名前を報告して止まる。実装を続けない |
