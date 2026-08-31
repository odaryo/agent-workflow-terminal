//
//  GhosttyTerminalView.swift
//
//  Gate 1 PoC (M1) — libghostty 隔離レイヤ
//
//  ============================================================================
//  ここは「libghostty の C API を呼ぶ唯一のファイル」である。
//
//  設計書 §21.5「libghostty隔離」に従い、本体実装では以下の境界を想定する:
//
//      protocol TerminalRenderer {
//          associatedtype ViewType            // NSView / UIView
//          func makeSurface(command: String, workingDirectory: String?,
//                           env: [String: String]) throws -> SurfaceHandle
//          func resize(_ h: SurfaceHandle, pixelSize: CGSize, scale: CGSize)
//          func setFocus(_ h: SurfaceHandle, _ focused: Bool)
//          func sendKey(_ h: SurfaceHandle, _ event: TerminalKeyEvent)
//          func sendText(_ h: SurfaceHandle, _ text: String)
//          func setPreedit(_ h: SurfaceHandle, _ text: String?)
//          func readSelection(_ h: SurfaceHandle) -> String?
//          var  gridSize: (columns: Int, rows: Int) { get }
//          // observation: process exited / foreground pid / tty name / title / pwd
//      }
//
//  M1 の段階では protocol を切らず、「切るとしたら何が必要になるか」を
//  実際に呼んだ API から逆算できるようにコメントで印を付けてある。
//  → `// [RENDERER]` が付いた箇所が protocol に載る候補。
//
//  スパイク品質。エラー処理・リソース解放は最小限。
//  ============================================================================

import AppKit
import GhosttyKit
import SwiftUI

// MARK: - リソースディレクトリ解決

enum GhosttyResources {
    /// libghostty は release ビルドでは `GHOSTTY_RESOURCES_DIR` を最優先で見る
    /// (`src/os/resourcesdir.zig`)。ここを設定しないと terminfo (`xterm-ghostty`) が
    /// 引けず、TERM が `xterm-256color` にフォールバックして TUI 検証が歪む。
    /// PLAN.md §4.5 / R7 の必須項目。
    ///
    /// libghostty 側は `<resources_dir>/../terminfo` を TERMINFO として子プロセスへ
    /// 渡す (`src/termio/Exec.zig`)。したがってディレクトリ構成は
    ///   <root>/ghostty/     ← GHOSTTY_RESOURCES_DIR
    ///   <root>/terminfo/
    /// でなければならない。build-app.sh はこれを .app/Contents/Resources 配下に作る。
    @discardableResult
    static func configureEnvironment() -> String? {
        // 注意: このアプリを Ghostty.app のターミナルから起動すると
        // GHOSTTY_RESOURCES_DIR が既に環境変数に入っており、そのままだと
        // **本家 Ghostty.app のリソースを掴んでしまう**。PoC の検証結果が
        // 「どの libghostty のリソースを見ていたか」で揺れるため、自分の
        // バンドル内リソースを最優先にして環境変数を上書きする。
        var candidates: [String] = []
        if let resourcePath = Bundle.main.resourcePath {
            candidates.append((resourcePath as NSString).appendingPathComponent("ghostty"))
        }
        // .app にせず `swift run` で直に起動した場合のフォールバック。
        // 実行ファイルから見た vendor/ghostty/zig-out/share/ghostty を探す。
        let exeDir = (Bundle.main.executablePath as NSString?)?.deletingLastPathComponent
        if let exeDir {
            candidates.append(
                URL(fileURLWithPath: exeDir)
                    .appendingPathComponent("../../../vendor/ghostty/zig-out/share/ghostty")
                    .standardizedFileURL.path
            )
        }

        for candidate in candidates {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            setenv("GHOSTTY_RESOURCES_DIR", candidate, 1)
            return candidate
        }

        // 自前のリソースが見つからない場合のみ、継承した環境変数を使う
        if let inherited = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
           !inherited.isEmpty {
            NSLog("[spike] WARNING: 継承した GHOSTTY_RESOURCES_DIR を使用: \(inherited)")
            return inherited
        }
        return nil
    }
}

