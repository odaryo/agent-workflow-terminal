public struct TerminalTabLayout: Sendable, Equatable {
  private var indicesByIdentity: [WorktreeIdentity: [Int]] = [:]

  public init() {}

  public func tabs(directories: [WorktreeIdentity]) -> [TerminalSessionKey] {
    var seen: Set<WorktreeIdentity> = []
    return directories.flatMap { identity -> [TerminalSessionKey] in
      guard seen.insert(identity).inserted else { return [] }
      return tabs(in: identity)
    }
  }

  public func tabs(in identity: WorktreeIdentity) -> [TerminalSessionKey] {
    guard let indices = indicesByIdentity[identity] else { return [.primary(identity)] }
    return indices.compactMap { TerminalSessionKey(identity: identity, index: $0) }
  }

  public mutating func addTab(
    in identity: WorktreeIdentity,
    existingSessionNames: [String]
  ) -> TerminalSessionKey? {
    var indices = indicesByIdentity[identity] ?? [1]
    let existingMaximum = TmuxSessionName.indices(of: identity, in: existingSessionNames).last ?? 1
    // 欠番を詰めない: 再起動後に番号の昇順でタブを復元すると作った順に並ぶ (設計書 §3.5)。
    // 最大の番号のタブを閉じた後は、その番号を再び使う (session はもう無い)。
    let nextIndex = max(indices.last ?? 1, existingMaximum) + 1
    guard let key = TerminalSessionKey(identity: identity, index: nextIndex) else { return nil }
    indices.append(nextIndex)
    indicesByIdentity[identity] = indices
    return key
  }

  public mutating func removeTab(_ key: TerminalSessionKey) {
    guard var indices = indicesByIdentity[key.identity] else { return }
    // 設計書 §3.1 は最初からのタブと後から足したタブを区別しないため、primary も削除対象にする。
    indices.removeAll { $0 == key.index }
    // [1] だけに戻ったら既定と同じ形にする。残すと tabs は同じなのに == が false になる。
    if indices.isEmpty || indices == [1] {
      indicesByIdentity.removeValue(forKey: key.identity)
    } else {
      indicesByIdentity[key.identity] = indices
    }
  }
}
