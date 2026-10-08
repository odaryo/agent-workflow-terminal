/// `worktree remove` が失敗した後、登録が残っているかを読み直した結果 (設計書 §3.4)。
///
/// **`worktree remove` は step として atomic ではない。** git 2.50.1 実測では、clean な worktree の
/// サブディレクトリを `chmod 500` にすると `worktree remove` は
/// `error: failed to delete '<path>': Permission denied` と **rc=255** で終わるが、
/// `worktree list --porcelain` からその worktree は消え、管理ディレクトリ (`.git/worktrees/<名前>`)
/// ごと削除されていた。作業ツリーのディレクトリは中途半端に消えた状態で残る (`--force` を付けても
/// 同じ)。一方、未commit変更があって git が実行を拒否した場合は rc=128 で登録は残る。
/// **exit code だけでは区別できない**ので、この層が読み取りを1回撃って確かめる。
///
/// - Important: **「登録が残っている」と「アプリから見える」は別物である。** git 2.50.1 実測では、
///   同じ `chmod 500` でも対象が管理ディレクトリ (`.git/worktrees/<名前>`) 側だと結果が変わる。
///   `worktree remove` は同じ rc=255 /
///   `error: failed to delete '.git/worktrees/p6': Permission denied` で終わり、作業ツリーは
///   **完全に消える**のに、`worktree list --porcelain` には
///   `prunable gitdir file points to non-existent location` を伴う record が残る。
///   `GitWorktreeDetector` は `prunable` の付いた entry をスキャン対象から落とすので、
///   「record がある」を「やり直せる」と答えると、ユーザーのファイルが全部消えた worktree を
///   無傷だと伝えることになる。だから record の有無だけでなく、その record が
///   スキャン対象になり得るかまで見る。
public enum WorktreeRegistrationAfterFailedRemoval: Sendable, Equatable {
  /// record があり、`GitWorktreeDetector` が一覧段で落とす条件 (`prunable` / bare) にも当たらない。
  ///
  /// **呼び出し側にできること**: 次のスキャンでもこの worktree は現れるので、UI から同じ Close を
  /// もう一度選べる。git が実行を拒否した場合 (未commit変更など) がここへ来る。
  ///
  /// - Important: 「`scan()` が必ず返す」までは約束しない。`GitWorktreeDetector.describe` は
  ///   一覧段を通った entry も、作業ツリーへ到達できない・common dir がこの Project のもので
  ///   ないという理由で落とす。ここで見ているのは `worktree list` の record だけである。
  case retained
  /// record はあるが `prunable` (または bare) が付いており、`GitWorktreeDetector` が一覧段で落とす。
  ///
  /// **呼び出し側にできること**: `scan()` には現れないので、**UI からもう一度 Close を選ぶ経路は
  /// 無い**。やり直せるのは、いま手元にある `WorktreeCloseExecutor` から同じ計画を撃ち直す場合
  /// だけである。git 2.50.1 実測では、`prunable` の原因を取り除いた後の `worktree remove` は
  /// rc=0 で record ごと消えるが、原因が残っている間は同じ rc=255 を繰り返す
  /// (`worktree prune` も同じ `Permission denied` を出し、record を残したまま rc=0 で終わる)。
  /// 原因を取り除く操作はアプリの書き込み範囲の外にあり、§17.2 のとおり Agent か通常 shell へ委ねる。
  case retainedButNotScannable
  /// 消したい作業ツリーのパスが `worktree list` に**見えなくなった**。
  ///
  /// 本当に登録が消えている形は実在する (上の「サブディレクトリを `chmod 500`」がそれで、
  /// `.git/worktrees/<名前>` ごと消えたうえに作業ツリーは中途半端に残る)。ただしこの判定は
  /// 「`DetectedWorktree.worktreePath` と `worktree list` の `worktree` 行が同じバイト列か」しか
  /// 見ておらず、**両者が同じスキャンから来ている保証は型に無い**。git 2.50.1 実測では、
  /// 登録が無傷のまま `.dropped` に見える形が少なくとも3つある。
  ///
  /// 1. `git worktree move` の後。安定 ID は不変なので `scan()` はこの worktree を返し続けるが、
  ///    `worktree` 行は新しいパスになる (実測: `p7` → `p7-moved` で安定 ID は
  ///    `.../worktrees/p7` のまま、旧パスは list から消える)。手元の `DetectedWorktree` が
  ///    移動前のものなら一致しない。呼び出し側のバグは要らない。
  /// 2. `repositoryDirectory` が別 repository を指していた場合。その repository の list に対象の
  ///    パスは無い (実測) 一方、対象の登録は無傷である。
  /// 3. `worktree remove` が受け付けるパス表記は list が吐く表記より広い。実測では末尾スラッシュ・
  ///    `..` を含む形・symlink 経由 (`/tmp` → `/private/tmp`) がいずれも rc=0 で同じ worktree を
  ///    消すが、list は解決後の1表記しか吐かない。`WorktreeCloseExecutor.init` の検証は
  ///    `hasPrefix("/")` だけなのでこれらは argv に入り、入った時点で文字列比較は外れる。
  ///
  /// **呼び出し側にできること**: この値だけで「消えた」と断定しない。次のスキャン結果と安定 ID で
  /// 突き合わせ直すのが唯一の確かめ方である。挙動を安全側 (`.retained` へ丸めない) に寄せている
  /// のは、上の3つがどれも**登録が残っている**方向の誤りだからである。
  case dropped
  /// 読み直し自体が失敗し、どれか決められなかった。`retained` へ丸めない —— 消えた登録を
  /// 「何も起きていない」と読ませることが、この読み直しが防ごうとしている事故そのものである。
  case unknown(GitRunnerError)
}
