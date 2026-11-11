import Adapters
import Darwin
import Foundation
import TerminalCore

func writeLine(_ line: String, to descriptor: Int32) -> Bool {
  let bytes = Array((line + "\n").utf8)
  var offset = 0
  while offset < bytes.count {
    let count = bytes.withUnsafeBytes { buffer in
      Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), bytes.count - offset)
    }
    if count > 0 {
      offset += count
    } else if count < 0 && errno == EINTR {
      continue
    } else {
      return false
    }
  }
  return true
}

func fail(_ message: String, code: Int32) -> Never {
  _ = writeLine(message, to: STDERR_FILENO)
  exit(code)
}

func absoluteDirectory(_ directory: String) -> String {
  if let resolved = realpath(directory, nil) {
    defer { free(resolved) }
    return String(cString: resolved)
  }
  return directory.hasPrefix("/")
    ? directory : FileManager.default.currentDirectoryPath + "/" + directory
}

signal(SIGPIPE, SIG_IGN)

let command: HostControlCommand
switch HostControlCommandLine.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): command = parsed
case .failure(let error): fail(error.message, code: 2)
}

switch command {
case .openWorktree(let directory, let socket, let fromPane):
  guard let path = socket ?? ProcessInfo.processInfo.environment["AWT_HOSTCTL_SOCKET"],
    !path.isEmpty
  else {
    fail("--socketまたはAWT_HOSTCTL_SOCKETを指定してください", code: 2)
  }
  do {
    let response = try await HostControlSocketClient.send(
      .openWorktree(directory: absoluteDirectory(directory), fromPane: fromPane), to: path,
      timeout: .seconds(30))
    guard writeLine(HostControlProtocol.encode(response), to: STDOUT_FILENO) else {
      fail("標準出力に書き込めません", code: 74)
    }
    switch response {
    case .opened: exit(0)
    case .failure: exit(1)
    }
  } catch {
    switch error {
    case .serverUnavailable: fail("Hostのアプリが起動していません: \(path)", code: 69)
    case .pathTooLong(let path): fail("socketパスが長すぎます: \(path)", code: 74)
    case .addressInUse(let path): fail("socketは使用中です: \(path)", code: 74)
    case .timedOut: fail("Hostとの通信がタイムアウトしました", code: 74)
    case .io(let message): fail(message, code: 74)
    }
  }
}
