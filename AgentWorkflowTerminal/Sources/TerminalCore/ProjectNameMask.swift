public enum ProjectNameMask {
  public static func masked(_ name: String) -> String {
    name.prefix(1) + "•••"
  }
}