// MARK: - アプリ単位の libghostty ランタイム

/// `ghostty_app_t` は プロセスに 1 つ。surface (= 1 ターミナルビュー) は
/// この app からいくつでも作れる。本体では「1 タスクタブ = 1 surface」になる想定。
/// NOTE(Swift 6): libghostty のコールバックは C 関数ポインタであり actor 隔離を
/// 表現できない。スパイクでは `nonisolated(unsafe)` で逃がしている。本体では
/// TerminalRenderer の実装体を MainActor に固定し、コールバックは全て
/// `MainActor.assumeIsolated` 経由に揃える必要がある (Gate 1 の所見)。
final class GhosttyRuntime {
    nonisolated(unsafe) static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var resourcesDir: String?
    private(set) var initError: String?

    private init() {
        resourcesDir = GhosttyResources.configureEnvironment()

        // [RENDERER] プロセス初期化。ホスト側が最初に 1 回だけ呼ぶ。
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != 0 {
            initError = "ghostty_init failed"
            return
        }

        guard let cfg = ghostty_config_new() else {
            initError = "ghostty_config_new failed"
            return
        }

        // スパイクの再現性のため、既定ではユーザーの ~/.config/ghostty/config を
        // 読まない。読ませたい場合は TERMINAL_SPIKE_USER_CONFIG=1 で起動する。
        if ProcessInfo.processInfo.environment["TERMINAL_SPIKE_USER_CONFIG"] == "1" {
            ghostty_config_load_default_files(cfg)
        }
        ghostty_config_finalize(cfg)
        config = cfg

        // 設定診断 (config のパースエラー) を素通しにしない
        let diagCount = ghostty_config_diagnostics_count(cfg)
        for i in 0..<diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let message = diag.message {
                NSLog("[spike] ghostty config diagnostic: \(String(cString: message))")
            }
        }

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                // libghostty の IO スレッドから呼ばれる。main へ回して tick する。
                DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
            },
            action_cb: { app, target, action in
                GhosttyRuntime.handleAction(app: app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyRuntime.readClipboard(userdata, location, state)
            },
            confirm_read_clipboard_cb: { userdata, string, state, _ in
                // スパイクでは確認ダイアログを出さずそのまま通す (M2 で扱う)
                guard let string, let surface = GhosttyRuntime.surface(from: userdata) else { return }
                ghostty_surface_complete_clipboard_request(surface, string, state, true)
            },
            write_clipboard_cb: { userdata, location, content, len, _ in
                GhosttyRuntime.writeClipboard(userdata, location, content, len)
            },
            close_surface_cb: { userdata, _ in
                guard let view = GhosttyRuntime.view(from: userdata) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { view.window?.performClose(nil) }
                }
            }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            initError = "ghostty_app_new failed"
            return
        }
        self.app = app
        ghostty_app_set_focus(app, true)
    }

    /// [RENDERER] IO / タイマー処理を進める。ホストの run loop から駆動する。
    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    // MARK: userdata <-> view

    fileprivate static func view(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceNSView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
    }

    fileprivate static func surface(from userdata: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        view(from: userdata)?.surface
    }

    // MARK: callbacks

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let surface = surface(from: userdata),
              let str = NSPasteboard.general.string(forType: .string) else { return false }
        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
        }
        return true
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ content: UnsafePointer<ghostty_clipboard_content_s>?,
        _ len: Int
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
        // text/plain だけ拾う。他の mime (text/html 等) は M2 以降。
        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, let data = item.data else { continue }
            guard String(cString: mime).hasPrefix("text/plain") else { continue }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(String(cString: data), forType: .string)
            return
        }
    }

    /// libghostty → ホストへの要求。約 60 種類あるが M1 では最小限だけ処理する。
    /// [RENDERER] ここが本体の「タブ状態 / タイトル / pwd / 通知」の入口になる。
    private static func handleAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let view = view(from: ghostty_surface_userdata(target.target.surface)),
                  let title = action.action.set_title.title else { return true }
            let str = String(cString: title)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { view.window?.title = str }
            }
            return true

        // M2: URL / path hit testing の観測点。
        // libghostty がセル下のテキストをリンクと判定すると、hover のたびにここへ
        // URL が飛んでくる。tmux 越しでも通るかを確認するため必ずログに出す。
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let link = action.action.mouse_over_link
            if let url = link.url, link.len > 0 {
                let str = String(
                    decoding: UnsafeRawBufferPointer(start: url, count: Int(link.len)), as: UTF8.self)
                NSLog("[spike] MOUSE_OVER_LINK url=\(str)")
            } else {
                NSLog("[spike] MOUSE_OVER_LINK <cleared>")
            }
            return true

        // M2: リンクの実クリック。既定ブラウザを開いてしまうと検証の邪魔なので
        // スパイクでは開かずログのみ。
        case GHOSTTY_ACTION_OPEN_URL:
            let open = action.action.open_url
            if let url = open.url, open.len > 0 {
                let str = String(
                    decoding: UnsafeRawBufferPointer(start: url, count: Int(open.len)), as: UTF8.self)
                NSLog("[spike] OPEN_URL kind=\(open.kind.rawValue) url=\(str)")
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE, GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_PWD, GHOSTTY_ACTION_RENDER,
             GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_CELL_SIZE,
             GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_SECURE_INPUT:
            // M1 では観測しない (ログのみ)。M2/M3 で扱う。
            return true

        case GHOSTTY_ACTION_NEW_SPLIT, GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
             GHOSTTY_ACTION_GOTO_SPLIT, GHOSTTY_ACTION_RESIZE_SPLIT,
             GHOSTTY_ACTION_EQUALIZE_SPLITS, GHOSTTY_ACTION_NEW_TAB,
             GHOSTTY_ACTION_NEW_WINDOW:
            // 設計書 §4.1 (確定): pane 分割は tmux の責務。libghostty 側の split は使わない。
            // false を返して「ホストは対応しない」ことを libghostty に伝える。
            NSLog("[spike] ignored split/tab action tag=\(action.tag.rawValue)")
            return false

        default:
            return false
        }
    }
}

