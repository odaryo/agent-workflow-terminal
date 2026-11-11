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
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  init() {}

  func register(address: UInt) -> GhosttySurfaceID {
    state.withLock { state in
      state.lastID += 1
      let surfaceID = GhosttySurfaceID(rawValue: state.lastID)
      state.identities[address] = surfaceID
      return surfaceID
    }
  }

  func unregister(address: UInt, id: GhosttySurfaceID) {
    state.withLock { state in
      guard state.identities[address] == id else { return }
      state.identities.removeValue(forKey: address)
    }
  }

  func id(forAddress address: UInt) -> GhosttySurfaceID? {
    state.withLock { $0.identities[address] }
  }
}
