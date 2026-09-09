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
  private let focusRequest: TerminalFocusRequest?
  private let keyboardParticipation: TerminalKeyboardParticipation
  private let stateChanged: ((TerminalRendererState) -> Void)?

  /// `focusRequest` はキーボードフォーカスを取り直す要求。`nil` は「この端末は今画面に
  /// 出ていない」を意味し、first responder を取りに行かない。SwiftUI の `opacity` /
  /// `allowsHitTesting` は AppKit の first responder を動かさないので、切り替える側が
  /// 明示的に渡す必要がある (Issue #233)。取ってよいかどうかは表示の有無とは別の値
  /// (`isTerminalAllowed`) が持つ (Issue #278)。
  ///
  /// `stateChanged` は surface の状態が変わったときに呼ばれる。**呼び出しは常に非同期**で、
  /// この view の更新が終わった後の main queue で届く (`GhosttySurfaceView.notifyStateChange`
  /// にその理由がある)。`.exited` は端末内のプロセスだけが終わった状態であり、surface は
  /// 生きている (`TerminalRendererState` 参照) ので、受け側は覆う判断だけをする。
  ///
  /// - Important: `stateChanged` は**状態の全列ではない**。1回の呼び出しの中で状態が続けて
  ///   進むと、途中の状態は通知されずに最後の1つだけが届く (`GhosttySurfaceView.send`)。
  ///   例えば `restart()` から surface の生成が**同期に成功した**場合、`.awaitingSurface` は
  ///   一度も届かない (生成が同期に成功しなかった場合は届く)。落ちない・重複しない・順序が
  ///   狂わないのは落ち着いた先の状態についてであり、途中の状態を数えてはならない。
  ///
  /// Why not `configurationFileURL` に既定値: 書き忘れてもコンパイルが通ると、2つ目の
  /// 呼び出し側が `nil` を渡す形になり、`GhosttyRuntime` の初期化が
  /// `configurationFileChanged` で失敗する。それは `makeNSView` の `catch` が NSLog へ
  /// 流すだけなので、画面には**何も出ない端末**が残る (Issue #236)。
  public init(
    command: [String],
    workingDirectory: String? = nil,
    configurationFileURL: URL?,
    focusRequest: TerminalFocusRequest? = nil,
    keyboardParticipation: TerminalKeyboardParticipation = .normal,
    stateChanged: ((TerminalRendererState) -> Void)? = nil
  ) {
    configuration = TerminalRendererConfiguration(
      command: command,
      workingDirectory: workingDirectory,
      configurationFileURL: configurationFileURL
    )
    self.focusRequest = focusRequest
    self.keyboardParticipation = keyboardParticipation
    self.stateChanged = stateChanged
  }

  public func makeNSView(context: Context) -> GhosttySurfaceView {
    let view = GhosttySurfaceView()
    // Why start より前: surface は window へ装着された時点で作られ、その中で first responder を
    // 取るかどうかをこの値で決める。最初の updateNSView はそれより後に来る。
    view.applyFocusRequest(focusRequest, participation: keyboardParticipation)
    view.stateChanged = stateChanged
    do {
      try view.start(configuration: configuration)
    } catch {
      NSLog("[app] libghostty の初期化に失敗: \(error.localizedDescription)")
    }
    return view
  }

  public func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
    nsView.applyFocusRequest(focusRequest, participation: keyboardParticipation)
    // Why 毎回入れ替える: closure は body のたびに作り直され、そのたびに違うものになる。
    // 最初のものを持ち続けると、受け側が後から変えた値 (この view の場合は世代番号) が
    // 通知へ反映されない。**世代をまたぐ誤配送を防いでいるのはこの入れ替えではなく、
    // 呼び出し側が付ける `.id(世代)` と、closure が世代番号を値で捕まえていること**である。
    nsView.stateChanged = stateChanged
  }

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
      // Why not 第2引数を読む: 閉じる判断をしないので、確認ダイアログを出すかどうかの分岐が
      // 要らない (GhosttySurfaceView.handleCloseRequest)。apprt 層の呼称は process_alive だが、
      // 実体は App/vendor/ghostty/src/Surface.zig:828 が渡す needsConfirmQuit() であり、
      // プロセスの生存そのものではない。
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

