public enum HostKeyVerdict: Sendable, Equatable {
  case unknown
  case trusted
  case mismatch(trusted: SSHHostKeyFingerprint)
}

public struct KnownHosts: Sendable, Equatable, Codable {
  private var fingerprints: [String: [Int: SSHHostKeyFingerprint]] = [:]

  public init() {}

  private struct Entry: Codable {
    let host: String
    let port: Int
    let fingerprint: SSHHostKeyFingerprint
  }

  public init(from decoder: any Decoder) throws {
    let entries = try decoder.singleValueContainer().decode([Entry].self)
    for entry in entries {
      trust(host: entry.host, port: entry.port, fingerprint: entry.fingerprint)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var entries: [Entry] = []
    for host in fingerprints.keys.sorted() {
      guard let ports = fingerprints[host] else { continue }
      for port in ports.keys.sorted() {
        guard let fingerprint = ports[port] else { continue }
        entries.append(Entry(host: host, port: port, fingerprint: fingerprint))
      }
    }
    var container = encoder.singleValueContainer()
    try container.encode(entries)
  }

  public func verdict(
    host: String, port: Int, fingerprint: SSHHostKeyFingerprint
  ) -> HostKeyVerdict {
    guard let trusted = trustedFingerprint(host: host, port: port) else { return .unknown }
    return trusted == fingerprint ? .trusted : .mismatch(trusted: trusted)
  }

  public func trustedFingerprint(host: String, port: Int) -> SSHHostKeyFingerprint? {
    fingerprints[Self.normalized(host)]?[port]
  }

  public mutating func trust(host: String, port: Int, fingerprint: SSHHostKeyFingerprint) {
    fingerprints[Self.normalized(host), default: [:]][port] = fingerprint
  }

  public mutating func remove(host: String, port: Int) {
    let key = Self.normalized(host)
    fingerprints[key]?[port] = nil
    if fingerprints[key]?.isEmpty == true { fingerprints[key] = nil }
  }

  private static func normalized(_ host: String) -> String {
    String(decoding: host.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
  }
}
