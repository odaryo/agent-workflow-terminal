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
    case gitDirectory(GitRunnerError)
    /// `rev-parse` の出力が main では2行、main でない entry では4行 (`describe`) でなかった。
    /// パス自体に改行が含まれる場合と、`--is-bare-repository` が `true` / `false` でない場合も
    /// ここへ来る。
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
    /// 判定は main でない entry にだけ、同じ1回の `rev-parse` に `--is-bare-repository` と
    /// `--show-prefix` を足して、この順に行う (`describe`)。どれにも当たらなければ、common dir の
    /// 照合 (別 Project なら `.absent`) へ進む。
    /// 1. git ディレクトリが common dir そのもので、その common dir がこの Project のものである。
    ///    linked worktree の git ディレクトリは `<common>/worktrees/<名前>` であって common dir
    ///    にはならない。遡った先が bare (`proj/feat` → `proj/.git` の `gitdir: ./.bare`) や main の
    ///    作業ツリーの場合、`.git` が `<common>` への symlink の場合 (同レビューの m1) がここに
    ///    当たる。lock 前の計測では、bare 配置で `id=<R>/proj/.bare path=<R>/proj/feat root=true`、
    ///    main の中で Project Root と ID が重複した。Project の common dir に絞るのは、別
    ///    repository に置き換わった entry も、置き換わった先の main として git ディレクトリと
    ///    common dir が等しくなるためである (それは 2 と 3 も素通りして `.absent` になる)。
    /// 2. `--is-bare-repository` が `true`。linked worktree が bare になることは無いので、別の bare
    ///    repository の中 (`other.git/w`) へ遡ったことになる。これは git ディレクトリと common dir
    ///    が等しく common dir が別 Project で、prefix も空なので、置き換わった entry と同じ形になる。
    /// 3. `--show-prefix` が空でない。entry のディレクトリが作業ツリーの根でなく、祖先の作業ツリーの
    ///    中にいる。
    ///
    /// git 2.50.1 実測 (Issue #502 の再レビューと実装時の計測):
    ///
    /// | 場合 | `--is-bare-repository` | `--show-prefix` |
    /// | --- | --- | --- |
    /// | 祖先へ遡った (`.worktrees/y`、別 repository の中の `w`、main の中の `.worktrees/x`) | `false` | 空でない |
    /// | 正常な linked (`feat`、linked 側の `core.worktree`、`worktree move`、大小違い、NFC 記録) | `false` | 空 |
    /// | 別 repository に置き換わった `rep` | `false` | 空 |
    /// | 遡った先が bare (`proj/z`、`other.git/w`) | `true` | exit 0 で空 |
    ///
    /// **パスは比べない。** `worktree list` のパスは gitdir ファイルに記録された打った表記で、
    /// `--show-toplevel` などが返すディスク上の表記とずれる。APFS は大小を区別しないので大小を
    /// 変えて打てばずれ、`core.precomposeunicode=true` の git は NFC で記録するが `FileManager` が
    /// 作るディレクトリは NFD である。linked 側の `core.worktree` では別のディレクトリになる。
    /// 比べると正常な linked worktree が恒久的に失敗になる (同レビューの Critical C2)。
    ///
    /// main の entry には足さない。main には `worktree list` のパスと作業ツリーがずれる配置
    /// (submodule、`core.worktree`、`--separate-git-dir`。Issue #376 の領域) があり、そこで2つの
    /// 値がどう出るかは測っていない。
    ///
    /// 不在にせず失敗にするのは、lock が「消さないで」という意思表示だからである。観測失敗として
    /// 前回の状態を残し、黙って消失させない。
    case resolvedToAncestorRepository
  }
}
