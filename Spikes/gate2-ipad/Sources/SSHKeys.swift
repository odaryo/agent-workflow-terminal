import Crypto
import Foundation
import NIOCore
import NIOSSH
import Security

enum SpikeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

enum DeviceKey {
    static func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.odaryo.awt.spike.gate2ipad",
            kSecAttrAccount as String: "ed25519",
            kSecAttrSynchronizable as String: false,
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        guard status == errSecItemNotFound else {
            throw SpikeError.message("Keychain 読み取り失敗: \(status)")
        }
        let key = Curve25519.Signing.PrivateKey()
        var item = query
        item[kSecValueData as String] = key.rawRepresentation
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SpikeError.message("Keychain 保存失敗: \(addStatus)")
        }
        return key
    }

    static func authorizedKey(_ key: Curve25519.Signing.PrivateKey) -> String {
        var buffer = ByteBuffer()
        let name = Array("ssh-ed25519".utf8)
        let publicKey = key.publicKey.rawRepresentation
        buffer.writeInteger(UInt32(name.count))
        buffer.writeBytes(name)
        buffer.writeInteger(UInt32(publicKey.count))
        buffer.writeBytes(publicKey)
        return "ssh-ed25519 \(Data(buffer.readableBytesView).base64EncodedString()) awt-gate2-ipad"
    }
}

struct HostKeyReview {
    let endpoint: String
    let received: Data
    let saved: Data?

    static func fingerprint(_ data: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }
}

final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let expected: Data?
    private let lock = NSLock()
    private var rejectedKey: Data?

    init(expected: Data?) {
        self.expected = expected
    }

    var received: Data? {
        lock.lock()
        defer { lock.unlock() }
        return rejectedKey
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let data = Data(buffer.readableBytesView)
        if data == expected {
            validationCompletePromise.succeed(())
        } else {
            // 接続失敗が UI へ戻る前に、NIO の同期コールバックで鍵を確定させる。
            lock.lock()
            rejectedKey = data
            lock.unlock()
            validationCompletePromise.fail(SpikeError.message("host key が未承認、または保存済みの鍵と不一致"))
        }
    }
}

enum KnownHosts {
    private static let defaultsKey = "gate2.knownHosts"

    static func key(for endpoint: String) -> Data? {
        guard let value = UserDefaults.standard.dictionary(forKey: defaultsKey)?[endpoint] as? String else {
            return nil
        }
        return Data(base64Encoded: value)
    }

    static func save(_ data: Data?, for endpoint: String) {
        var hosts = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        hosts[endpoint] = data?.base64EncodedString()
        UserDefaults.standard.set(hosts, forKey: defaultsKey)
    }
}