// MARK: - surface を載せる NSView

/// libghostty は渡した NSView を layer-hosting にして自前の `IOSurfaceLayer` を
/// 差し込む (`src/renderer/Metal.zig`)。したがってこの View 側では
/// layer / wantsLayer / draw を一切触らない。描画は libghostty が自走する
/// (ホストから `ghostty_surface_draw` を毎フレーム呼ぶ必要はない)。
final class GhosttySurfaceNSView: NSView {
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    private let command: String
    private var trackingArea: NSTrackingArea?

    /// 直近に libghostty へ渡したグリッドサイズ (README / 検証用)
    private(set) var lastReportedSize: ghostty_surface_size_s?

    /// M1 の resize 検証用。スパイク専用のフック (本体には持ち込まない)。
    nonisolated(unsafe) static weak var current: GhosttySurfaceNSView?

    /// `ghostty_surface_size()` の生値を文字列化する
    var sizeDescription: String {
        guard let size = lastReportedSize else { return "<none>" }
        return "cols=\(size.columns) rows=\(size.rows) "
            + "px=\(size.width_px)x\(size.height_px) "
            + "cell=\(size.cell_width_px)x\(size.cell_height_px)"
    }

    init(command: String) {
        self.command = command
        super.init(frame: .zero)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    // MARK: ライフサイクル

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, surface == nil else { return }
        createSurface()
    }

