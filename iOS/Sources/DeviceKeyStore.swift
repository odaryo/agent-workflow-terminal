import CryptoKit
import Foundation
import RemoteClient
import Security

protocol DeviceKeyStoring {
  func loadOrCreate() throws -> Curve25519.Signing.PrivateKey
  func publicKey() throws -> SSHEd25519PublicKey
}

struct DeviceKeyStore: DeviceKeyStoring {
  struct KeychainError: Error {
    let status: OSStatus
  }

  private var query: [String: Any] {
    get throws {
      guard let service = Bundle.main.bundleIdentifier else {
        throw KeychainError(status: errSecParam)
      }
      return [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "ssh-ed25519",
        kSecAttrSynchronizable as String: false,
      ]
    }
  }

  func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
    var lookup = try query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecSuccess {
      guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
      do {
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
      } catch {
        throw KeychainError(status: errSecDecode)
      }
    }
    guard status == errSecItemNotFound else { throw KeychainError(status: status) }
    let key = Curve25519.Signing.PrivateKey()
    var item = try query
    item[kSecValueData as String] = key.rawRepresentation
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let saved = SecItemAdd(item as CFDictionary, nil)
    // 同時の初回呼び出しで先に保存された鍵を上書きしない。
    if saved == errSecDuplicateItem { return try loadOrCreate() }
    guard saved == errSecSuccess else { throw KeychainError(status: saved) }
    return key
  }

  func publicKey() throws -> SSHEd25519PublicKey {
    try SSHEd25519PublicKey(rawRepresentation: loadOrCreate().publicKey.rawRepresentation)
  }
}
