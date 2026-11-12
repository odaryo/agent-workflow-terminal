import Foundation
import RemoteClient
import Testing

enum SSHKeyExamples {
  static let publicKeyBase64 =
    "AAAAC3NzaC1lZDI1NTE5AAAAICHmQHHNsPTGZzi7Yito0IY66ZZKwUXMezgUOq0TK7uD"
  static let hostKeyBase64 =
    "AAAAC3NzaC1lZDI1NTE5AAAAIDrhIlJR05nGs8AyaQIYXy1Y73JtVzPGjvk1V9dSKKwW"
  static let publicKeyFingerprint = "SHA256:acUiZchhzxDn9C0skQXmrQKnIs5+qPfoXBVG05mcgrM"
  static let hostKeyFingerprint = "SHA256:BX8BtS8VKvswjsNTPShlwFaVHfO4DQiTFrPYgN7MI8A"

  static func wire(_ base64: String) throws -> [UInt8] {
    Array(try #require(Data(base64Encoded: base64)))
  }
}

@Suite("ed25519 公開鍵と OpenSSH 指紋")
struct SSHKeyTests {
  @Test("実測した32バイト鍵を SSH wire 形式にする")
  func wireFormat() throws {
    let wire = try SSHKeyExamples.wire(SSHKeyExamples.publicKeyBase64)
    let key = try SSHEd25519PublicKey(rawRepresentation: Data(wire.suffix(32)))
    #expect(key.wireFormat == wire)
    #expect(
      Array(key.wireFormat.prefix(19)) == [
        0, 0, 0, 11, 115, 115, 104, 45, 101, 100, 50, 53, 53, 49, 57, 0, 0, 0, 32,
      ])
    #expect(key.fingerprint.rawValue == SSHKeyExamples.publicKeyFingerprint)
  }

  @Test("32バイト以外は拒否する", arguments: [0, 1, 31, 33, 64])
  func rejectsInvalidLength(count: Int) {
    #expect(throws: (any Error).self) {
      try SSHEd25519PublicKey(rawRepresentation: Data(repeating: 0, count: count))
    }
  }

  @Test("authorized_keys のコメントと末尾空白", arguments: ["", "ipad", "iPad 計測"])
  func authorizedKeysLine(comment: String) throws {
    let wire = try SSHKeyExamples.wire(SSHKeyExamples.publicKeyBase64)
    let key = try SSHEd25519PublicKey(rawRepresentation: Data(wire.suffix(32)))
    let suffix = comment.isEmpty ? "" : " " + comment
    #expect(
      key.authorizedKeysLine(comment: comment) == "ssh-ed25519 "
        + SSHKeyExamples.publicKeyBase64 + suffix)
  }

  @Test(
    "wire 全体の SHA256 を OpenSSH のパディング無し指紋にする",
    arguments: [
      (SSHKeyExamples.publicKeyBase64, SSHKeyExamples.publicKeyFingerprint),
      (SSHKeyExamples.hostKeyBase64, SSHKeyExamples.hostKeyFingerprint),
    ]
  )
  func measuredFingerprints(base64: String, expected: String) throws {
    let fingerprint = SSHHostKeyFingerprint(wireFormat: try SSHKeyExamples.wire(base64))
    #expect(fingerprint.rawValue == expected)
    #expect(!fingerprint.rawValue.hasSuffix("="))
  }

  @Test("OpenSSH 公開鍵行はコメントの有無にかかわらず読める", arguments: ["", " ipad 計測"])
  func parsesPublicKeyLine(comment: String) throws {
    let fingerprint = try #require(
      SSHHostKeyFingerprint(
        openSSHPublicKeyLine: "ssh-ed25519 " + SSHKeyExamples.hostKeyBase64 + comment))
    #expect(fingerprint.rawValue == SSHKeyExamples.hostKeyFingerprint)
  }

  @Test(
    "不正な base64・wire の型名不一致・切れた string は拒否する",
    arguments: [
      "", "ssh-ed25519", "ssh-ed25519 !!!", "ssh-ed25519 AA==",
      "ssh-ed25519 /////w==", "ssh-ed25519 AAAAC3NzaA==",
      "ssh-rsa " + SSHKeyExamples.hostKeyBase64,
    ]
  )
  func rejectsInvalidPublicKeyLine(line: String) {
    #expect(SSHHostKeyFingerprint(openSSHPublicKeyLine: line) == nil)
  }

  @Test("鍵と指紋の値等価性・Hashable・Codable")
  func valueSemantics() throws {
    let wire = try SSHKeyExamples.wire(SSHKeyExamples.publicKeyBase64)
    let raw = Data(wire.suffix(32))
    let key = try SSHEd25519PublicKey(rawRepresentation: raw)
    let sameKey = try SSHEd25519PublicKey(rawRepresentation: raw)
    let otherKey = try SSHEd25519PublicKey(rawRepresentation: Data(repeating: 0, count: 32))
    #expect(key == sameKey)
    #expect(key != otherKey)
    #expect(Set([key, sameKey, otherKey]).count == 2)
    let fingerprint = SSHHostKeyFingerprint(wireFormat: wire)
    let other = SSHHostKeyFingerprint(
      wireFormat: try SSHKeyExamples.wire(SSHKeyExamples.hostKeyBase64))
    #expect(fingerprint != other)
    #expect(Set([fingerprint, key.fingerprint, other]).count == 2)
    let decoded = try JSONDecoder().decode(
      SSHHostKeyFingerprint.self, from: JSONEncoder().encode(fingerprint))
    #expect(decoded == fingerprint)
    #expect(decoded.rawValue == SSHKeyExamples.publicKeyFingerprint)
  }
}