    private func createSurface() {
        guard let app = GhosttyRuntime.shared.app else {
            NSLog("[spike] no ghostty app: \(GhosttyRuntime.shared.initError ?? "unknown")")
            return
        }

        // [RENDERER] surface 生成。PTY の所有者は libghostty 側であり、
        // command / working_directory / env をここで渡すと子プロセスを起動する。
        // → 本体では command に `tmux new-session -A -s <worktree>` を入れる (M2)。
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        command.withCString { cmd in
            config.command = cmd
            surface = ghostty_surface_new(app, &config)
        }

        if surface == nil {
            NSLog("[spike] ghostty_surface_new failed")
            return
        }

        updateContentScale()
        updateSurfaceSize()
        window?.makeFirstResponder(self)
        Self.current = self
    }

    // MARK: サイズ・スケール

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentScale()
        updateSurfaceSize()
        updateDisplayID()
    }

    private func updateContentScale() {
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        // [RENDERER] Retina / 外部ディスプレイ移動で呼ぶ
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        // libghostty はフレームバッファ (ピクセル) サイズを期待する
        let backing = convertToBacking(bounds.size)
        guard backing.width > 0, backing.height > 0 else { return }
        // [RENDERER] resize
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
        lastReportedSize = ghostty_surface_size(surface)
    }

    private func updateDisplayID() {
        guard let surface,
              let screen = window?.screen,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        ghostty_surface_set_display_id(surface, number.uint32Value)
    }

    // MARK: フォーカス

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    // MARK: キー入力
    //
    // AppKit bridge が必須な理由その 1。
    // SwiftUI の onKeyPress では keycode / 左右修飾キー / IME preedit が取れない。

    override func keyDown(with event: NSEvent) {
        guard let surface else { return super.keyDown(with: event) }
        var key = makeKeyEvent(event, action: GHOSTTY_ACTION_PRESS)

        // NOTE(M3): IME はここで `interpretKeyEvents` → `NSTextInputClient` へ渡し、
        // markedText を `ghostty_surface_preedit` に流す必要がある。M1 では未実装。
        if let text = ghosttyText(for: event) {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return super.keyUp(with: event) }
        var key = makeKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return super.flagsChanged(with: event) }
        // 修飾キーの押下 / 解放を、現在の flags に該当ビットが立っているかで判定する
        let mods = Self.mods(from: event.modifierFlags)
        var key = ghostty_input_key_s()
        key.keycode = UInt32(event.keyCode)
        key.mods = mods
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.text = nil
        key.unshifted_codepoint = 0
        key.composing = false

        let pressed: Bool
        switch Int(event.keyCode) {
        case 56, 60: pressed = event.modifierFlags.contains(.shift)
        case 59, 62: pressed = event.modifierFlags.contains(.control)
        case 58, 61: pressed = event.modifierFlags.contains(.option)
        case 55, 54: pressed = event.modifierFlags.contains(.command)
        default: pressed = false
        }
        key.action = pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
    }

    private func makeKeyEvent(
        _ event: NSEvent,
        action: ghostty_input_action_e
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = event.isARepeat && action == GHOSTTY_ACTION_PRESS
            ? GHOSTTY_ACTION_REPEAT : action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(from: event.modifierFlags)
        // 「文字生成に寄与した修飾キー」。control / command は寄与しないと見なす。
        key.consumed_mods = Self.mods(
            from: event.modifierFlags.subtracting([.control, .command]))
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?
            .unicodeScalars.first?.value ?? 0
        key.composing = false
        key.text = nil
        return key
    }

    /// 制御文字と PUA (ファンクションキー) を libghostty に渡さない。
    /// 制御文字のエンコードは libghostty 側の KeyEncoder が行う。
    private func ghosttyText(for event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(
                    byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }

    private static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var value = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(value)
    }

    // MARK: マウス
    //
    // AppKit bridge が必須な理由その 2 (tracking area / drag / scroll phase)。

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect,
                      .activeInKeyWindow, .cursorUpdate],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT,
            Self.mods(from: event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT,
            Self.mods(from: event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT,
            Self.mods(from: event.modifierFlags))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT,
            Self.mods(from: event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { reportMousePosition(event) }
    override func mouseDragged(with event: NSEvent) { reportMousePosition(event) }

    private func reportMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // libghostty は左上原点を期待する
        ghostty_surface_mouse_pos(
            surface, point.x, frame.height - point.y,
            Self.mods(from: event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods = 1 }
        // momentum phase を上位ビットへ (ghostty_input_scroll_mods_t の規約)
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        mods |= momentum << 1
        ghostty_surface_mouse_scroll(
            surface, event.scrollingDeltaX, event.scrollingDeltaY,
            ghostty_input_scroll_mods_t(mods))
    }

    // MARK: 観測 (Gate 3 の前哨)
    //
    // 重要な差分: PLAN.md §4.4 が挙げた `ghostty_surface_foreground_pid` /
    // `ghostty_surface_tty_name` は **v1.3.1 の ghostty.h には存在しない**
    // (upstream main で後から追加された)。v1.3.1 にピン留めする限り、
    // surface からプロセスを直接観測する手段はなく、Agent Adapter (Gate 3) は
    // `tmux list-panes -F '#{pane_pid}'` 系に頼る必要がある。

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }
}

