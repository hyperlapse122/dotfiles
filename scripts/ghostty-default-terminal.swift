import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Ghostty default terminal ERROR: " + message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else { fail("Expected apply|status and the account home.") }
let mode = CommandLine.arguments[1]
guard mode == "apply" || mode == "status" else { fail("Invalid operation.") }
guard getuid() != 0 else { fail("Run as the intended non-root user.") }
let home = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let workspace = NSWorkspace.shared
let bundleID = "com.mitchellh.ghostty"
let candidates = [
    URL(fileURLWithPath: "/Applications/Ghostty.app", isDirectory: true),
    home.appendingPathComponent("Applications/Ghostty.app", isDirectory: true),
    workspace.urlForApplication(withBundleIdentifier: bundleID)
].compactMap { $0 }
guard let app = candidates.first(where: { url in
    guard let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID,
          let executable = bundle.executableURL else { return false }
    return FileManager.default.isExecutableFile(atPath: executable.path)
}) else { fail("No executable Ghostty bundle with the expected identifier was found.") }

func isDefault() -> Bool {
    guard let selected = workspace.urlForApplication(toOpen: UTType.unixExecutable),
          let bundle = Bundle(url: selected), let executable = bundle.executableURL else { return false }
    return bundle.bundleIdentifier == bundleID && FileManager.default.isExecutableFile(atPath: executable.path)
}
if isDefault() {
    print("Ghostty Unix-executable association is ready.")
    exit(0)
}
if mode == "status" {
    print("Ghostty Unix-executable association is pending.")
    exit(2)
}
guard CGSessionCopyCurrentDictionary() != nil else {
    FileHandle.standardError.write(Data("Ghostty default-terminal approval needs a desktop session.\n".utf8))
    exit(2)
}

// Completion runs after any native approval prompt; keep the main run loop alive.
let approvalTimeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in
    FileHandle.standardError.write(Data("Ghostty default-terminal approval did not finish; complete it in a desktop session and check status again.\n".utf8))
    exit(2)
}
workspace.setDefaultApplication(at: app, toOpen: UTType.unixExecutable) { error in
    approvalTimeout.invalidate()
    if let error = error as NSError? {
        if (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError) ||
           (error.domain == NSOSStatusErrorDomain && error.code == -128) {
            FileHandle.standardError.write(Data("Ghostty default-terminal approval is pending.\n".utf8))
            exit(2)
        }
        fail(error.localizedDescription)
    }
    guard isDefault() else {
        FileHandle.standardError.write(Data("Ghostty default-terminal association is not yet effective.\n".utf8))
        exit(2)
    }
    print("Ghostty Unix-executable association is ready.")
    exit(0)
}
RunLoop.main.run()
