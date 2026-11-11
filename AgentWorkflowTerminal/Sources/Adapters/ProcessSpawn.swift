import Darwin
import Foundation

#if os(macOS)
// Process は argv と env の値を fileSystemRepresentation で NFD に分解し、pack 後のかな名の
// ref を git rev-parse が解決できなくなる。NUL では abort するため、UTF-8 を直接渡す (Issue #875)。
enum ChildSpawn {
  static func launch(
    executableURL: URL, arguments: [String], environment: [String: String],
    stdout: Int32, stderr: Int32
  ) throws(ProcessRunnerError) -> pid_t {
    let executable = executableURL.path
    guard !([executable] + arguments).contains(where: { $0.utf8.contains(0) }),
      environment.allSatisfy({ key, value in
        !key.isEmpty && !key.contains("=") && !key.utf8.contains(0) && !value.utf8.contains(0)
      })
    else {
      throw .launchFailed(executableURL: executableURL, message: "Invalid argument or environment")
    }
    let argv = try makeCStringArray([executable] + arguments, executableURL: executableURL)
    defer { argv.forEach { free($0) } }
    let envp = try makeCStringArray(
      environment.map { "\($0.key)=\($0.value)" }, executableURL: executableURL)
    defer { envp.forEach { free($0) } }
    var attributes = posix_spawnattr_t(bitPattern: 0)
    try check(posix_spawnattr_init(&attributes), executableURL: executableURL)
    defer { posix_spawnattr_destroy(&attributes) }
    try configureAttributes(&attributes, executableURL: executableURL)
    var actions = posix_spawn_file_actions_t(bitPattern: 0)
    try check(posix_spawn_file_actions_init(&actions), executableURL: executableURL)
    defer { posix_spawn_file_actions_destroy(&actions) }
    try check(
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0),
      executableURL: executableURL)
    try check(posix_spawn_file_actions_adddup2(&actions, stdout, 1), executableURL: executableURL)
    try check(posix_spawn_file_actions_adddup2(&actions, stderr, 2), executableURL: executableURL)
    var processIdentifier: pid_t = 0
    try check(
      posix_spawn(&processIdentifier, executable, &actions, &attributes, argv, envp),
      executableURL: executableURL)
    return processIdentifier
  }

  private static func configureAttributes(
    _ attributes: inout posix_spawnattr_t?, executableURL: URL
  ) throws(ProcessRunnerError) {
    // NSTask の計測に合わせ、独立 pgid・空の signal mask・既定の signal disposition とし、
    // 親の余分な fd を継承させない。cwd は従来どおり親から継承する。
    var defaults = sigset_t()
    sigfillset(&defaults)
    var mask = sigset_t()
    sigemptyset(&mask)
    try check(posix_spawnattr_setsigdefault(&attributes, &defaults), executableURL: executableURL)
    try check(posix_spawnattr_setsigmask(&attributes, &mask), executableURL: executableURL)
    try check(posix_spawnattr_setpgroup(&attributes, 0), executableURL: executableURL)
    let flags = Int16(
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        | POSIX_SPAWN_CLOEXEC_DEFAULT)
    try check(posix_spawnattr_setflags(&attributes, flags), executableURL: executableURL)
  }

  private static func makeCStringArray(
    _ strings: [String], executableURL: URL
  ) throws(ProcessRunnerError) -> [UnsafeMutablePointer<CChar>?] {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    for string in strings {
      guard let pointer = string.withCString({ strdup($0) }) else {
        pointers.forEach { free($0) }
        throw .launchFailed(
          executableURL: executableURL, message: String(cString: strerror(ENOMEM)))
      }
      pointers.append(pointer)
    }
    return pointers + [nil]
  }

  private static func check(_ result: Int32, executableURL: URL) throws(ProcessRunnerError) {
    guard result == 0 else {
      throw .launchFailed(executableURL: executableURL, message: String(cString: strerror(result)))
    }
  }
}
#endif
