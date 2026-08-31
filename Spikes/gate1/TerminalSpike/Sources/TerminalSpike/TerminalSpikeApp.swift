//
//  TerminalSpikeApp.swift
//
//  Gate 1 PoC (M1) — SwiftUI ウィンドウに libghostty surface を 1 枚だけ載せる。
//  libghostty への依存は GhosttyTerminalView.swift に閉じている (設計書 §21.5)。
//

import AppKit
import SwiftUI

@main
struct TerminalSpikeApp: App {
    @NSApplicationDelegateAdaptor(SpikeAppDelegate.self) private var appDelegate

    /// M1 は素の zsh。M2 で `tmux new-session -A -s <name>` に差し替える。
    private let command = ProcessInfo.processInfo.environment["TERMINAL_SPIKE_COMMAND"]
        ?? "/bin/zsh"

    var body: some Scene {
        WindowGroup("Gate1 Terminal Spike") {
            // NOTE(M2): M1 では `.ignoresSafeArea()` を付けていたが、これだと
            // ターミナル面がタイトルバーの下へ潜り込み、**先頭行が隠れる**。
            // ユーザー環境の tmux は `status-position top` なので、ステータス行が
            // まるごと見えなくなっていた。安全領域を尊重する形に直す。
            GhosttyTerminalView(command: command)
                .frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 900, height: 560)
    }
}

final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // libghostty の初期化はここで確実に済ませる (ghostty_init はプロセスで 1 回)
        let runtime = GhosttyRuntime.shared
        if let error = runtime.initError {
            NSLog("[spike] ghostty runtime init error: \(error)")
        }
        NSLog("[spike] GHOSTTY_RESOURCES_DIR=\(runtime.resourcesDir ?? "<none>")")

        // M2: 外部からキー / マウスを駆動するための制御チャネル (スパイク専用)
        if let path = ProcessInfo.processInfo.environment["TERMINAL_SPIKE_CONTROL"],
           !path.isEmpty {
            let control = SpikeControl(path: path)
            self.control = control
            control.start()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in GhosttyRuntime.shared.setFocus(true) }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in GhosttyRuntime.shared.setFocus(false) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// M1 の resize 検証。`TERMINAL_SPIKE_RESIZE_TEST=1` で起動すると
    /// ウィンドウを 3 サイズに変えて `ghostty_surface_size()` の生値をログに出し、
    /// `TERMINAL_SPIKE_EXIT_AFTER` 秒後に終了する。スパイク専用の計測フック。
    func applicationDidBecomeActive(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["TERMINAL_SPIKE_RESIZE_TEST"] == "1",
              !resizeTestStarted else { return }
        resizeTestStarted = true

        let sizes: [NSSize] = [.init(width: 900, height: 560),
                               .init(width: 520, height: 380),
                               .init(width: 1200, height: 800)]
        for (index, size) in sizes.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(index)) {
                NSApp.windows.first?.setContentSize(size)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let view = GhosttySurfaceNSView.current
                    NSLog("[spike] resize \(Int(size.width))x\(Int(size.height)) -> "
                          + (view?.sizeDescription ?? "<no surface>"))
                }
            }
        }

        if let seconds = ProcessInfo.processInfo.environment["TERMINAL_SPIKE_EXIT_AFTER"],
           let delay = Double(seconds) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { NSApp.terminate(nil) }
        }
    }

    private var resizeTestStarted = false
    private var control: SpikeControl?
}