/// - Precondition: `ghostty_init` が済んでいること。`ghostty_config_new` は libghostty の
///   グローバル allocator を使う (`src/config/CApi.zig`)。
/// - Important: `configurationFileURL` に無いパスを渡してはならない。存在判定は
///   `TerminalConfigurationFile.resolve` が済ませている (設計書 §21.6)。
///   ghostty 本体の default files (`ghostty_config_load_default_files`) は**呼ばない**。
///   libghostty の bundle id はコンパイル時定数 `com.mitchellh.ghostty` なので、
///   default files は本物の Ghostty.app 向けの設定を読み込むことになる。
///
/// Why not `GhosttyRuntime` の private method: この手順そのものをテストが叩くため
/// (Issue #236)。テスト側に同じ手順を書き直すと、本番経路が腐っても緑のままになる。
@MainActor
func makeGhosttyConfiguration(configurationFileURL: URL?) throws -> ghostty_config_t {
  guard let config = ghostty_config_new() else {
    throw GhosttyRendererError.configurationCreationFailed
  }
  if let configurationFileURL {
    configurationFileURL.path.withCString { path in
      ghostty_config_load_file(config, path)
    }
  }
  ghostty_config_finalize(config)
  logGhosttyConfigurationDiagnostics(from: config)
  return config
}

