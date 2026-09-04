import AppKit
import GhosttyKit
import QuartzCore
import SwiftUI
import TerminalCore

// Why not 分割: runtime callback と view の userdata 復元を同じファイルに置き、
// C 境界から @MainActor へ移る経路を一箇所で追跡できるようにする。
// swiftlint:disable file_length

public struct GhosttyTerminalView: NSViewRepresentable {
  private let configuration: TerminalRendererConfiguration

  public init(
    command: [String],
    workingDirectory: String? = nil,
    configurationFileURL: URL? = nil
  ) {
    configuration = TerminalRendererConfiguration(
      command: command,
      workingDirectory: workingDirectory,
      configurationFileURL: configurationFileURL
    )
  }

  public func makeNSView(context: Context) -> GhosttySurfaceView {
    let view = GhosttySurfaceView()
    do {
      try view.start(configuration: configuration)
    } catch {
      NSLog("[app] libghostty の初期化に失敗: \(error.localizedDescription)")
    }
    return view
  }

  public func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {}

  public static func dismantleNSView(_ nsView: GhosttySurfaceView, coordinator: ()) {
    // Why not deinit: SwiftUI は破棄前にこの main actor callback を呼ぶ契約であり、
    // GhosttySurfaceView はこの representable だけが生成できる。
    nsView.shutdown()
  }
}

@MainActor
public func setGhosttyApplicationFocus(_ focused: Bool) {
  GhosttyRuntime.shared.setFocus(focused)
}

