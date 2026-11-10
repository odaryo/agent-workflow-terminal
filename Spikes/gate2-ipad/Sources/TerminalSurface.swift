import SwiftTerm
import SwiftUI

@MainActor
struct TerminalSurface: UIViewRepresentable {
    let model: ConnectionModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> TerminalView {
        model.terminal.terminalDelegate = context.coordinator
        return model.terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    @MainActor
    final class Coordinator: TerminalViewDelegate {
        let model: ConnectionModel

        init(model: ConnectionModel) { self.model = model }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            model.send(data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            model.resize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
