import AppKit
import GhosttyKit
import Testing

@testable import GhosttyRenderer

struct GhosttyColorSchemeTests {
  @Test func aquaMapsToLight() throws {
    let appearance = try #require(NSAppearance(named: .aqua))
    #expect(ghosttyColorScheme(for: appearance) == GHOSTTY_COLOR_SCHEME_LIGHT)
  }

  @Test func darkAquaMapsToDark() throws {
    let appearance = try #require(NSAppearance(named: .darkAqua))
    #expect(ghosttyColorScheme(for: appearance) == GHOSTTY_COLOR_SCHEME_DARK)
  }
}
