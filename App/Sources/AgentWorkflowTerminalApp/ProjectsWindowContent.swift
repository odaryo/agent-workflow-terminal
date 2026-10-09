import AppKit
import SwiftUI
import TerminalCore

/// メイン window の中身。window は1枚のまま (`Window(id: "main")`、Issue #238) で、選択中の1 Project
/// だけを表示し、ツールバーのメニューで切り替える (Issue #372)。
struct ProjectsWindowContent: View {
  @ObservedObject var projects: ProjectsModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 0) {
      if let warning = projects.warning {
        WarningBar(text: warning) { projects.dismissWarning() }
        Divider()
      }
      content
    }
    .toolbar {
      ToolbarItem(placement: .navigation) {
        ProjectMenu(projects: projects)
      }
    }
    .task { projects.start() }
    .onAppear { projects.navigator.openWindow = openWindow }
  }

  @ViewBuilder private var content: some View {
    if !projects.didLoad {
      ProgressView("登録済みの Project を読み込んでいます")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let model = projects.selectedModel {
      // 選択中の Project の view だけを置く。`.id` で Project ごとに別の view にするので、
      // 切り替えると前の Project の端末は `dismantleNSView` で破棄され、tmux client が detach する
      // (session は残る)。タブのように opacity で重ねると前の Project の client が attach した
      // まま残り、戻ったときに同じ session へ2つ目の client が attach する。
      ProjectView(model: model)
        .id(model.project.commonDirectory)
    } else if projects.registry.projects.isEmpty {
      ContentUnavailableView {
        Label("Project が登録されていません", systemImage: "folder.badge.plus")
      } description: {
        Text("Git repository のフォルダを選んで登録してください。")
      } actions: {
        Button("Project を追加…") { chooseProjectDirectory(projects) }
      }
    } else {
      ContentUnavailableView(
        "選択できる Project がありません", systemImage: "exclamationmark.triangle",
        description: Text("登録済みの Project にはどれも到達できません。ツールバーのメニューから理由を確認してください。"))
    }
  }
}

private struct ProjectMenu: View {
  @ObservedObject var projects: ProjectsModel

  var body: some View {
    Menu {
      ForEach(projects.registry.projects, id: \.commonDirectory) { project in
        projectItem(project)
      }
      if !projects.registry.projects.isEmpty {
        Divider()
      }
      Button("Project を追加…") { chooseProjectDirectory(projects) }
      if let selected = projects.selectedProject {
        Button("「\(selected.displayName)」の登録を解除") {
          projects.unregister(selected.commonDirectory)
        }
      }
    } label: {
      Label(projects.selectedProject?.displayName ?? "Project", systemImage: "folder")
        .labelStyle(.titleAndIcon)
    }
    .help("Project")
    .disabled(!projects.didLoad)
  }

  @ViewBuilder
  private func projectItem(_ project: RegisteredProject) -> some View {
    switch projects.slots[project.commonDirectory] {
    case .available:
      // `Toggle` で印を付ける。メニューの中の `Toggle` はチェックマーク付きの項目になる。
      Toggle(
        project.displayName,
        isOn: Binding(
          get: { projects.registry.selection == project.commonDirectory },
          set: { _ in projects.select(project.commonDirectory) }
        ))
    case .unavailable(let reason):
      // 到達不能な Project は選択できないので、選択中の Project 向けの「登録を解除」からは外せない。
      // 項目ごとのサブメニューに解除を置く (全 Project が到達不能で選択が無いときもここから外せる)。
      Menu("\(project.displayName) (到達不能: \(reason))") {
        Button("登録を解除") { projects.unregister(project.commonDirectory) }
      }
    case nil:
      Button(project.displayName) {}
        .disabled(true)
    }
  }
}

/// `NSOpenPanel` は選ばれた URL を返すだけで、repository root の抽出は `ProjectsModel` が git に
/// 問い合わせて行う (設計書 §16.1)。
@MainActor
private func chooseProjectDirectory(_ projects: ProjectsModel) {
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.allowsMultipleSelection = false
  panel.prompt = "追加"
  panel.message = "登録する Git repository のフォルダを選んでください。"
  panel.begin { response in
    guard response == .OK, let url = panel.url else { return }
    Task { await projects.register(directory: url) }
  }
}
