import Darwin
import Foundation
import TerminalCore

extension GitWorktreeDetector {
  /// exit 0 の一覧が record を黙って欠いたかを、Project Root 側の管理ディレクトリと数で照らす
  /// (Issue #774)。欠けたのがどの worktree かは分からないので、一覧全体を不完全として扱う。
  ///
  /// - Note: `<common>/worktrees` に新しい管理ディレクトリができる `worktree add` と一覧の取得が
  ///   すれ違うと、その1回だけ不完全になる。前回の状態を保つ側へ倒れるだけで、次の回で戻る。
  static func omission(
    linkedRecords: Int,
    commonDirectory: WorktreeIdentity
  ) -> GitWorktreeOmission? {
    guard let count = listedAdministrativeDirectoryCount(commonDirectory: commonDirectory) else {
      return .administrativeDirectoriesUnreadable
    }
    guard count > linkedRecords else { return nil }
    return .missingRecords(administrativeDirectories: count, linkedRecords: linkedRecords)
  }

  /// git が一覧に出すはずの管理ディレクトリの数。`nil` は `<common>/worktrees` を readdir
  /// できなかったこと。`worktrees` が無い (ENOENT) のは linked worktree を持たない repository の
  /// 正常な形なので 0 とする。
  ///
  /// 数えるのは、子ディレクトリのうち次のどちらかに当たるものである。
  /// - 子ディレクトリそのもの、またはその `gitdir` を `lstat` できない (ENOENT 以外の失敗。
  ///   `worktrees` が 444 だと readdir はできても子は EACCES になる)。中を確かめられない以上、
  ///   一覧に出るはずのものとして数える。
  /// - `gitdir` が `lstat` で存在する (種別は問わない)。git 2.54.0 実測では、`gitdir` が 000・
  ///   ディレクトリ・空のファイルのどれでも record は出ない。作業ツリーが生きていても欠けるので、
  ///   一覧の不完全として扱う。
  ///
  /// `gitdir` が無い (ENOENT) 管理ディレクトリと、ディレクトリでない子 (`.DS_Store` 等) は数えない。
  /// git 自身も一覧に出さない。
  ///
  /// - Important: 数えた管理ディレクトリが壊れたまま残る間は、毎回のスキャンが「不完全」になる。
  ///   `git worktree prune --dry-run --verbose` (git 2.54.0 実測) は、数えない `gitdir` 無し
  ///   (`gitdir file does not exist`) だけでなく、数える 000・ディレクトリ (`unable to read gitdir
  ///   file`)・空 (`invalid gitdir file`) もすべて削除の対象に挙げる。prune されれば数から外れる。
  ///
  /// - Note: `administrativeDirectory` と同じく、打ち切る手段の無い同期 FS I/O を行う。読む先は
  ///   Project Root 側の common dir であり、作業ツリーではない。
  /// - Note: `FileManager.contentsOfDirectory` を使わないのは、444 のディレクトリで失敗するため
  ///   である (macOS 27.0.1 実測: Code=257、下は EACCES。`ls` は名前を返す)。git と同じく
  ///   `readdir` で名前を読む。
  static func listedAdministrativeDirectoryCount(commonDirectory: WorktreeIdentity) -> Int? {
    let worktrees = commonDirectory.rawValue + "/worktrees"
    guard let directory = opendir(worktrees) else { return errno == ENOENT ? 0 : nil }
    defer { closedir(directory) }
    var count = 0
    var info = stat()
    while true {
      errno = 0
      guard let entry = readdir(directory) else { return errno == 0 ? count : nil }
      let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
        String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
      }
      guard name != ".", name != ".." else { continue }
      let child = worktrees + "/" + name
      guard lstat(child, &info) == 0 else {
        if errno != ENOENT { count += 1 }
        continue
      }
      guard info.st_mode & S_IFMT == S_IFDIR else { continue }
      if lstat(child + "/gitdir", &info) == 0 || errno != ENOENT {
        count += 1
      }
    }
  }
}
