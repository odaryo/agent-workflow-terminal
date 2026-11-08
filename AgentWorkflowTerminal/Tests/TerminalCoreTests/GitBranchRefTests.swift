import TerminalCore
import Testing

@Suite("branch ref の名前空間")
struct GitBranchRefTests {
  @Test(
    "短縮名と完全名を対応させる",
    arguments: [
      (GitBranchRef.local("feature"), "feature", "refs/heads/feature"),
      (.local("origin/feature"), "origin/feature", "refs/heads/origin/feature"),
      (.remote("origin/feature"), "origin/feature", "refs/remotes/origin/feature"),
      (.local("HEAD"), "HEAD", "refs/heads/HEAD"),
    ])
  func names(branch: GitBranchRef, shortName: String, fullName: String) {
    #expect(branch.shortName == shortName)
    #expect(branch.fullName == fullName)
    #expect(GitBranchRef(fullName: fullName) == branch)
  }

  @Test(
    "branch 以外と空の名前と不正な文字と remote HEAD を拒否する",
    arguments: [
      "", "feature", "refs/tags/feature", "refs/heads/", "refs/remotes/",
      "refs/remotes/origin/HEAD", "refs/remotes/upstream/HEAD", "refs/remotes/HEAD",
      "refs/heads/feature\n", "refs/remotes/origin/feature\n",
      "refs/heads/with space", "refs/remotes/origin/with space",
      "refs/heads/with\ttab", "refs/remotes/origin/with\rreturn",
      "refs/heads/control\u{0000}", "refs/remotes/origin/control\u{007F}",
    ])
  func rejectsNonBranch(fullName: String) {
    #expect(GitBranchRef(fullName: fullName) == nil)
  }

  @Test("同じ短縮名でも local と remote は異なる")
  func distinguishesNamespaces() {
    #expect(Set([GitBranchRef.local("origin/feature"), .remote("origin/feature")]).count == 2)
  }
}
