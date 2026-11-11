import os

struct GhosttySurfaceID: Hashable, Sendable {
  fileprivate let rawValue: UInt64
}

// Why not actor: 同期の action callback 内で世代を確定しないと、main queue への hop 中に
// アドレスが再利用されて別世代の ID を取得してしまう (Issue #125 の計測1)。
final class GhosttySurfaceIdentities: Sendable {
  static let shared = GhosttySurfaceIdentities()

  private struct State {
    var lastID: UInt64 = 0
    var identities: [UInt: GhosttySurfaceID] = [:]
    var creatingID: GhosttySurfaceID?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  init() {}

  func beginCreation() -> GhosttySurfaceID {
    state.withLock { state in
      state.lastID += 1
      let surfaceID = GhosttySurfaceID(rawValue: state.lastID)
      state.creatingID = surfaceID
      return surfaceID
    }
  }

  func finishCreation(address: UInt?) {
    state.withLock { state in
      if let address, let surfaceID = state.creatingID {
        state.identities[address] = surfaceID
      }
      state.creatingID = nil
    }
  }

  func unregister(address: UInt, id: GhosttySurfaceID) {
    state.withLock { state in
      guard state.identities[address] == id else { return }
      state.identities.removeValue(forKey: address)
    }
  }

  func id(forAddress address: UInt) -> GhosttySurfaceID? {
    // Why 未登録なら生成中の ID: 生成は main で同期に1つずつ行い、生存中はすべて登録済みで、
    // free 後も drain まで登録を残すため、未登録アドレスの action は生成中の surface に限られる。
    state.withLock { $0.identities[address] ?? $0.creatingID }
  }
}
