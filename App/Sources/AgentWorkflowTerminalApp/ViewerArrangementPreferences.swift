import Foundation
import TerminalCore

enum ViewerArrangementPreferences {
  static let key = "viewerDrawer.contentArrangements"

  static func restoredLayout() -> ViewerDrawerLayout {
    ViewerDrawerLayout(arrangements: load())
  }

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
  func saveViewerArrangements(replacing old: ViewerDrawerLayout) {
    guard viewerDrawerLayout.arrangements != old.arrangements else { return }
    ViewerArrangementPreferences.save(viewerDrawerLayout.arrangements)
  }
}
