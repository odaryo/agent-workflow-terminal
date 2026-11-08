---
name: worktree-handoff
description: Agent Workflow Terminal の Project Root で実装を指示されたとき、worktree を作り、新しいセッションの Agent に作業を渡して自分は終える手順。
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/handoff.sh *)
---

実装の指示を受け、カレントが Project Root（linked worktree ではない）のときだけ使う。
調査や質問への回答には使わない。

1. `"${CLAUDE_SKILL_DIR}/scripts/handoff.sh" --check` が exit 0 になることを確認する。
   使えないときは、このセッションの中で通常どおり worktree を作って移動して作業する。
2. `CLAUDE.md` など Project の規則に従って worktree を作る。
3. 新しい Agent は今の会話を引き継がない。指示を単体で読める形で Issue コメントやファイルに書き出す。
   `--prompt` はその指示を指す短い1行（改行なし、700 バイトまで）にする。
4. 次を実行する。

   ```bash
   "${CLAUDE_SKILL_DIR}/scripts/handoff.sh" --directory <worktree の絶対パス> --prompt '指示の場所と実施内容'
   ```

5. 成功したら、出力されたセッション名を報告して自分の処理を終える。実装を続けない。

| 終了コード | 対応 |
| --- | --- |
| 0 | セッション名を報告して終える |
| 2 | 指示を空でない短い1行に直す（700 バイトまで） |
| 3 | 既にセッションがある。表示された名前を報告し、送信せず止まる |
| 69 | このセッションの中で通常どおり worktree を作って移動して作業する |
| 4 / 5 / 6 / その他 | 状況を報告して止まる |
