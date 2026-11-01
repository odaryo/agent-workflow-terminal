/// 登録解除で「session とデータも削除」を選んだときに消す tmux session を決める (Issue #406)。
public enum ProjectSessionCleanup {
  /// `projectCommonDirectory` を候補に入れるのは、Project Root の安定 ID が `<git common dir>`
  /// そのものなので、保存も観測も無い Project でも Project Root の session を導出できるため。
  /// 到達不能な Project では `observed` が空になり、`saved` だけが task worktree の手がかりになる。
  ///
  /// `existingSessionNames` との照合は導出名との完全一致だけで行う。`awt-` 接頭辞は管理下に
  /// あることの証明にならない (`TmuxSessionOperations.list()` の注釈)。
  ///
  /// 候補は Project Root そのものか `<common>/worktrees/` 直下の1要素だけに絞る。保存ファイルや
  /// 観測に別 Project の安定 ID が紛れると、その Project の session を消してしまうため。linked
  /// worktree の安定 ID がこの形になることは git 2.50.1 で実測した (通常の `worktree add`、
  /// symlink 経由のパス、`--relative-paths`、到達不能な worktree、bare repository、NFC の非 ASCII
  /// パス。Issue #406)。`<common>/worktrees/<wt>/modules/<sub>` は submodule の common dir で、
  /// 別 Project になりうるため、接頭辞だけでは判定しない。接頭辞は `String.hasPrefix` ではなく
  /// UTF-8 バイト列で比べる — `hasPrefix` は正準等価を見るので、NFD 表記の別 Project を同じものと答える
  /// (`WorktreeIdentity` の同一性がバイト列であるのと揃える)。
  public static func sessions(
    projectCommonDirectory: WorktreeIdentity,
    saved: PersistedWorktreeInventory?,
    observed: [WorktreeIdentity],
    existingSessionNames: [String]
  ) -> [TmuxSessionName] {
    let candidates =
      [projectCommonDirectory]
      + [saved?.projectRoot?.identity].compactMap { $0 }
      + (saved?.taskWorktrees.map(\.identity) ?? [])
      + observed
    let linkedWorktreePrefix = Array((projectCommonDirectory.rawValue + "/worktrees/").utf8)
    let existing = Set(existingSessionNames)

    var seen: Set<TmuxSessionName> = []
    var result: [TmuxSessionName] = []
    for identity in candidates
    where identity == projectCommonDirectory
      || (identity.rawValue.utf8.starts(with: linkedWorktreePrefix)
        && identity.rawValue.utf8.count > linkedWorktreePrefix.count
        && !identity.rawValue.utf8.dropFirst(linkedWorktreePrefix.count).contains(UInt8(ascii: "/")))
    {
      let name = TmuxSessionName(identity: identity)
      guard existing.contains(name.rawValue), seen.insert(name).inserted else { continue }
      result.append(name)
    }
    return result
  }
}
