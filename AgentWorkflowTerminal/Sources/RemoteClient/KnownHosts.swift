public enum HostKeyVerdict: Sendable, Equatable {
  case unknown
  case trusted
  case mismatch(trusted: SSHHostKeyFingerprint)
}

public struct KnownHosts: Sendable, Equatable, Codable {
  private var fingerprints: [String: [Int: SSHHostKeyFingerprint]] = [:]

  public init() {}

  public func verdict(
    host: String, port: Int, fingerprint: SSHHostKeyFingerprint
  ) -> HostKeyVerdict {
    guard let trusted = fingerprints[Self.normalized(host)]?[port] else { return .unknown }
    return trusted == fingerprint ? .trusted : .mismatch(trusted: trusted)
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