private func logGhosttyConfigurationDiagnostics(from config: ghostty_config_t) {
  let count = ghostty_config_diagnostics_count(config)
  for index in 0..<count {
    let diagnostic = ghostty_config_get_diagnostic(config, index)
    if let message = diagnostic.message {
      NSLog("[app] ghostty config: \(String(cString: message))")
    }
  }
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
    let newConfig = try makeGhosttyConfiguration(configurationFileURL: configurationFileURL)
    config = newConfig

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
  /// 表示中のタブで、かつ Drawer のテキスト入力がキーボードを主張していないときだけ true。
  /// false の間は自分から first responder を取らない。surface の (再) 生成の経路も
  /// `applyFocusRequest` の経路も、この同じ述語だけを読む (Issue #278)。
  private var wantsKeyboardFocus = false
  private var appliedFocusRequest: Int?
  /// フォーカス移譲だけに使われたクリックの mouseUp を握り潰すための印。
  var suppressesNextLeftMouseUp = false
  var trackingAreaReference: NSTrackingArea?
  let markedTextStorage = NSMutableAttributedString()
  var textAccumulator: [String]?
  private var contentScale = 1.0
  private var lifecycle = TerminalSurfaceLifecycle()
  private var retryWorkItem: DispatchWorkItem?
  /// 状態が変わったときの通知先。SwiftUI 側の生成のたびに入れ替わる。
  var stateChanged: ((TerminalRendererState) -> Void)?
  /// 最後に通知した状態。`lifecycle` の初期値と揃えておく。
  private var notifiedState = TerminalRendererState.notStarted

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
    send(.start)
  }

  public func restart() {
    send(.restartRequested)
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
    send(.shutdown)
    GhosttySurfaceRegistry.shared.unregister(self)
  }

  override public func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    environmentMayHaveChanged()
  }

  func environmentMayHaveChanged() {
    send(.environmentMayHaveChanged)
  }

  func pollProcessExit() {
    guard lifecycle.state == .running, let surface,
      ghostty_surface_process_exited(surface)
    else { return }
    send(.processExited)
  }

  func handleCloseRequest() {
    // Why 呼ぶだけ: close 要求はプロセス終了の早期の手がかりであり、tick を待たずに `.exited`
    // へ移せる。
    pollProcessExit()
    // Why not 閉じる: 閉じるかどうかは上位レイヤの判断 (Issue #23 のユーザー決定)。設計書は
    // §21.5 で「作り直すか」だけを確定させており、閉じる条件は §25 で未確定のまま残る。
    // Why not 状態で分岐: close 要求の userdata は view であって surface ではなく、どの世代宛て
    // かを照合できない。状態で分岐すると、旧世代宛ての要求が restart() 後に drain されたときに
    // 新しい window を閉じてしまう。
    // 無視しても libghostty 側は壊れない — App/vendor/ghostty/src/apprt/embedded.zig:639 の
    // close() は callback を呼ぶだけで surface を解放しない (解放は同 :254 の closeSurface)。
    // ユーザーが閉じる経路は塞がらない: `.exited` でも window.performClose(nil) と
    // NSApp.terminate(nil) は機能する (実測)。タブを閉じる操作と、案内文 "Press any key to
    // close the terminal." との食い違いは Issue #25 のタブ UI が引き取る。
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

  /// 要求と参加可否は同じ呼び出しで渡す。2つの setter に分けると適用順に依存し、順が
  /// 入れ替わった側が「取りに行ってから明け渡す」あるいはその逆を撃つ。
  func applyFocusRequest(
    _ request: TerminalFocusRequest?,
    participation: TerminalKeyboardParticipation
  ) {
    wantsKeyboardFocus = request?.isTerminalAllowed == true && participation == .normal
    // 表示中のタブ (`request != nil`) が受け取れないときは、キーボードを端末から外す。
    // Why not `isTerminalAllowed` も条件にする: それは「テキスト入力が主張しているなら
    // first responder は端末ではない」という、**どこにも保証の無い不変条件**に頼ることに
    // なる。Issue #278 が確立したのは逆向きの乖離 (AppKit 側の grab は SwiftUI の
    // `@FocusState` を見ない) が起こりうるという事実であり、乖離した瞬間に Issue #234 の
    // 誤送信が無音で戻る。テキスト入力から奪わないことは
    // `withdrawKeyboardFromTerminals` の `is GhosttySurfaceView` が構造的に保証するので、
    // ここを緩めても過剰発火は増えない。
    if participation == .withdrawn, request != nil {
      withdrawKeyboardFromTerminals()
    }
    guard let request else {
      // Why not 覚えたままにする: 覚えたままだと、同じ要求番号のまま選び直されたタブが
      // first responder を取り直せない。
      appliedFocusRequest = nil
      return
    }
    // Why not 適用済みを忘れる: 忘れると主張が解けた瞬間に、主張より前の古い要求で
    // first responder を奪い返す。要求は保留したまま、主張が解けた時点で最新の1つだけが
    // 下の比較を通る (Issue #278 の規則 2・3)。
    guard request.isTerminalAllowed, participation == .normal else { return }
    guard request.token != appliedFocusRequest else { return }
    appliedFocusRequest = request.token
    // window が無い間 (装着前) は記録だけしておき、surface 生成時に取る。
    window?.makeFirstResponder(self)
  }

  /// Why not 自分だけ降ろす: このアプリで first responder を動かすのは「選ばれたタブが
  /// 取りに行く」経路だけで、降りる側は誰も resign しない (Issue #233 の実測。`opacity(0)` も
  /// `allowsHitTesting(false)` も first responder を動かさない)。そのため
  /// 「A が `.exited` → B へ切替 → A へ戻す」の後、**隠れた B が first responder のまま**に
  /// なる。自分が持っているときだけ降ろす実装では、A を見ながらの打鍵が B の生きた
  /// session へ入る経路 (Issue #234 の Critical) が残る。
  ///
  /// Why not `makeFirstResponder` の相手を名指しする: 覆いを出す SwiftUI 側の view を
  /// AppKit の側から指せない。`nil` は window 自身を first responder にするので、打鍵は
  /// どの端末へも入らなくなる。
  private func withdrawKeyboardFromTerminals() {
    guard let window, window.firstResponder is GhosttySurfaceView else { return }
    // Why not 戻り値を見る: 降りる相手は上の guard により必ず `GhosttySurfaceView` で、その
    // `resignFirstResponder` は `super` の答えをそのまま返す (拒否する分岐を持たない)。
    window.makeFirstResponder(nil)
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

  /// 状態機械への入口はここ1つだけにする。個々の呼び出し側で通知を足して回ると、後から
  /// 増えた経路で通知が抜ける。
  ///
  /// - Note: 通知の判定を `perform` の**後**に置くのは、`createSurface` がこの関数を再入して
  ///   `.creationSucceeded` を送るためである。再入側が先に最新の状態を通知して
  ///   `notifiedState` を進めるので、戻ってきた外側は差が無くなり、古い状態で上書きしない。
  /// - Important: **その結果、途中の状態は通知されない。** 1回の `send` で状態が2つ進むと、
  ///   届くのは最後の1つだけである。`restart()` の経路で `createSurface` が**同期に成功した**
  ///   ときは (`.awaitingSurface` → 再入で `.running`)、`.awaitingSurface` が一度も通知
  ///   されない。同期に成功しなかったとき — window へ未装着で `createSurface` が何もせずに
  ///   戻る場合や、`ghostty_surface_new` が失敗して `.creationFailed` から再試行待ちになる
  ///   場合 — は `.awaitingSurface` のまま通知される。通知は状態の全列ではなく、落ち着いた
  ///   先を報せるものだと考えること。
  private func send(_ event: TerminalSurfaceLifecycleEvent) {
    perform(lifecycle.handle(event))
    notifyStateChange()
  }

  private func notifyStateChange() {
    guard lifecycle.state != notifiedState else { return }
    notifiedState = lifecycle.state
    let state = lifecycle.state
    // Why 非同期: この経路は SwiftUI の view 更新の最中にも走る (`makeNSView` → `start()`)。
    // 同期に呼ぶと受け側の `@State` を view 更新中に書き換えることになり、SwiftUI は未定義
    // 動作として扱う。main queue は順序を保つので、状態の順序はこの hop で入れ替わらない。
    // Why not `.exited` だけ通知する: 経路を状態で絞ると、絞った先の状態が要る日に同じ
    // 未定義動作を再び踏む。危険なのは同期呼び出しであって、通知する状態の種類ではない。
    DispatchQueue.main.async { [weak self] in
      // Why assumeIsolated: DispatchQueue の closure は MainActor 隔離とみなされない。
      MainActor.assumeIsolated {
        // Why 届いた時点で読む: 通知先は body のたびに入れ替わるため。**これは誤配送を防ぐ
        // 仕掛けではない** — 世代をまたいで届かないことを保証しているのは、呼び出し側が
        // 端末に付ける `.id(世代)` である。`.id` を外すと同じ NSView が使い回され、世代 N の
        // `.exited` が世代 N+1 の closure へ届いて、作り直したばかりの端末を覆う。
        self?.stateChanged?(state)
      }
    }
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
        self.send(.retryDeadlineReached(token: token))
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
    // Why creationSucceeded を返す: 到達した時点で surface は実在するので、状態機械を現実へ
    // 合わせて自己修復させる。何も返さないと release ビルド (assertionFailure が消える) で
    // 状態が `.awaitingSurface` のまま保留中の再試行も無く、以後の environmentMayHaveChanged が
    // 何度来てもこのガードへ戻るだけで抜けられなくなる。
    guard surface == nil else {
      assertionFailure("surface が生きているうちに createSurface が呼ばれた")
      NSLog("[app] surface が生きているうちに createSurface が呼ばれました")
      send(.creationSucceeded)
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
      send(.creationFailed)
      return
    }

    updateContentScaleFromWindow()
    updateSurfaceSize()
    updateDisplayID()
    // Why not 常に取る: 背面のタブの surface が (再) 生成されるたびに first responder を
    // 奪うと、表示中のタブへの打鍵が背面の端末へ入る (Issue #233 と同じ誤送信)。表示中でも
    // Drawer のテキスト入力が主張している間は取らない — この経路は AppKit 側で走り SwiftUI の
    // `@FocusState` を見ないので、入力側だけで表しても止まらない (Issue #278)。
    if wantsKeyboardFocus { window?.makeFirstResponder(self) }
    ghostty_surface_set_focus(
      surface, window?.isKeyWindow == true && window?.firstResponder === self)
    send(.creationSucceeded)
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
