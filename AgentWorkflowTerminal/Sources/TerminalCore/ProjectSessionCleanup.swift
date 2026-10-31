/// 登録解除で「session とデータも削除」を選んだときに消す tmux session を決める (Issue #406)。
public enum ProjectSessionCleanup {
  /// `projectCommonDirectory` を候補に入れるのは、Project Root の安定 ID が `<git common dir>`
  /// そのものなので、保存も観測も無い Project でも Project Root の session を導出できるため。
  /// 到達不能な Project では `observed` が空になり、`saved` だけが task worktree の手がかりになる。
  ///
  /// `existingSessionNames` との照合は導出名との完全一致だけで行う。`awt-` 接頭辞は管理下に
  /// あることの証明にならない (`TmuxSessionOperations.list()` の注釈)。
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
    let existing = Set(existingSessionNames)

    var seen: Set<TmuxSessionName> = []
    var result: [TmuxSessionName] = []
    for identity in candidates {
      let name = TmuxSessionName(identity: identity)
      guard existing.contains(name.rawValue), seen.insert(name).inserted else { continue }
      result.append(name)
    }
    return result
  }
}