// Why not @MainActor: C callback は renderer / IO を含む任意のスレッドから同期に呼ばれる。
// actor 隔離を継承しない場所で callback table を生成し、副作用だけを main queue へ移す。
// swiftlint:disable:next cyclomatic_complexity function_body_length
private func makeGhosttyRuntimeConfiguration() -> ghostty_runtime_config_s {
  ghostty_runtime_config_s(
    userdata: nil,
    supports_selection_clipboard: false,
    wakeup_cb: { _ in
      // Why main queue へ移す: wakeup は libghostty の IO スレッドから届く
      // (Spikes/gate1/README.md §5.2)。
      DispatchQueue.main.async {
        MainActor.assumeIsolated { GhosttyRuntime.shared.tick() }
      }
    },
    action_cb: { _, target, action in
      let accepted: Bool
      let pendingAction: PendingGhosttyAction?
      switch action.tag {
      case GHOSTTY_ACTION_SET_TITLE:
        accepted = true
        if target.tag == GHOSTTY_TARGET_SURFACE,
          let surface = target.target.surface,
          let title = action.action.set_title.title
        {
          pendingAction = .setTitle(
            surfaceAddress: UInt(bitPattern: surface),
            title: String(cString: title)
          )
        } else {
          pendingAction = nil
        }
      case GHOSTTY_ACTION_MOUSE_OVER_LINK:
        accepted = true
        pendingAction = .setLinkCursor(action.action.mouse_over_link.len > 0)
      case GHOSTTY_ACTION_OPEN_URL:
        accepted = true
        let value = action.action.open_url
        if let bytes = value.url, value.len > 0 {
          pendingAction = .openURL(
            String(
              decoding: UnsafeRawBufferPointer(start: bytes, count: Int(value.len)),
              as: UTF8.self
            )
          )
        } else {
          pendingAction = nil
        }
      case GHOSTTY_ACTION_NEW_SPLIT, GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
        GHOSTTY_ACTION_GOTO_SPLIT, GHOSTTY_ACTION_RESIZE_SPLIT,
        GHOSTTY_ACTION_EQUALIZE_SPLITS, GHOSTTY_ACTION_NEW_TAB,
        GHOSTTY_ACTION_NEW_WINDOW:
        // Why not handle: pane / tab / window 操作は tmux の責務である (設計書 §4.1)。
        accepted = false
        pendingAction = nil
      case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        // Why not accept: 握り潰すと libghostty 自身の "Process exited." 表示が消える。
        // 出典: App/vendor/ghostty/macos/Sources/Ghostty/Ghostty.App.swift:664。
        accepted = false
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
          pendingAction = .childExited(surfaceAddress: UInt(bitPattern: surface))
        } else {
          pendingAction = nil
        }
      case GHOSTTY_ACTION_MOUSE_SHAPE, GHOSTTY_ACTION_MOUSE_VISIBILITY,
        GHOSTTY_ACTION_PWD, GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_RENDERER_HEALTH,
        GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_CONFIG_CHANGE,
        GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_KEY_SEQUENCE,
        GHOSTTY_ACTION_SECURE_INPUT:
        accepted = true
        pendingAction = nil
      default:
        accepted = false
        pendingAction = nil
      }
      if let pendingAction {
        // Why main queue へ移す: action は renderer スレッドからも届く。
        DispatchQueue.main.async {
          MainActor.assumeIsolated { GhosttyRuntime.handleAction(pendingAction) }
        }
      }
      return accepted
    },
    read_clipboard_cb: { userdata, location, state in
      guard location == GHOSTTY_CLIPBOARD_STANDARD,
        let userdata,
        let state
      else { return false }
      // Why callback 内で復元: takeUnretainedValue 自体は retain しないが、直後の main queue
      // closure が view を capture して強参照を持つため、実行までの生存を保証できる。
      let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
      let stateAddress = UInt(bitPattern: state)
      // Why main queue へ移す: callback のスレッドは保証されず、NSPasteboard は main actor 上で扱う。
      // このため空 clipboard でも true を返して空文字列で完了し、上流の performable keybind を
      // terminal へ透過する経路は失われる。この既知差分は Issue #109 で扱う。
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          GhosttyRuntime.readClipboard(
            view: view,
            stateAddress: stateAddress
          )
        }
      }
      return true
    },
    confirm_read_clipboard_cb: { userdata, string, state, request in
      guard let userdata, let string, let state else { return }
      // Why callback 内で復元: main queue closure の capture により、実行まで強参照を保持する。
      let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
      let confirmation = ClipboardConfirmation(
        view: view,
        stateAddress: UInt(bitPattern: state),
        value: String(cString: string),
        request: request.rawValue
      )
      // Why main queue へ移す: confirm callback の呼び出しスレッドは保証されない。
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          GhosttyRuntime.confirmClipboardRead(confirmation)
        }
      }
    },
    write_clipboard_cb: { userdata, location, content, count, confirm in
      guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, count > 0 else { return }
      var value: String?
      for index in 0..<count {
        let item = content[index]
        guard let mime = item.mime, let data = item.data,
          String(cString: mime) == "text/plain"
        else { continue }
        value = String(cString: data)
        break
      }
      guard let value else { return }
      let view = userdata.map {
        Unmanaged<GhosttySurfaceView>.fromOpaque($0).takeUnretainedValue()
      }
      // Why main queue へ移す: write callback の呼び出しスレッドは保証されない。
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          if confirm, let view {
            GhosttyRuntime.confirmClipboardWrite(value, view: view)
          } else if !confirm {
            GhosttyRuntime.writeClipboard(value)
          }
        }
      }
    },
    close_surface_cb: { userdata, _ in
      guard let userdata else { return }
      // Why callback 内で復元: main queue closure の capture により、実行まで強参照を保持する。
      let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
      // Why main queue へ移す: close callback の呼び出しスレッドは保証されない。
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          view.handleCloseRequest()
        }
      }
    }
  )
}

@MainActor
private final class GhosttyRuntime {
  static let shared = GhosttyRuntime()

  private(set) var app: ghostty_app_t?
  // Why not local variable: libghostty app が参照する config の寿命を process 全体で保持する。
  private var config: ghostty_config_t?
  private var initializationAttempted = false
  private var configurationFileURL: URL?
  // Why not discard: NotificationCenter は token の解放時に observer を解除する。
  private var keyboardObserver: (any NSObjectProtocol)?

  private init() {}

  func initialize(configurationFileURL: URL?) throws {
    guard !initializationAttempted else {
      guard self.configurationFileURL == configurationFileURL else {
        throw GhosttyRendererError.configurationFileChanged
      }
      if app == nil { throw GhosttyRendererError.runtimeUnavailable }
      return
    }
    initializationAttempted = true
    self.configurationFileURL = configurationFileURL

    guard let resourcePath = Bundle.main.resourcePath else {
      throw GhosttyRendererError.resourcesUnavailable
    }
    let resourcesDirectory = URL(fileURLWithPath: resourcePath)
      .appendingPathComponent("ghostty", isDirectory: true).path
    setenv("GHOSTTY_RESOURCES_DIR", resourcesDirectory, 1)

    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
      throw GhosttyRendererError.initializationFailed
    }
    guard let newConfig = ghostty_config_new() else {
      throw GhosttyRendererError.configurationCreationFailed
    }
    config = newConfig

