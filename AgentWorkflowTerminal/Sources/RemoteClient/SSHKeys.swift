import CryptoKit
import Foundation

public struct SSHEd25519PublicKey: Sendable, Hashable {
  private let rawRepresentation: Data

  private enum ValidationError: Error {
    case invalidLength
  }

  public init(rawRepresentation: Data) throws {
    guard rawRepresentation.count == 32 else { throw ValidationError.invalidLength }
    self.rawRepresentation = rawRepresentation
  }

  public var wireFormat: [UInt8] {
    [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32] + rawRepresentation
  }

  public func authorizedKeysLine(comment: String) -> String {
    let key = "ssh-ed25519 " + Data(wireFormat).base64EncodedString()
    return comment.isEmpty ? key : key + " " + comment
  }

  public var fingerprint: SSHHostKeyFingerprint { SSHHostKeyFingerprint(wireFormat: wireFormat) }
}

public struct SSHHostKeyFingerprint: Sendable, Hashable, Codable {
  public let rawValue: String

  public init(wireFormat: [UInt8]) {
    let digest = SHA256.hash(data: Data(wireFormat))
    rawValue =
      "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
  }

  public init?(openSSHPublicKeyLine: String) {
    let fields = openSSHPublicKeyLine.split(whereSeparator: { $0.isWhitespace })
    guard fields.count >= 2, let data = Data(base64Encoded: String(fields[1])) else { return nil }
    let wire = Array(data)
    guard wire.count >= 4 else { return nil }
    let length = wire.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard let typeLength = Int(exactly: length), typeLength <= wire.count - 4,
      wire[4..<(4 + typeLength)].elementsEqual(fields[0].utf8)
    else { return nil }
    self.init(wireFormat: wire)
  }
}
