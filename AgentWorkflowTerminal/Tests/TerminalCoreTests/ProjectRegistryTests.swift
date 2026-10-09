import Foundation
import TerminalCore
import Testing

@Suite("登録済み Project の一覧と選択 (設計書 §2.1 / §16.1)")
struct ProjectRegistryTests {

  // MARK: - Helpers

  private func project(_ name: String, directory: String? = nil) throws -> RegisteredProject {
    RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/\(name)/.git")),
      directory: directory ?? "/\(name)"
    )
  }

  private func registry(_ projects: [RegisteredProject]) -> ProjectRegistry {
    var registry = ProjectRegistry()
    for project in projects {
      registry.register(project)
    }
    return registry
  }

  // MARK: - 追加

  @Test("空の一覧は未選択")
  func emptyRegistryHasNoSelection() {
    let registry = ProjectRegistry()

    #expect(registry.projects.isEmpty)
    #expect(registry.selection == nil)
  }

  @Test("追加した Project は末尾に並び、選択される")
  func registerAppendsAndSelects() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    var registry = ProjectRegistry()

    let alphaRegistration = registry.register(alpha)
    let betaRegistration = registry.register(beta)

    #expect(alphaRegistration == .added)
    #expect(betaRegistration == .added)

    #expect(registry.projects == [alpha, beta])
    #expect(registry.selection == beta.commonDirectory)
  }

  /// 同じ repository を linked worktree の中など別のパスから選んでも、git common dir は同じ値になる
  /// (git 2.50.1 実測)。一覧を2行にすると、同じ Project の worktree 検出が2本走り、同じ保存ファイル
  /// (`projects/<common dir の hash>/`) を2つのモデルが書き合う。
  @Test("common dir が同じなら別のパスから追加しても重複させず、既存を選択する")
  func registeringSameCommonDirectorySelectsExisting() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    let alphaAgain = try project("alpha", directory: "/alpha-elsewhere")
    var registry = self.registry([alpha, beta])

    let registration = registry.register(alphaAgain)

    #expect(registration == .alreadyRegistered)
    #expect(registry.projects == [alpha, beta])
    #expect(registry.project(alpha.commonDirectory)?.directory == "/alpha")
    #expect(registry.selection == alpha.commonDirectory)
  }

  /// 同一性は `WorktreeIdentity` のバイト列比較に乗る。正準等価な別表記 (NFC / NFD) を同じ Project と
  /// みなすと、`TmuxSessionName` と保存先の hash が別々の値になる。
  @Test("正準等価でもバイト列が違う common dir は別の Project として扱う")
  func canonicallyEquivalentCommonDirectoriesAreDistinct() throws {
    let composed = RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/caf\u{00E9}/.git")),
      directory: "/caf\u{00E9}"
    )
    let decomposed = RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/cafe\u{0301}/.git")),
      directory: "/cafe\u{0301}"
    )
    var registry = ProjectRegistry()

    registry.register(composed)
    let registration = registry.register(decomposed)

    #expect(registration == .added)
    #expect(registry.projects.count == 2)
  }

  // MARK: - 登録解除

  @Test("選択中でない Project を外しても選択は動かない")
  func unregisteringUnselectedKeepsSelection() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    var registry = self.registry([alpha, beta])

    registry.unregister(alpha.commonDirectory)

    #expect(registry.projects == [beta])
    #expect(registry.selection == beta.commonDirectory)
  }

  @Test("選択中の Project を外すと先頭が選択される")
  func unregisteringSelectedSelectsFirst() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    let gamma = try project("gamma")
    var registry = self.registry([alpha, beta, gamma])

    registry.unregister(gamma.commonDirectory)

    #expect(registry.projects == [alpha, beta])
    #expect(registry.selection == alpha.commonDirectory)
  }

  @Test("最後の Project を外すと未選択になる")
  func unregisteringLastProjectClearsSelection() throws {
    let alpha = try project("alpha")
    var registry = self.registry([alpha])

    registry.unregister(alpha.commonDirectory)

    #expect(registry.projects.isEmpty)
    #expect(registry.selection == nil)
  }

  @Test("登録されていない Project の登録解除は何もしない")
  func unregisteringUnknownProjectIsNoOp() throws {
    let alpha = try project("alpha")
    let registry = self.registry([alpha])
    var changed = registry

    changed.unregister(try project("unknown").commonDirectory)

    #expect(changed == registry)
  }

  // MARK: - 選択

  @Test("登録済みの Project を選択できる")
  func selectRegisteredProject() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    var registry = self.registry([alpha, beta])

    let selected = registry.select(alpha.commonDirectory)

    #expect(selected)
    #expect(registry.selection == alpha.commonDirectory)
  }

  @Test("登録されていない Project は選択できず、選択は動かない")
  func selectUnknownProjectIsRejected() throws {
    let alpha = try project("alpha")
    var registry = self.registry([alpha])

    let selected = registry.select(try project("unknown").commonDirectory)

    #expect(selected == false)
    #expect(registry.selection == alpha.commonDirectory)
  }

  /// 到達できない Project は選択不可 (Issue #372)。到達可能性は観測結果であって一覧の状態では
  /// ないので、判定は呼び出し側から受け取る。
  @Test("選択中の Project が選択不可なら、選択できる先頭の Project へ移す")
  func reselectMovesToFirstSelectable() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    let gamma = try project("gamma")
    var registry = self.registry([alpha, beta, gamma])
    registry.select(alpha.commonDirectory)

    registry.reselect { $0 != alpha.commonDirectory }

    #expect(registry.selection == beta.commonDirectory)
  }

  @Test("選択中の Project が選択できるなら動かさない")
  func reselectKeepsSelectableSelection() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    var registry = self.registry([alpha, beta])

    registry.reselect { _ in true }

    #expect(registry.selection == beta.commonDirectory)
  }

  @Test("選択できる Project が1つも無ければ未選択になる")
  func reselectWithoutSelectableProjectClearsSelection() throws {
    let alpha = try project("alpha")
    var registry = self.registry([alpha])

    registry.reselect { _ in false }

    #expect(registry.selection == nil)
    #expect(registry.projects == [alpha])
  }

  // MARK: - 永続化形式からの復元

  @Test("保存した一覧と選択をそのまま復元する")
  func roundTripThroughPersistedForm() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    var registry = self.registry([alpha, beta])
    registry.select(alpha.commonDirectory)

    let persisted = PersistedProjectRegistry(registry)

    #expect(persisted.schemaVersion == PersistedProjectRegistry.currentSchemaVersion)
    #expect(ProjectRegistry(restoring: persisted) == registry)
  }

  @Test("保存された選択が一覧に無ければ先頭を選択する")
  func restoringWithMissingSelectionSelectsFirst() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    let persisted = PersistedProjectRegistry(
      projects: [PersistedRegisteredProject(alpha), PersistedRegisteredProject(beta)],
      selection: try project("gone").commonDirectory
    )

    let restored = ProjectRegistry(restoring: persisted)

    #expect(restored.projects == [alpha, beta])
    #expect(restored.selection == alpha.commonDirectory)
  }

  @Test("保存された選択が無くても一覧があれば先頭を選択する")
  func restoringWithoutSelectionSelectsFirst() throws {
    let alpha = try project("alpha")
    let persisted = PersistedProjectRegistry(
      projects: [PersistedRegisteredProject(alpha)],
      selection: nil
    )

    #expect(ProjectRegistry(restoring: persisted).selection == alpha.commonDirectory)
  }

  @Test("空の一覧を復元すると未選択になる")
  func restoringEmptyRegistryHasNoSelection() throws {
    let persisted = PersistedProjectRegistry(
      projects: [],
      selection: try project("gone").commonDirectory
    )

    let restored = ProjectRegistry(restoring: persisted)

    #expect(restored.projects.isEmpty)
    #expect(restored.selection == nil)
  }

  /// 手で編集されたファイルや、将来の不具合で同じ common dir が2行入っても、一覧に重複を
  /// 持ち込まない。重複したまま復元すると、同じ Project のモデルが2つ作られる。
  @Test("保存に同じ common dir が重複していたら先に現れたほうだけを残す")
  func restoringDropsDuplicateCommonDirectories() throws {
    let alpha = try project("alpha")
    let alphaElsewhere = try project("alpha", directory: "/alpha-elsewhere")
    let beta = try project("beta")
    let persisted = PersistedProjectRegistry(
      projects: [
        PersistedRegisteredProject(alpha),
        PersistedRegisteredProject(beta),
        PersistedRegisteredProject(alphaElsewhere),
      ],
      selection: beta.commonDirectory
    )

    let restored = ProjectRegistry(restoring: persisted)

    #expect(restored.projects == [alpha, beta])
    #expect(restored.selection == beta.commonDirectory)
  }

  @Test("永続化形式は schemaVersion・一覧・選択を JSON の固定キーで持つ")
  func persistedFormEncodesFixedKeys() throws {
    let alpha = try project("alpha")
    let persisted = PersistedProjectRegistry(self.registry([alpha]))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    let json = String(decoding: try encoder.encode(persisted), as: UTF8.self)

    #expect(
      json
        == #"{"projects":[{"commonDirectory":"/alpha/.git","directory":"/alpha"}],"#
        + #""schemaVersion":1,"selection":"/alpha/.git"}"#
    )
  }

  @Test("common dir が絶対パスでない保存は復号に失敗する")
  func decodingRejectsRelativeCommonDirectory() {
    let json =
      #"{"schemaVersion":1,"projects":[{"commonDirectory":"alpha/.git","directory":"/alpha"}]}"#

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(PersistedProjectRegistry.self, from: Data(json.utf8))
    }
  }
}
