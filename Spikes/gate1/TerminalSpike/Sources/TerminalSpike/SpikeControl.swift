//
//  SpikeControl.swift
//
//  Gate 1 PoC (M2) — 検証を自動化するための制御チャネル。**スパイク専用。**
//
//  `TERMINAL_SPIKE_CONTROL=<path>` を指定すると、そのファイルを 100ms 間隔で
//  ポーリングし、追記された行をコマンドとして実行する。シェルから
//
//      echo 'key ctrl+b' >> "$CTL"
//
//  のように書き込むだけで、アプリのキー・マウス入力を外部から駆動できる。
//
//  このファイルは **GhosttyKit を import しない**。libghostty を呼ぶのは
//  GhosttyTerminalView.swift の `spike*` メソッドだけであり、設計書 §21.5 の
//  「libghostty 呼び出しを 1 箇所に隔離する」境界を M2 でも崩さない。
//
//  ---- コマンド一覧 ----
//   text <string>          **paste 経路** (bracketed paste で包まれる)。打鍵ではない
//   line <string>          text + CR (同じく paste 経路)
//   key <spec>             ctrl+q / cmd+v / escape / z / % など 1 打鍵
//   keys <string>          文字列を 1 文字ずつ打鍵として送る
//   mousepos <x> <y>       ビュー座標 (左上原点、pt)
//   mousecell <col> <row>  セル座標指定 (0 起点)。cell size からピクセルへ換算
//   mousedown [right]
//   mouseup [right]
//   scroll <dx> <dy>
//   drag <c1> <r1> <c2> <r2> [shift]  セル座標でドラッグ (down → move → up)
//   resize <w> <h>         ウィンドウの content size (pt)
//   keydown <string>       **M3** NSEvent を合成して keyDown 経路を通す (1文字ずつ)
//   preedit <string>       **M3** 変換中文字列を直接セット (空文字でクリア)
//   ime [label]            **M3** ghostty_surface_ime_point / 候補ウィンドウ矩形をログへ
//   report [label]         surface の観測値をログへ
//   log <text>             ログに任意のマーカーを書く
//   sleep <ms>             以降のコマンドを遅延実行する
//   quit                   アプリ終了
//

import AppKit

@MainActor
final class SpikeControl: NSObject {
    private let path: String
    private var offset: UInt64 = 0
    private var timer: Timer?
    private var pending: [String] = []
    private var blockedUntil: Date = .distantPast

    init(path: String) {
        self.path = path
        // 既存内容は読み飛ばさない: 起動前にコマンドを流し込めるようにする
        FileManager.default.createFile(atPath: path, contents: nil)
        super.init()
    }

    func start() {
        // NOTE(Swift 6): クロージャ版 Timer は @Sendable が要求され、
        // MainActor 隔離のこのクラスを捕まえられない。target/selector 版を使う。
        let t = Timer(timeInterval: 0.1, target: self,
                      selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSLog("[spike] control channel: \(path)")
    }

    @objc private func tick() { poll() }

    private func poll() {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            runPending()
            return
        }
        offset += UInt64(data.count)
        let chunk = String(decoding: data, as: UTF8.self)
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            pending.append(s)
        }
        runPending()
    }

    private func runPending() {
        while !pending.isEmpty {
            if Date() < blockedUntil { return }
            let line = pending.removeFirst()
            execute(line)
        }
    }

    private func execute(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        guard let view = GhosttySurfaceNSView.current else {
            NSLog("[spike] control: no surface, dropped: \(line)")
            return
        }

        switch cmd {
        case "text":
            view.spikeSendText(unescape(arg))
        case "line":
            view.spikeSendText(unescape(arg) + "\r")
        case "key":
            let consumed = view.spikeSendKey(arg)
            NSLog("[spike] key \(arg) consumed=\(consumed)")
        case "keys":
            // 1 文字ずつ「打鍵」として送る (paste 経路を通さない)
            for ch in arg { _ = view.spikeSendKey(String(ch)) }
        case "mousepos":
            let n = numbers(arg)
            if n.count >= 2 {
                view.spikeMousePos(n[0], n[1], shift: arg.contains("shift"),
                                   cmd: arg.contains("cmd"))
            }
        case "mousecell":
            let n = numbers(arg)
            if n.count >= 2, let p = view.spikeCellToPoint(col: n[0], row: n[1]) {
                view.spikeMousePos(p.x, p.y, shift: arg.contains("shift"),
                                   cmd: arg.contains("cmd"))
            }
        case "mousedown":
            view.spikeMouseButton(press: true, right: arg.contains("right"),
                                  shift: arg.contains("shift"), cmd: arg.contains("cmd"))
        case "mouseup":
            view.spikeMouseButton(press: false, right: arg.contains("right"),
                                  shift: arg.contains("shift"), cmd: arg.contains("cmd"))
        case "scroll":
            let n = numbers(arg)
            if n.count == 2 { view.spikeScroll(n[0], n[1]) }
        case "drag":
            let n = numbers(arg)
            guard n.count >= 4,
                  let a = view.spikeCellToPoint(col: n[0], row: n[1]),
                  let b = view.spikeCellToPoint(col: n[2], row: n[3]) else { break }
            let shift = arg.contains("shift")
            view.spikeMousePos(a.x, a.y, shift: shift)
            view.spikeMouseButton(press: true, shift: shift)
            // 途中経過を数点入れないと selection が更新されないことがある
            for i in 1...8 {
                let t = Double(i) / 8.0
                view.spikeMousePos(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, shift: shift)
            }
            view.spikeMouseButton(press: false, shift: shift)
        case "resize":
            let n = numbers(arg)
            if n.count == 2 {
                view.window?.setContentSize(NSSize(width: n[0], height: n[1]))
            }
        case "keydown":
            // M3: AppKit の keyDown 経路 (interpretKeyEvents 経由) を通す
            for ch in unescape(arg) {
                let code: UInt16 = ch == "\r" || ch == "\n" ? 36 : 0
                view.spikeKeyDown(ch == "\n" ? "\r" : String(ch), keyCode: code)
            }
        case "preedit":
            // M3: 実 IME 無しで preedit (変換中文字列) の描画だけを確認する
            view.spikeSetPreedit(unescape(arg))
        case "ime":
            NSLog("[spike] IME \(arg): \(view.spikeIMEReport())")
        case "report":
            NSLog("[spike] REPORT \(arg): \(view.spikeReport())")
        case "log":
            NSLog("[spike] MARK \(arg)")
        case "sleep":
            let ms = Double(arg.trimmingCharacters(in: .whitespaces)) ?? 0
            blockedUntil = Date().addingTimeInterval(ms / 1000.0)
        case "quit":
            NSApp.terminate(nil)
        default:
            NSLog("[spike] control: unknown command: \(line)")
        }
    }

    private func numbers(_ s: String) -> [Double] {
        s.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
    }

    /// `\n` `\t` `\e` `\\` のみ解釈する最小のエスケープ。
    private func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "e": out.append("\u{1b}")
            case "\\": out.append("\\")
            case let other?: out.append(other)
            case nil: out.append("\\")
            }
        }
        return out
    }
}

extension GhosttySurfaceNSView {
    /// セル座標 → ビュー座標 (左上原点、pt)。セル中央を指す。
    func spikeCellToPoint(col: Double, row: Double) -> CGPoint? {
        guard let size = lastReportedSize else { return nil }
        let scale = window?.backingScaleFactor ?? 2.0
        let cw = Double(size.cell_width_px) / scale
        let ch = Double(size.cell_height_px) / scale
        return CGPoint(x: (col + 0.5) * cw, y: (row + 0.5) * ch)
    }
}
