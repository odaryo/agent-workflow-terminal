import Foundation
import RemoteClient

@MainActor
protocol ClientSettingsStoring {
  func loadSettings() -> RemoteHostSettings
  func saveSettings(_ settings: RemoteHostSettings) throws
  func loadKnownHosts() -> KnownHosts
  func saveKnownHosts(_ hosts: KnownHosts) throws
}

@MainActor
struct ClientSettingsStore: ClientSettingsStoring {
  private let defaults = UserDefaults.standard

  func loadSettings() -> RemoteHostSettings {
    decode(RemoteHostSettings.self, key: "remoteHostSettings")
      ?? RemoteHostSettings(host: "", port: 22, user: "", tmuxPath: "/opt/homebrew/bin/tmux")
  }

  func saveSettings(_ settings: RemoteHostSettings) throws {
    defaults.set(try JSONEncoder().encode(settings), forKey: "remoteHostSettings")
  }

  func loadKnownHosts() -> KnownHosts {
    decode(KnownHosts.self, key: "knownHosts") ?? KnownHosts()
  }

  func saveKnownHosts(_ hosts: KnownHosts) throws {
    defaults.set(try JSONEncoder().encode(hosts), forKey: "knownHosts")
  }

  private func decode<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }
}
