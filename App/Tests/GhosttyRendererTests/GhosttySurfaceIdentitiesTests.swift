import Testing

@testable import GhosttyRenderer

@Suite("surface の世代識別")
struct GhosttySurfaceIdentitiesTests {
  @Test("同じアドレスを解放後に再登録すると別の ID になる")
  func reregisterAddress() {
    let identities = GhosttySurfaceIdentities()
    let oldID = identities.register(address: 1)
    identities.unregister(address: 1, id: oldID)

    let newID = identities.register(address: 1)

    #expect(oldID != newID)
    #expect(identities.id(forAddress: 1) == newID)
  }

  @Test("古い ID で解除しても新しい対応は消えない")
  func unregisterOldID() {
    let identities = GhosttySurfaceIdentities()
    let oldID = identities.register(address: 1)
    let newID = identities.register(address: 1)

    identities.unregister(address: 1, id: oldID)

    #expect(identities.id(forAddress: 1) == newID)
  }

  @Test("登録を解除したアドレスには ID がない")
  func unregisterAddress() {
    let identities = GhosttySurfaceIdentities()
    let surfaceID = identities.register(address: 1)

    identities.unregister(address: 1, id: surfaceID)

    #expect(identities.id(forAddress: 1) == nil)
  }

  @Test("異なるアドレスには異なる ID を発行する")
  func registerDifferentAddresses() {
    let identities = GhosttySurfaceIdentities()

    let firstID = identities.register(address: 1)
    let secondID = identities.register(address: 2)

    #expect(firstID != secondID)
  }
}
