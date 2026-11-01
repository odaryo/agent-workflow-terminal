/// entry 1件の失敗。`scan()` はこれを検出できた worktree と一緒に返す。
///
/// - Important: 呼び出し側が原因を再現できるよう、git の生の出力を丸めずに持つ。
///   失敗した worktree を UI でどう扱うかは Issue #137 の担当で、ここでは決めない。
public struct GitWorktreeEntryFailure: Sendable, Equatable {
  /// `worktree list` が返した作業ツリーのパス。呼び出し側が失敗を既存の worktree と突き合わせる
  /// 手掛かりはこれだけである。
  ///
  /// - Note: `invalidCommonDirectoryPath` に限っては `rev-parse` の1行目から `WorktreeIdentity` を
  ///   作れているが、ここには載せない。その ID は「この Project のものか」を確かめる2行目が壊れた
  ///   ままの未照合の値であり、照合を省くと別 repository へ置き換わった worktree の ID が
  ///   この Project の ID として通って Project Root が2件になる (`describe`)。載せると呼び出し側は
  ///   照合済みの ID と混ぜて使うか、同じ照合をもう一度書くかのどちらかになる。どちらが要るかは
  ///   照合の要否を決められる呼び出し側 (Issue #137) と一緒に決める。
  public let worktreePath: String
  public let reason: Reason

  public enum Reason: Sendable, Equatable {
    /// 安定 ID の `rev-parse` が失敗し、作業ツリーの不在として除外できなかった。壊れているのが
    /// git ディレクトリ側とは限らない。分類は作業ツリーへ**到達できたかどうか**だけで決めており、
    /// git のメッセージは見ていない (`describe`)。git が exit code を返さなかった失敗
    /// (timeout 等) も、不在の証拠にならないのでここへ来る。git 2.50.1 実測では、
    /// 管理ディレクトリの `commondir` 欠落が
    /// `not a git repository: <管理ディレクトリ>`、`.git` ファイルの破損が `invalid gitfile format`、
    /// `.git` ファイルの消失が `not a git repository (or any of the parent directories): .git` で、
    /// いずれも exit 128。`worktree list` はこのどれにも `prunable` を付けない (網羅ではない)。
    /// main worktree でない entry の `--show-toplevel` が失敗した場合もここへ来る。linked worktree
    /// には必ず作業ツリーがあるので、その失敗は「確かめられなかった」であって不在の証拠ではない。
    case gitDirectory(GitRunnerError)
    /// `rev-parse` の出力が2行でなかった。パス自体に改行が含まれる場合もここへ来る。
    case unexpectedGitDirectoryOutput(output: String)
    /// 安定 ID にする1行目が絶対パスでなかった。
    case invalidGitDirectoryPath(gitDirectory: String)
    /// この Project のものかを判定する2行目が絶対パスでなかった。`invalidGitDirectoryPath` と
    /// 分けているのは、壊れているのが ID なのか判定基準なのかで呼び出し側の打ち手が変わるためである。
    case invalidCommonDirectoryPath(commonDirectory: String)
    /// 到達不能な作業ツリーと対応する admin ディレクトリを Project Root 側で特定できなかった。
    /// 作業ツリーのパスを代替 ID にすると復帰時に同一性を保証できないため、検出結果へは載せない。
    case administrativeDirectoryNotFound
    /// main worktree でない entry の `rev-parse` が、entry 自身でない git ディレクトリへ解決した。
    /// lock された worktree は `.git` を失っても `prunable` が付かず、入れるディレクトリなら
    /// `rev-parse` は祖先へ遡って exit 0 で祖先の git ディレクトリを返す (Issue #502)。検出すると
    /// 偽の Project Root や安定 ID の重複になり、別 repository の中なら `.absent` で黙って消える。
    ///
    /// 判定は2つで、`describe` はこの順に確かめる。
    /// 1. git ディレクトリが common dir そのもので、その common dir がこの Project のものである。
    ///    linked worktree の git ディレクトリは `<common>/worktrees/<名前>` であって common dir
    ///    にはならない。Project の common dir に絞るのは、別 repository に置き換わった entry も
    ///    置き換わった先の main として git ディレクトリと common dir が等しくなり、ここに当たって
    ///    しまうためである (toplevel は entry 自身なので 2 も素通りし、`.absent` になる)。遡った先が bare
    ///    (`proj/feat` → `proj/.git` の `gitdir: ./.bare`) や main の作業ツリーの場合、`.git` が
    ///    `<common>` への symlink の場合 (同レビューの m1) がここに当たる。lock 前の計測では、bare
    ///    配置で `id=<R>/proj/.bare path=<R>/proj/feat root=true`、main の中で Project Root と ID が
    ///    重複した。
    /// 2. 別のプロセスで撃つ `rev-parse --show-toplevel` の1行目が、entry のパスとバイト単位で
    ///    一致しない。遡った先が linked worktree か別 repository の作業ツリーだと、git ディレクトリは
    ///    common dir にならないので 1 では拾えない。git 2.50.1 実測 (Issue #502 のレビュー):
    ///
    ///    | entry | toplevel | 一致 |
    ///    | --- | --- | --- |
    ///    | 別 repository の中の `/other/w` | `/other` | しない (祖先へ遡った) |
    ///    | linked の中の `/feat/.worktrees/y` | `/feat` | しない (祖先へ遡った) |
    ///    | 別 repository に置き換わった `/rep` | `/rep` | する (`.absent` のまま) |
    ///    | `/main`、`/feat`、NFC の `/café`、親が symlink の linked | 同じ | する |
    ///
    ///    置き換わった `/rep` は一致するので、別 repository への置き換え (`.absent`) とは区別できる。
    ///
    /// `--show-toplevel` を `--git-dir --git-common-dir` と同じ実行に混ぜないのは、遡った先が bare
    /// だと git が `fatal: this operation must be run in a work tree` で exit 128 になり、2行も
    /// 失敗に巻き込まれて 1 の判定ができなくなるためである (git 2.50.1 実測)。代わりに git の
    /// 起動が linked worktree 1件につき1回増える。
    ///
    /// main の entry には `--show-toplevel` を撃たない。main では `worktree list` のパスと
    /// toplevel が一致しない配置 (submodule の main: `sup/.git/modules/s` → `<R>/sup/s`、
    /// `core.worktree`: `gd.git` → `<R>/wt`) や、`--show-toplevel` が上と同じ fatal になる配置
    /// (`--separate-git-dir` で main の作業ツリーが消えた) があり (同レビューの計測、Issue #376 の
    /// 領域)、Project Root の検出ごと壊れる。
    ///
    /// 不在にせず失敗にするのは、lock が「消さないで」という意思表示だからである。観測失敗として
    /// 前回の状態を残し、黙って消失させない。
    case resolvedToAncestorRepository
  }
}
