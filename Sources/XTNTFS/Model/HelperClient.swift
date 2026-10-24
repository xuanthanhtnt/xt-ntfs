import Foundation
import AppKit
import XTShared

/// An unmount or eject failed because apps have files open on the volume.
struct VolumeBusyError: LocalizedError {
    /// "Name (pid)" of each process using the volume; empty if unknown.
    var users: [String]

    var errorDescription: String? {
        if users.isEmpty {
            return NSLocalizedString("Another app is using the volume. Close any files on it and try again.", comment: "")
        }
        return String(format: NSLocalizedString("These apps are using the volume: %@. Quit them or close their files and try again.", comment: ""),
                      users.joined(separator: ", "))
    }
}

/// Async access to the privileged helper.
enum HelperClient {
    static func send(_ request: HelperRequest, timeout: Double = 3600) async throws -> HelperResponse {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try SocketIO.send(request, timeout: timeout))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Sends a request and turns a failed reply into an error.
    @discardableResult
    static func perform(_ request: HelperRequest) async throws -> HelperResponse {
        let r = try await send(request)
        if !r.ok {
            if let users = r.inUse { throw VolumeBusyError(users: users) }
            throw HelperSocketError.failed(r.error ?? NSLocalizedString("The operation failed.", comment: ""))
        }
        return r
    }

    static func status(since: Int) async -> HelperStatus? {
        try? await send(HelperRequest(command: .status, sinceEvent: since), timeout: 5).status
    }
}

/// Installs, updates and removes the privileged parts (helper + engine)
/// with an administrator prompt.
enum EngineInstaller {
    enum InstallState: Equatable {
        case unknown
        case notInstalled
        case outdated(installed: String)
        case running
        case notResponding
    }

    static var isInstalledOnDisk: Bool {
        FileManager.default.fileExists(atPath: XTPaths.helperBinary)
            && FileManager.default.fileExists(atPath: XTPaths.launchDaemonPlist)
    }

    static var macFUSEInstalled: Bool {
        FileManager.default.fileExists(atPath: XTPaths.macFUSEBundle)
            && FileManager.default.fileExists(atPath: XTPaths.macFUSELibrary)
    }

    static var macFUSEVersion: String? {
        let d = NSDictionary(contentsOfFile: XTPaths.macFUSEBundle + "/Contents/Info.plist")
        return (d?["CFBundleShortVersionString"] as? String) ?? (d?["CFBundleVersion"] as? String)
    }

    static func state(for status: HelperStatus?) -> InstallState {
        guard let status else { return isInstalledOnDisk ? .notResponding : .notInstalled }
        if status.helperVersion != XTBuild.fullVersion || status.protocolVersion != XTProtocolVersion {
            return .outdated(installed: status.helperVersion)
        }
        return .running
    }

    private static func script(_ name: String) -> String? {
        Bundle.main.path(forResource: name, ofType: "sh", inDirectory: "scripts")
    }

    private static func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs a bundled script as root through the standard admin prompt.
    private static func runPrivileged(script name: String, arguments: [String], prompt: String) async throws {
        guard let path = script(name) else {
            throw HelperSocketError.failed("Missing script \(name).sh in the app bundle.")
        }
        var command = "\"/bin/bash \" & quoted form of " + appleScriptQuoted(path)
        for a in arguments {
            command += " & \" \" & quoted form of " + appleScriptQuoted(a)
        }
        let source = "do shell script \(command) with prompt \(appleScriptQuoted(prompt)) with administrator privileges"
        // osascript keeps the app responsive while the password prompt is up.
        let result: (Int32, String) = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", source]
                let errPipe = Pipe()
                p.standardError = errPipe
                p.standardOutput = Pipe()
                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
        if result.0 != 0 {
            if result.1.contains("-128") { throw CancellationError() }
            let text = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperSocketError.failed(text.isEmpty ? "The installer failed (\(result.0))." : text)
        }
    }

    static func install() async throws {
        try await runPrivileged(script: "install-engine",
                                arguments: [Bundle.main.bundlePath],
                                prompt: NSLocalizedString("XT NTFS wants to install its NTFS engine.", comment: ""))
        // Give launchd a moment to start the helper.
        for _ in 0..<40 {
            if await HelperClient.status(since: Int.max) != nil { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    static func uninstall() async throws {
        _ = try? await HelperClient.send(HelperRequest(command: .unmountAll), timeout: 300)
        try await runPrivileged(script: "uninstall-engine", arguments: [],
                                prompt: NSLocalizedString("XT NTFS wants to remove its NTFS engine.", comment: ""))
    }
}
