import TerminalCore

struct ViewerDrawerStates {
  var arrangements: ViewerContentArrangements
  private var contents: [WorktreeIdentity: ViewerContent] = [:]

  init(arrangements: ViewerContentArrangements = .defaults) {
    self.arrangements = arrangements
  }

  func layout(for identity: WorktreeIdentity?) -> ViewerDrawerLayout {
    var layout = ViewerDrawerLayout(arrangements: arrangements)
    if let identity, let content = contents[identity] {
      layout.open(content)
    }
    return layout
  }

  mutating func update(_ layout: ViewerDrawerLayout, for identity: WorktreeIdentity?) {
    arrangements = layout.arrangements
    if let identity { contents[identity] = layout.content }
  }

  mutating func retainContents(for identities: Set<WorktreeIdentity>) {
    contents = contents.filter { identities.contains($0.key) }
  }
}

extension AppModel {
  var viewerDrawerLayout: ViewerDrawerLayout {
    get { viewerDrawerStates.layout(for: selectedIdentity) }
    set {
      let identity = selectedIdentity
      guard
        identity != nil || newValue.arrangements != viewerDrawerStates.arrangements
      else { return }
      viewerDrawerStates.update(newValue, for: identity)
    }
  }

  func reloadViewerArrangements() {
    let arrangements = ViewerArrangementPreferences.load()
    guard arrangements != viewerDrawerStates.arrangements else { return }
    viewerDrawerStates.arrangements = arrangements
  }
}
