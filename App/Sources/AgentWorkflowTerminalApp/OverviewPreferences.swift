import Foundation

/// 設計書 §13「表示形態の選択」。キーは UserDefaults に置く。
enum OverviewPresentation: String, CaseIterable {
  case window
  case sidebar

  static let key = "overview.presentation"
  static let `default` = Self.window

  /// 不明な値や未設定は既定のウィンドウ表示として読む。
  init(storedValue: String?) {
    self = storedValue.flatMap(Self.init(rawValue:)) ?? .default
  }

  static func current(_ defaults: UserDefaults = .standard) -> Self {
    Self(storedValue: defaults.string(forKey: key))
  }

  var settingsLabel: String {
    switch self {
    case .window: "ウィンドウ"
    case .sidebar: "サイドバー"
    }
  }
}

enum OverviewProjectPreferences {
  static let collapsedProjectsKey = "overview.collapsedProjects"

  static func collapsedProjects(storedValue: String) -> Set<String> {
    let data = Data(storedValue.utf8)
    return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
  }

  static func storedValue(for collapsedProjects: Set<String>) -> String? {
    guard let data = try? JSONEncoder().encode(collapsedProjects.sorted()) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}

enum OverviewSidebarPreferences {
  static let isOpenKey = "overview.sidebar.isOpen"
  static let widthKey = "overview.sidebar.width"
  static let defaultIsOpen = true
  static let defaultWidth: Double = 300
  static let widthRange: ClosedRange<Double> = 240...480
  /// `DrawerResizeHandle` の当たり判定の幅。サイドバーと端末の間に1本置く。
  static let handleWidth = Double(ViewerDrawerMetrics.resizeHandleWidth)

  /// 非有限値は既定の幅へ戻す。`clamp` だけでは NaN が通る。
  static func clamped(_ width: Double) -> Double {
    guard width.isFinite else { return defaultWidth }
    return min(max(width, widthRange.lowerBound), widthRange.upperBound)
  }

  /// 開いている間にメイン window の最小幅へ足す分 (つまみを含む)。
  static func occupiedWidth(isVisible: Bool, width: Double) -> CGFloat {
    isVisible ? CGFloat(clamped(width) + handleWidth) : 0
  }
}
