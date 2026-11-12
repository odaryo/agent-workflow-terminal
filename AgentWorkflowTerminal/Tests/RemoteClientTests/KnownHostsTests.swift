import Foundation
import RemoteClient
import Testing

@Suite("KnownHosts の host・port ごとの承認")
struct KnownHostsTests {
  private func fingerprints() throws -> (SSHHostKeyFingerprint, SSHHostKeyFingerprint) {
    (
      SSHHostKeyFingerprint(wireFormat: try SSHKeyExamples.wire(SSHKeyExamples.publicKeyBase64)),
      SSHHostKeyFingerprint(wireFormat: try SSHKeyExamples.wire(SSHKeyExamples.hostKeyBase64))
    )
  }

  @Test("未承認は unknown、承認後は trusted、変更された鍵は元の指紋付き mismatch")
  func trustAndMismatch() throws {
    let (original, changed) = try fingerprints()
    var hosts = KnownHosts()
    #expect(hosts.verdict(host: "mac", port: 22, fingerprint: original) == .unknown)
    hosts.trust(host: "mac", port: 22, fingerprint: original)
    #expect(hosts.verdict(host: "mac", port: 22, fingerprint: original) == .trusted)
    #expect(
      hosts.verdict(host: "mac", port: 22, fingerprint: changed) == .mismatch(trusted: original))
  }

  @Test("ASCII の大文字小文字は同一 host、別 host と別 port は未承認")
  func hostAndPortIdentity() throws {
    let (fingerprint, _) = try fingerprints()
    var hosts = KnownHosts()
    hosts.trust(host: "Mac.Studio.TS.NET", port: 22, fingerprint: fingerprint)
    #expect(
      hosts.verdict(host: "mac.studio.ts.net", port: 22, fingerprint: fingerprint) == .trusted)
    #expect(
      hosts.verdict(host: "MAC.STUDIO.TS.NET", port: 22, fingerprint: fingerprint) == .trusted)
    #expect(hosts.verdict(host: "other.ts.net", port: 22, fingerprint: fingerprint) == .unknown)
    #expect(
      hosts.verdict(host: "mac.studio.ts.net", port: 2222, fingerprint: fingerprint) == .unknown)
  }

  @Test("再承認は同じ host・port だけを置き換える")
  func replacesTrust() throws {
    let (original, changed) = try fingerprints()
    var hosts = KnownHosts()
    hosts.trust(host: "Mac", port: 22, fingerprint: original)
    hosts.trust(host: "Mac", port: 2222, fingerprint: original)
    hosts.trust(host: "other", port: 22, fingerprint: original)
    hosts.trust(host: "MAC", port: 22, fingerprint: changed)
    #expect(hosts.verdict(host: "mac", port: 22, fingerprint: changed) == .trusted)
    #expect(
      hosts.verdict(host: "mac", port: 22, fingerprint: original) == .mismatch(trusted: changed))
    #expect(hosts.verdict(host: "mac", port: 2222, fingerprint: original) == .trusted)
    #expect(hosts.verdict(host: "other", port: 22, fingerprint: original) == .trusted)
  }

  @Test("削除は大文字小文字を区別せず対象 host・port だけを消す")
  func removesTrust() throws {
    let (fingerprint, _) = try fingerprints()
    var hosts = KnownHosts()
    hosts.trust(host: "Mac", port: 22, fingerprint: fingerprint)
    hosts.trust(host: "Mac", port: 2222, fingerprint: fingerprint)
    hosts.trust(host: "other", port: 22, fingerprint: fingerprint)
    hosts.remove(host: "MAC", port: 22)
    #expect(hosts.verdict(host: "mac", port: 22, fingerprint: fingerprint) == .unknown)
    #expect(hosts.verdict(host: "mac", port: 2222, fingerprint: fingerprint) == .trusted)
    #expect(hosts.verdict(host: "other", port: 22, fingerprint: fingerprint) == .trusted)
    let before = hosts
    hosts.remove(host: "missing", port: 22)
    #expect(hosts == before)
  }

  @Test("Codable の往復後にも複数宛先の承認を保持し、コピーは独立する")
  func persistenceAndValueSemantics() throws {
    let (original, changed) = try fingerprints()
    var hosts = KnownHosts()
    hosts.trust(host: "Mac", port: 22, fingerprint: original)
    hosts.trust(host: "other", port: 2222, fingerprint: changed)
    let decoded = try JSONDecoder().decode(
      KnownHosts.self, from: JSONEncoder().encode(hosts))
    #expect(decoded == hosts)
    #expect(decoded.verdict(host: "MAC", port: 22, fingerprint: original) == .trusted)
    #expect(decoded.verdict(host: "other", port: 2222, fingerprint: changed) == .trusted)
    var copy = decoded
    copy.remove(host: "mac", port: 22)
    #expect(copy != hosts)
    #expect(hosts.verdict(host: "mac", port: 22, fingerprint: original) == .trusted)
  }

  @Test("trustedFingerprint は承認・置換・削除と host・port の区別を反映する")
  func trustedFingerprint() throws {
    let (original, changed) = try fingerprints()
    var hosts = KnownHosts()
    #expect(hosts.trustedFingerprint(host: "mac", port: 22) == nil)
    hosts.trust(host: "Mac", port: 22, fingerprint: original)
    #expect(hosts.trustedFingerprint(host: "mac", port: 22) == original)
    #expect(hosts.trustedFingerprint(host: "MAC", port: 22) == original)
    #expect(hosts.trustedFingerprint(host: "mac", port: 2222) == nil)
    #expect(hosts.trustedFingerprint(host: "other", port: 22) == nil)
    hosts.trust(host: "MAC", port: 22, fingerprint: changed)
    #expect(hosts.trustedFingerprint(host: "mac", port: 22) == changed)
    hosts.remove(host: "Mac", port: 22)
    #expect(hosts.trustedFingerprint(host: "mac", port: 22) == nil)
  }

  @Test("保存 JSON は小文字 host・port 昇順の配列と文字列指紋に固定する")
  func fixedPersistenceFormat() throws {
    let (original, changed) = try fingerprints()
    var hosts = KnownHosts()
    hosts.trust(host: "Z.example", port: 22, fingerprint: changed)
    hosts.trust(host: "Mac.Example", port: 2222, fingerprint: changed)
    hosts.trust(host: "MAC.EXAMPLE", port: 22, fingerprint: original)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let expected =
      #"[{"fingerprint":"SHA256:acUiZchhzxDn9C0skQXmrQKnIs5+qPfoXBVG05mcgrM","host":"mac.example","port":22},"#
      + #"{"fingerprint":"SHA256:BX8BtS8VKvswjsNTPShlwFaVHfO4DQiTFrPYgN7MI8A","host":"mac.example","port":2222},"#
      + #"{"fingerprint":"SHA256:BX8BtS8VKvswjsNTPShlwFaVHfO4DQiTFrPYgN7MI8A","host":"z.example","port":22}]"#
    #expect(String(decoding: try encoder.encode(hosts), as: UTF8.self) == expected)
    let decoded = try JSONDecoder().decode(KnownHosts.self, from: Data(expected.utf8))
    #expect(decoded == hosts)
    #expect(String(decoding: try encoder.encode(KnownHosts()), as: UTF8.self) == "[]")
    #expect(try JSONDecoder().decode(KnownHosts.self, from: Data("[]".utf8)) == KnownHosts())
  }

  @Test("保存データの host も decode 時に小文字へ正規化する")
  func normalizesDecodedHost() throws {
    let json = """
      [{"host":"MAC.Example","port":22,"fingerprint":"SHA256:acUiZchhzxDn9C0skQXmrQKnIs5+qPfoXBVG05mcgrM"}]
      """
    let (fingerprint, _) = try fingerprints()
    let hosts = try JSONDecoder().decode(KnownHosts.self, from: Data(json.utf8))
    #expect(hosts.trustedFingerprint(host: "mac.example", port: 22) == fingerprint)
    #expect(hosts.verdict(host: "MAC.EXAMPLE", port: 22, fingerprint: fingerprint) == .trusted)
    var expected = KnownHosts()
    expected.trust(host: "mac.example", port: 22, fingerprint: fingerprint)
    #expect(hosts == expected)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(hosts) == encoder.encode(expected))
  }
}
