public enum SyntaxHighlightLanguage {
  /// 値は highlight.js が登録している言語名またはその別名。
  /// 拡張子が2つ以上の言語を指し得るもの (`.h` は C / C++ / Objective-C、`.m` は Objective-C /
  /// MATLAB) は載せない。誤った言語で色を付けるのは、色を付けないより悪い (§12.3)。
  private static let namesByExtension: [String: String] = [
    "bash": "bash",
    "bat": "dos",
    "c": "c",
    "cc": "cpp",
    "cjs": "javascript",
    "cpp": "cpp",
    "cs": "csharp",
    "css": "css",
    "cxx": "cpp",
    "dart": "dart",
    "diff": "diff",
    "dockerfile": "dockerfile",
    "erl": "erlang",
    "ex": "elixir",
    "exs": "elixir",
    "go": "go",
    "gql": "graphql",
    "graphql": "graphql",
    "hh": "cpp",
    "hpp": "cpp",
    "hs": "haskell",
    "htm": "xml",
    "html": "xml",
    "ini": "ini",
    "java": "java",
    "jl": "julia",
    "js": "javascript",
    "json": "json",
    "jsx": "javascript",
    "kt": "kotlin",
    "kts": "kotlin",
    "lua": "lua",
    "markdown": "markdown",
    "md": "markdown",
    "mjs": "javascript",
    "patch": "diff",
    "php": "php",
    "pl": "perl",
    "proto": "protobuf",
    "ps1": "powershell",
    "py": "python",
    "r": "r",
    "rb": "ruby",
    "rs": "rust",
    "scala": "scala",
    "scss": "scss",
    "sh": "bash",
    "sql": "sql",
    "svg": "xml",
    "swift": "swift",
    "toml": "toml",
    "ts": "typescript",
    "tsx": "typescript",
    "vim": "vim",
    "xml": "xml",
    "yaml": "yaml",
    "yml": "yaml",
    "zig": "zig",
    "zsh": "bash",
  ]

  public static func name(forFileName fileName: String) -> String? {
    guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return nil }
    let fileExtension = fileName[fileName.index(after: dot)...]
    guard !fileExtension.isEmpty else { return nil }
    // `lowercased()` はロケール非依存 (計測: `LANG=tr_TR.UTF-8` でも `"I".lowercased() == "i"`)。
    return namesByExtension[fileExtension.lowercased()]
  }
}