    if let configurationFileURL {
      configurationFileURL.path.withCString { path in
        ghostty_config_load_file(newConfig, path)
      }
    }
    ghostty_config_finalize(newConfig)
    logDiagnostics(from: newConfig)

    var runtimeConfiguration = makeGhosttyRuntimeConfiguration()

    guard let newApp = ghostty_app_new(&runtimeConfiguration, newConfig) else {
      throw GhosttyRendererError.applicationCreationFailed
    }
    app = newApp
    ghostty_app_set_focus(newApp, NSApp.isActive)
    keyboardObserver = NotificationCenter.default.addObserver(
      forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      // Why main queue へ移す: OperationQueue.main は main dispatch queue の context を保証しない。
      DispatchQueue.main.async {
        MainActor.assumeIsolated { Self.shared.keyboardChanged() }
      }
    }
  }

  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
    // Why ここで poll: libghostty v1.3.1 はプロセス終了を surface の状態としてしか公開せず、
    // GHOSTTY_ACTION_SHOW_CHILD_EXITED は表示用の副次的な通知でしかない。
    GhosttySurfaceRegistry.shared.pollProcessExit()
  }

  func setFocus(_ focused: Bool) {
    guard let app else { return }
    ghostty_app_set_focus(app, focused)
  }

  private func keyboardChanged() {
    guard let app else { return }
    ghostty_app_keyboard_changed(app)
  }

  private func logDiagnostics(from config: ghostty_config_t) {
    let count = ghostty_config_diagnostics_count(config)
    for index in 0..<count {
      let diagnostic = ghostty_config_get_diagnostic(config, index)
      if let message = diagnostic.message {
        NSLog("[app] ghostty config: \(String(cString: message))")
      }
    }
  }

  fileprivate static func readClipboard(
    view: GhosttySurfaceView,
    stateAddress: UInt
  ) {
    let value = NSPasteboard.general.string(forType: .string) ?? ""
    completeClipboardRequest(
      view: view,
      stateAddress: stateAddress,
      value: value,
      confirmed: false
    )
  }

  fileprivate static func confirmClipboardRead(_ confirmation: ClipboardConfirmation) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    if confirmation.request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ.rawValue {
      alert.messageText = "クリップボードの読み取りを許可しますか？"
      alert.informativeText = "端末内のプログラムがクリップボードの内容を要求しています。"
    } else {
      alert.messageText = "複数行または危険な内容をペーストしますか？"
      alert.informativeText = "内容を確認し、信頼できる場合だけ許可してください。"
    }
    alert.addButton(withTitle: "許可")
    alert.addButton(withTitle: "キャンセル")

    let complete: @MainActor (NSApplication.ModalResponse) -> Void = { response in
      completeClipboardRequest(
        view: confirmation.view,
        stateAddress: confirmation.stateAddress,
        value: response == .alertFirstButtonReturn ? confirmation.value : "",
        confirmed: true
      )
    }
    if let window = confirmation.view.window {
      alert.beginSheetModal(for: window, completionHandler: complete)
    } else {
      complete(alert.runModal())
    }
  }

  private static func completeClipboardRequest(
    view: GhosttySurfaceView,
    stateAddress: UInt,
    value: String,
    confirmed: Bool
  ) {
    // Why not state を手動解放: state は libghostty の allocator 所有で公開解放 API がない。
    // teardown と非同期完了が競合すると数十 byte が残り得る既知差分を Issue #109 で扱う。
    guard let surface = view.surface,
      let state = UnsafeMutableRawPointer(bitPattern: stateAddress)
    else { return }
    value.withCString { pointer in
      ghostty_surface_complete_clipboard_request(surface, pointer, state, confirmed)
    }
  }

  fileprivate static func writeClipboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  fileprivate static func confirmClipboardWrite(_ value: String, view: GhosttySurfaceView) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "クリップボードへの書き込みを許可しますか？"
    alert.informativeText = "端末内のプログラムがクリップボードの上書きを要求しています。"
    alert.addButton(withTitle: "許可")
    alert.addButton(withTitle: "キャンセル")

    let complete: @MainActor (NSApplication.ModalResponse) -> Void = { response in
      if response == .alertFirstButtonReturn { writeClipboard(value) }
    }
    if let window = view.window {
      alert.beginSheetModal(for: window, completionHandler: complete)
    } else {
      complete(alert.runModal())
    }
  }

  fileprivate static func handleAction(_ action: PendingGhosttyAction) {
    switch action {
    case .setTitle(let surfaceAddress, let title):
      GhosttySurfaceRegistry.shared.view(forSurfaceAddress: surfaceAddress)?.window?.title = title
    case .childExited(let surfaceAddress):
      // Why not action を信用する: action は表示用の通知であり、届いた時点の surface の状態を
      // 保証しない。受け側で ghostty_surface_process_exited を読み直す。
      GhosttySurfaceRegistry.shared.view(forSurfaceAddress: surfaceAddress)?.pollProcessExit()
    case .setLinkCursor(let isLink):
      (isLink ? NSCursor.pointingHand : NSCursor.arrow).set()
    case .openURL(let value):
      guard let url = URL(string: value) else { return }
      NSWorkspace.shared.open(url)
    }
  }
}