// MARK: - M2 検証用フック (スパイク専用。本体には持ち込まない)
//
// なぜ必要か: このマシンには自動化ツール (cliclick 等) が無く、Claude Code の
// 実行コンテキストにはアクセシビリティ権限も無いため、`CGEvent` / `System Events`
// による物理的なキー・マウス送出ができない。
//
// そこで **AppKit のイベント配送層をバイパスして、libghostty の入力 API を直接叩く**。
// 検証したいのは「AppKit がイベントを配れるか」(自明) ではなく、その先の
// 「libghostty がキー / マウスをどうエンコードして PTY へ流し、tmux がどう解釈するか」
// なので、この省略で失われる情報は小さい。ただし **NSEvent → 引数への変換部分
// (`makeKeyEvent` / `reportMousePosition` / `scrollWheel`) は検証されない**ことを明記する。
extension GhosttySurfaceNSView {
    /// US ANSI キーボードの仮想キーコード。M2 で使うものだけ。
    private static let keycodes: [Character: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]
    private static let namedKeycodes: [String: UInt32] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    /// shift を伴う記号。US ANSI。
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
        "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]",
        "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// `ctrl+b` / `cmd+v` / `escape` / `z` のような指定を 1 打鍵として送る。
    /// 戻り値は libghostty がキーバインドとして消費したか (= PTY へ流れなかったか)。
    @discardableResult
    func spikeSendKey(_ spec: String) -> Bool {
        guard let surface else { return false }
        var mods = GHOSTTY_MODS_NONE.rawValue
        var parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.popLast() else { return false }
        for m in parts {
            switch m {
            case "shift": mods |= GHOSTTY_MODS_SHIFT.rawValue
            case "ctrl", "control": mods |= GHOSTTY_MODS_CTRL.rawValue
            case "alt", "opt", "option": mods |= GHOSTTY_MODS_ALT.rawValue
            case "cmd", "super", "command": mods |= GHOSTTY_MODS_SUPER.rawValue
            default: NSLog("[spike] unknown modifier: \(m)")
            }
        }

        // 元の spec (大文字も保持) から文字を取り直す
        let rawLast = String(spec.split(separator: "+").last ?? "")
        let keycode: UInt32
        var unshifted: UInt32 = 0
        var printable: String?

        if let named = Self.namedKeycodes[last] {
            keycode = named
            if named == 49 { printable = " " }
        } else if rawLast.count == 1, let ch = rawLast.first {
            if let code = Self.keycodes[Character(ch.lowercased())] {
                keycode = code
                unshifted = Character(ch.lowercased()).unicodeScalars.first?.value ?? 0
                if ch.isUppercase { mods |= GHOSTTY_MODS_SHIFT.rawValue }
            } else if let base = Self.shifted[ch], let code = Self.keycodes[base] {
                keycode = code
                unshifted = base.unicodeScalars.first?.value ?? 0
                mods |= GHOSTTY_MODS_SHIFT.rawValue
            } else {
                NSLog("[spike] unknown key: \(rawLast)")
                return false
            }
            printable = String(ch)
        } else {
            NSLog("[spike] unknown key: \(rawLast)")
            return false
        }

        var key = ghostty_input_key_s()
        key.keycode = keycode
        key.mods = ghostty_input_mods_e(mods)
        key.consumed_mods = ghostty_input_mods_e(
            mods & ~(GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SUPER.rawValue))
        key.unshifted_codepoint = unshifted
        key.composing = false

        // 重要 (M2 の実測): `ghostty_surface_text` は **paste** 経路であり
        // (`Surface.textCallback` → `completeClipboardPaste`)、bracketed paste で
        // 包まれる。素の打鍵として文字を送るには `ghostty_input_key_s.text` に
        // 「その打鍵が生成する文字」を入れる必要がある。AppKit 経路の
        // `event.characters` に相当する。
        let sendsText = printable != nil
            && (mods & (GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SUPER.rawValue
                        | GHOSTTY_MODS_ALT.rawValue)) == 0
            && Self.namedKeycodes[last] == nil

        key.action = GHOSTTY_ACTION_PRESS
        let consumed: Bool
        if sendsText, let printable {
            consumed = printable.withCString { ptr -> Bool in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            consumed = ghostty_surface_key(surface, key)
        }
        key.text = nil
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
        return consumed
    }

    /// 文字列をそのまま PTY へ流す (IME 確定文字と同じ経路)。
    func spikeSendText(_ text: String) {
        guard let surface else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                ghostty_surface_text(surface, ptr, UInt(buf.count))
            }
        }
    }

    /// ビュー座標 (左上原点、point 単位) でのマウス位置。
    /// `shift` は「mouse reporting を一時的にバイパスする」既定の修飾キー。
    func spikeMousePos(_ x: Double, _ y: Double, shift: Bool = false, cmd: Bool = false) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, x, y, Self.spikeMods(shift: shift, cmd: cmd))
    }

    func spikeMouseButton(press: Bool, right: Bool = false,
                          shift: Bool = false, cmd: Bool = false) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface,
            press ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE,
            right ? GHOSTTY_MOUSE_RIGHT : GHOSTTY_MOUSE_LEFT,
            Self.spikeMods(shift: shift, cmd: cmd))
    }

    private static func spikeMods(shift: Bool, cmd: Bool = false) -> ghostty_input_mods_e {
        var v = GHOSTTY_MODS_NONE.rawValue
        if shift { v |= GHOSTTY_MODS_SHIFT.rawValue }
        if cmd { v |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(v)
    }

    func spikeScroll(_ dx: Double, _ dy: Double) {
        guard let surface else { return }
        // precise deltas (トラックパッド相当) として送る
        ghostty_surface_mouse_scroll(surface, dx, dy, ghostty_input_scroll_mods_t(1))
    }

    /// surface の観測可能な状態をまとめて 1 行にする。
    func spikeReport() -> String {
        guard let surface else { return "surface=<nil>" }
        var out = "window=\(window?.windowNumber ?? -1)"
        out += " size[\(sizeDescription)]"
        out += " mouse_captured=\(ghostty_surface_mouse_captured(surface))"
        out += " process_exited=\(ghostty_surface_process_exited(surface))"
        let hasSel = ghostty_surface_has_selection(surface)
        out += " has_selection=\(hasSel)"
        if hasSel {
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                if let ptr = text.text, text.text_len > 0 {
                    let str = String(
                        decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)),
                        as: UTF8.self)
                    out += " selection=\(str.debugDescription)"
                }
                ghostty_surface_free_text(surface, &text)
            }
        }
        return out
    }
}

// MARK: - SwiftUI ブリッジ

struct GhosttyTerminalView: NSViewRepresentable {
    var command: String

    func makeNSView(context: Context) -> GhosttySurfaceNSView {
        GhosttySurfaceNSView(command: command)
    }

    func updateNSView(_ nsView: GhosttySurfaceNSView, context: Context) {}
}
