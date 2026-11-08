extension TmuxSessionOperations {
  public func setGlobalEnvironment(
    name: String, value: String
  ) async throws(TmuxSessionOperationError) {
    _ = try await run(["set-environment", "-g", name, value], session: nil)
  }
}