private enum PendingGhosttyAction: Sendable {
  case setTitle(surfaceAddress: UInt, title: String)
  case childExited(surfaceAddress: UInt)
  case setLinkCursor(Bool)
  case openURL(String)
}

private struct ClipboardConfirmation: Sendable {
  let view: GhosttySurfaceView
  let stateAddress: UInt
  let value: String
  let request: UInt32
}

private enum GhosttyRendererError: LocalizedError {
  case emptyCommand
  case commandContainsNull
  case resourcesUnavailable
  case initializationFailed
  case configurationCreationFailed
  case applicationCreationFailed
  case runtimeUnavailable
  case configurationFileChanged

  var errorDescription: String? {
    switch self {
    case .emptyCommand: "command に1つ以上の argv 要素が必要です"
    case .commandContainsNull: "command の argv 要素に NUL を含められません"
    case .resourcesUnavailable: "アプリバンドルの Resources を解決できません"
    case .initializationFailed: "ghostty_init が失敗しました"
    case .configurationCreationFailed: "ghostty_config_new が失敗しました"
    case .applicationCreationFailed: "ghostty_app_new が失敗しました"
    case .runtimeUnavailable: "libghostty runtime を利用できません"
    case .configurationFileChanged:
      "libghostty runtime の初期化後に別の設定ファイルへ変更できません"
    }
  }
}

@MainActor
public final class GhosttySurfaceView: NSView, TerminalRenderer {
  private(set) var surface: ghostty_surface_t?

  public private(set) var size = TerminalSize(columns: 0, rows: 0)
  public var state: TerminalRendererState { lifecycle.state }
  public var imePoint: TerminalIMEPoint? {
    imeRectangle.map { TerminalIMEPoint(x: $0.origin.x, y: $0.origin.y) }
  }

  private var configuration: TerminalRendererConfiguration?
  var trackingAreaReference: NSTrackingArea?
  let markedTextStorage = NSMutableAttributedString()
  var textAccumulator: [String]?
  private var contentScale = 1.0
  private var lifecycle = TerminalSurfaceLifecycle()
  private var retryWorkItem: DispatchWorkItem?

  init() {
    super.init(frame: .zero)
    focusRingType = .none
  }

