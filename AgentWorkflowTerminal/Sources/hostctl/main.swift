import Adapters
import Foundation
import TerminalCore

func fail(_ message: String, code: Int32) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

let command: HostControlCommand
switch HostControlCommandLine.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): command = parsed
case .failure(let error): fail(error.message, code: 2)
}

switch command {
case .openWorktree(let directory, let socket):
  guard let path = socket ?? ProcessInfo.processInfo.environment["AWT_HOSTCTL_SOCKET"],
    !path.isEmpty
  else {
    fail("--socketまたはAWT_HOSTCTL_SOCKETを指定してください", code: 2)
  }
  let currentDirectory = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  let absoluteDirectory = URL(
    fileURLWithPath: directory, relativeTo: currentDirectory
  ).standardizedFileURL.path
  do {
    let response = try await HostControlSocketClient.send(
      .openWorktree(directory: absoluteDirectory), to: path, timeout: .seconds(30))
    FileHandle.standardOutput.write(Data((HostControlProtocol.encode(response) + "\n").utf8))
    switch response {
    case .opened: exit(0)
    case .failure: exit(1)
    }
  } catch {
    switch error {
    case .serverUnavailable: fail("Hostのアプリが起動していません: \(path)", code: 69)
    default: fail(String(describing: error), code: 74)
    }
  }
}
