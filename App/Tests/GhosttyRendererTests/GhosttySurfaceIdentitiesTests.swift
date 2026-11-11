import Testing

@testable import GhosttyRenderer

@Suite("surface の世代識別")
struct GhosttySurfaceIdentitiesTests {
  @Test("同じアドレスを解放後に再登録すると別の ID になる")
  func reregisterAddress() {
    let identities = GhosttySurfaceIdentities()
    let oldID = identities.beginCreation()
    identities.finishCreation(address: 1)
    identities.unregister(address: 1, id: oldID)

    let newID = identities.beginCreation()
    identities.finishCreation(address: 1)

    #expect(oldID != newID)
    #expect(identities.id(forAddress: 1) == newID)
  }

  @Test("古い ID で解除しても新しい対応は消えない")
  func unregisterOldID() {
    let identities = GhosttySurfaceIdentities()
    let oldID = identities.beginCreation()
    identities.finishCreation(address: 1)
    let newID = identities.beginCreation()
    identities.finishCreation(address: 1)

    identities.unregister(address: 1, id: oldID)

    #expect(identities.id(forAddress: 1) == newID)
  }

  @Test("登録を解除したアドレスには ID がない")
  func unregisterAddress() {
    let identities = GhosttySurfaceIdentities()
    let surfaceID = identities.beginCreation()
    identities.finishCreation(address: 1)

    identities.unregister(address: 1, id: surfaceID)

    #expect(identities.id(forAddress: 1) == nil)
  }

  @Test("異なるアドレスには異なる ID を発行する")
  func registerDifferentAddresses() {
    let identities = GhosttySurfaceIdentities()

    let firstID = identities.beginCreation()
    identities.finishCreation(address: 1)
    let secondID = identities.beginCreation()
    identities.finishCreation(address: 2)

    #expect(firstID != secondID)
  }

  @Test("生成中は未登録のアドレスから生成中の ID を取得できる")
  func lookupDuringCreation() {
    let identities = GhosttySurfaceIdentities()
    let surfaceID = identities.beginCreation()

    #expect(identities.id(forAddress: 1) == surfaceID)
  }

  @Test("生成成功後は返されたアドレスだけで生成中と同じ ID を取得できる")
  func finishCreation() {
    let identities = GhosttySurfaceIdentities()
    let surfaceID = identities.beginCreation()

    identities.finishCreation(address: 1)

    #expect(identities.id(forAddress: 1) == surfaceID)
    #expect(identities.id(forAddress: 2) == nil)
  }

  @Test("生成失敗後は未登録のアドレスに ID がない")
  func failCreation() {
    let identities = GhosttySurfaceIdentities()
    _ = identities.beginCreation()

    identities.finishCreation(address: nil)

    #expect(identities.id(forAddress: 1) == nil)
  }

  @Test("生成中でも登録済みのアドレスは登録された ID を返す")
  func registeredAddressDuringCreation() {
    let identities = GhosttySurfaceIdentities()
    let registeredID = identities.beginCreation()
    identities.finishCreation(address: 1)
    let creatingID = identities.beginCreation()

    #expect(registeredID != creatingID)
    #expect(identities.id(forAddress: 1) == registeredID)
    #expect(identities.id(forAddress: 2) == creatingID)
  }
}