  // Why not deinit: @MainActor class の deinit から isolated な surface へ安全に触れられない。
  // initializer を module 内に閉じ、SwiftUI の dismantleNSView 契約で破棄前に shutdown する。

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    nil
  }

  public func start(configuration: TerminalRendererConfiguration) throws {
    guard !configuration.command.isEmpty else {
      throw GhosttyRendererError.emptyCommand
    }
    guard configuration.command.allSatisfy({ !$0.contains("\0") }) else {
      throw GhosttyRendererError.commandContainsNull
    }
    self.configuration = configuration
    try GhosttyRuntime.shared.initialize(
      configurationFileURL: configuration.configurationFileURL
    )
    GhosttySurfaceRegistry.shared.register(self)
    perform(lifecycle.handle(.start))
  }

  public func restart() {
    perform(lifecycle.handle(.restartRequested))
  }

  public func resize(to size: TerminalPixelSize) {
    guard let surface, size.width > 0, size.height > 0 else { return }
    ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    updateObservedSize()
  }

  public func setContentScale(_ scale: Double) {
    guard scale > 0 else { return }
    contentScale = scale
    guard let surface else { return }
    ghostty_surface_set_content_scale(surface, scale, scale)
    updateObservedSize()
  }

  public func shutdown() {
    perform(lifecycle.handle(.shutdown))
    GhosttySurfaceRegistry.shared.unregister(self)
  }

  override public func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    environmentMayHaveChanged()
  }

  func environmentMayHaveChanged() {
    perform(lifecycle.handle(.environmentMayHaveChanged))
  }

  func pollProcessExit() {
    guard lifecycle.state == .running, let surface,
      ghostty_surface_process_exited(surface)
    else { return }
    perform(lifecycle.handle(.processExited))
  }

  /// - Important: 先に `pollProcessExit` を呼ぶ。tick より先にキーが届くと状態が `.running` の
  ///   ままで、閉じるかどうかの判定が競合するため。
  func handleCloseRequest() {
    pollProcessExit()
    // Why not 閉じる: プロセス終了後に libghostty が出す "Press any key to close the terminal."
    // に従うと close 要求が届くが、閉じるかどうかも作り直すかどうかも上位レイヤの判断であり
    // (TerminalRenderer の Note)、ここで window を閉じると shutdown が走って `.stopped` へ
    // 落ち、上位の restart() が永久に届かなくなる。無視しても libghostty 側は壊れない —
    // App/vendor/ghostty/src/apprt/embedded.zig:639 の close() は callback を呼ぶだけで
    // surface を解放しない (解放は同 :254 の closeSurface)。案内文と実際の挙動が食い違う
    // 既知差分は、タブ UI を持つ Issue #25 で解消する。
    guard state != .exited else { return }
    window?.performClose(nil)
  }

  override public func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateSurfaceSize()
  }

  override public func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateLayerContentScale()
    updateContentScaleFromWindow()
    updateSurfaceSize()
    updateDisplayID()
  }

  override public var acceptsFirstResponder: Bool { true }

  override public func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if let surface { ghostty_surface_set_focus(surface, true) }
    return accepted
  }

  override public func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if let surface { ghostty_surface_set_focus(surface, false) }
    return accepted
  }

  // Why 再入しても安全: createSurface は成否を同期に状態機械へ戻すため perform を再入するが、
  // 効果の列は必ず createSurface で終わるので、新しい効果が未適用の効果を追い越さない。
  private func perform(_ effects: [TerminalSurfaceLifecycleEffect]) {
    for effect in effects {
      switch effect {
      case .createSurface: createSurface()
      case .destroySurface: destroySurface()
      case .scheduleRetry(let after, let token): scheduleRetry(after: after, token: token)
      case .cancelRetry: cancelRetry()
      }
    }
  }

  private func destroySurface() {
    // Why not 残す: プリエディットと入力の蓄積は破棄する surface 宛ての未確定入力であり、
    // 持ち越すと restart() 後に別 session となった新しい surface へ送られる。
    markedTextStorage.mutableString.setString("")
    textAccumulator = nil
    guard let surface else { return }
    ghostty_surface_free(surface)
    self.surface = nil
    size = TerminalSize(columns: 0, rows: 0)
  }

  private func scheduleRetry(after delay: Duration, token: Int) {
    cancelRetry()
    // Why not Timer: Timer は default run loop mode でしか発火せず、メニュー追跡や modal 表示中に
    // 再試行が止まる。ディスプレイスリープ中の再試行は止められない (申し送り #7)。
    let workItem = DispatchWorkItem { [weak self] in
      // Why assumeIsolated: DispatchWorkItem の body は MainActor 隔離とみなされない。
      MainActor.assumeIsolated {
        guard let self else { return }
        self.retryWorkItem = nil
        self.perform(self.lifecycle.handle(.retryDeadlineReached(token: token)))
      }
    }
    retryWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds(delay), execute: workItem)
  }

  private func cancelRetry() {
    retryWorkItem?.cancel()
    retryWorkItem = nil
  }

  private static func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

  private func createSurface() {
    // Why not 状態機械だけに任せる: 通常経路では到達しない防御。ここを抜けて上書きすると
    // 旧 surface のポインタを失い、その子プロセスがアプリ終了まで孤児として残る。
    // 状態機械へ成否を返さないのは、これが遷移の結果ではなく不変条件違反だから。
    guard surface == nil else {
      assertionFailure("surface が生きているうちに createSurface が呼ばれた")
      NSLog("[app] surface が生きているうちに createSurface が呼ばれました")
      return
    }
    // Why not creationFailed を送る: window が無いのは生成の失敗ではない。ここで失敗として
    // 扱うとバックオフが進み、装着直後の生成が無駄に遅れる。
    guard window != nil, let configuration, let app = GhosttyRuntime.shared.app else { return }

    var surfaceConfiguration = ghostty_surface_config_new()
    surfaceConfiguration.platform_tag = GHOSTTY_PLATFORM_MACOS
    surfaceConfiguration.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(
        nsview: Unmanaged.passUnretained(self).toOpaque()
      )
    )
    surfaceConfiguration.userdata = Unmanaged.passUnretained(self).toOpaque()
    surfaceConfiguration.scale_factor = Double(window?.backingScaleFactor ?? 1)
    surfaceConfiguration.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

    let command = POSIXShellCommandLine.joined(configuration.command)
    command.withCString { commandPointer in
      surfaceConfiguration.command = commandPointer
      if let workingDirectory = configuration.workingDirectory {
        workingDirectory.withCString { workingDirectoryPointer in
          surfaceConfiguration.working_directory = workingDirectoryPointer
          surface = ghostty_surface_new(app, &surfaceConfiguration)
        }
      } else {
        surface = ghostty_surface_new(app, &surfaceConfiguration)
      }
    }

    guard surface != nil else {
      NSLog("[app] ghostty_surface_new が失敗しました。画面復帰後に再試行できます")
      perform(lifecycle.handle(.creationFailed))
      return
    }

    updateContentScaleFromWindow()
    updateSurfaceSize()
    updateDisplayID()
    ghostty_surface_set_focus(surface, window?.isKeyWindow == true)
    window?.makeFirstResponder(self)
    perform(lifecycle.handle(.creationSucceeded))
  }

  private func updateContentScaleFromWindow() {
    guard let window else { return }
    setContentScale(window.backingScaleFactor)
  }

  private func updateLayerContentScale() {
    guard let window else { return }
    // Why not compositor に任せる: Retina / 非 Retina 間の移動時に libghostty 自身が解像度を
    // 更新するため、Core Animation の追加 scale を防ぐ必要がある。出典:
    // App/vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:842-865
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.contentsScale = window.backingScaleFactor
    CATransaction.commit()
  }

  private func updateSurfaceSize() {
    let backingSize = convertToBacking(bounds.size)
    resize(
      to: TerminalPixelSize(
        width: Int(backingSize.width),
        height: Int(backingSize.height)
      )
    )
  }

  private func updateObservedSize() {
    guard let surface else { return }
    let observed = ghostty_surface_size(surface)
    size = TerminalSize(columns: Int(observed.columns), rows: Int(observed.rows))
  }

  private func updateDisplayID() {
    guard let surface,
      let screen = window?.screen,
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return }
    ghostty_surface_set_display_id(surface, number.uint32Value)
  }

  private var cellSize: CGSize {
    guard let surface else { return CGSize(width: 8, height: 16) }
    let observed = ghostty_surface_size(surface)
    return CGSize(
      width: Double(observed.cell_width_px) / contentScale,
      height: Double(observed.cell_height_px) / contentScale
    )
  }

  var imeRectangle: NSRect? {
    guard let surface else { return nil }
    let fallback = cellSize
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0
    ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    // Why not expose width directly: v1.3.1 は width だけ content scale を適用しない
    // (Spikes/gate1/README.md §10.6)。
    width /= contentScale
    return NSRect(
      x: x,
      y: bounds.height - y,
      width: width,
      height: max(height, fallback.height)
    )
  }
}
