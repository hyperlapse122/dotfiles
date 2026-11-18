import Foundation
import Path
import Testing
import XcodesKit

@Test(arguments: [0, 1])
func aria2UsesScopedCookieFile(exitStatus: Int) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let tool = directory.appendingPathComponent("aria2c")
    try """
        #!/bin/sh
        set -eu
        cd "${0%/*}"
        printf '%s\\n' "$@" > arguments
        for argument do
            case "$argument" in
                --load-cookies=*)
                    jar=${argument#*=}
                    printf '%s\\n' "$jar" > cookie-path
                    stat -c '%a' "$jar" > cookie-mode
                    cat "$jar" > cookies
                    ;;
            esac
        done
        exit \(exitStatus)

        """.write(to: tool, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)

    let cookie = try #require(HTTPCookie(properties: [
        .domain: "download.example.test",
        .path: "/archives",
        .secure: "TRUE",
        .name: "session",
        .value: "fake-cookie",
    ]))
    let stream = Aria2DownloadService().download(
        aria2Path: try #require(Path(tool.path)),
        url: try #require(URL(string: "https://download.example.test/archives/xcode.xip")),
        destination: try #require(Path(directory.appendingPathComponent("xcode.xip").path)),
        cookies: [cookie]
    )

    var failed = false
    do {
        for try await _ in stream {}
    } catch {
        failed = true
    }
    #expect(failed == (exitStatus != 0))

    func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    let arguments = try read("arguments")
    #expect(!arguments.contains("fake-cookie"))
    #expect(arguments.split(separator: "\n").contains("--no-conf"))
    #expect(arguments.split(separator: "\n").contains("--ca-certificate=/fixture-ca.pem"))
    #expect(try read("cookie-mode") == "600\n")
    #expect(try read("cookies").split(separator: "\n").contains(
        "download.example.test\tFALSE\t/archives\tTRUE\t0\tsession\tfake-cookie"
    ))
    let cookiePath = try read("cookie-path").trimmingCharacters(in: .newlines)
    #expect(!FileManager.default.fileExists(atPath: cookiePath))
}
