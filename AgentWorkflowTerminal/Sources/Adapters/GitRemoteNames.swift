enum GitRemoteNames {
  static func parse(output: String) -> [String] {
    output.split(separator: "\n").map(String.init)
  }
}
