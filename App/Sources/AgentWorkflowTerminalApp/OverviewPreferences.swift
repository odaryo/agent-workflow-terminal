import Foundation

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

  static func storedValue(
    _ storedValue: String, settingCollapsed collapsed: Bool, for project: String
  ) -> String? {
    var projects = collapsedProjects(storedValue: storedValue)
    if collapsed {
      projects.insert(project)
    } else {
      projects.remove(project)
    }
    return Self.storedValue(for: projects)
  }
}

enum OverviewSidebarPreferences {
  static let isOpenKey = "overview.sidebar.isOpen"
  static let widthKey = "overview.sidebar.width"
  static let defaultIsOpen = true
  static let defaultWidth: Double = 300
  static let widthRange: ClosedRange<Double> = 160...480
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
