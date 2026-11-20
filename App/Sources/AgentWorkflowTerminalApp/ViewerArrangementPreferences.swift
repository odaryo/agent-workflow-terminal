import Foundation
import TerminalCore

enum ViewerArrangementPreferences {
  static let key = "viewerDrawer.contentArrangements"

  static func load(from defaults: UserDefaults = .standard) -> ViewerContentArrangements {
    guard let data = defaults.data(forKey: key) else { return .defaults }
    return (try? JSONDecoder().decode(ViewerContentArrangements.self, from: data)) ?? .defaults
  }

  static func save(_ arrangements: ViewerContentArrangements, to defaults: UserDefaults = .standard)
  {
    guard let data = try? JSONEncoder().encode(arrangements) else { return }
    defaults.set(data, forKey: key)
  }
}

extension AppModel {
  func saveViewerArrangements(replacing old: ViewerContentArrangements) {
    let arrangements = viewerDrawerStates.arrangements
    guard arrangements != old else { return }
    ViewerArrangementPreferences.save(arrangements)
  }
}
