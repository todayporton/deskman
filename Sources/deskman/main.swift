import DeskmanCore
import Foundation

if CommandLine.arguments.count == 1 {
    MainActor.assumeIsolated { runMenuBar() }
}

do {
    try runCLI(Array(CommandLine.arguments.dropFirst()))
} catch let error as DeskmanError {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(error.exitCode)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
