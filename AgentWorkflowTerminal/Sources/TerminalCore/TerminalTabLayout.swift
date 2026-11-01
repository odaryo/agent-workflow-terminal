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
    // モバイルなど別のクライアントが前の名前の session を握っている可能性があるため、欠番を使い回さない。
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
    if indices.isEmpty {
      indicesByIdentity.removeValue(forKey: key.identity)
    } else {
      indicesByIdentity[key.identity] = indices
    }
  }
}
