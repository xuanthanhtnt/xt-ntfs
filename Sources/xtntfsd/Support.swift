import Foundation
import SystemConfiguration
import XTShared

// MARK: - Logging

enum Log {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }
}

// MARK: - Running tools

struct CommandResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool

    var ok: Bool { status == 0 && !timedOut }
    var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Shell {
    /// Runs a program and collects its output. Never throws: launch errors
    /// are reported as status 127.
    @discardableResult
    static func run(_ path: String, _ args: [String], env: [String: String] = [:],
                    timeout: TimeInterval = 600) -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LC_ALL"] = "en_US.UTF-8"
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        do {
            try p.run()
        } catch {
            return CommandResult(status: 127, stdout: "", stderr: "\(path): \(error.localizedDescription)", timedOut: false)
        }
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline {
                timedOut = true
                p.terminate()
                break
            }
            usleep(20_000)
        }
        p.waitUntilExit()
        // Children that daemonize close their copies of the pipes; bound the
        // wait anyway in case a grandchild keeps them open.
        _ = group.wait(timeout: .now() + 5)
        return CommandResult(status: p.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self),
                             timedOut: timedOut)
    }
}

// MARK: - System facts

enum System {
    /// The user logged in at the console, if any.
    static func consoleUser() -> (uid: uid_t, gid: gid_t, name: String)? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              name != "loginwindow", uid != 0 else { return nil }
        return (uid, gid, name)
    }

    static func isAdmin(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        guard let pw = getpwuid(uid) else { return false }
        var groups = [Int32](repeating: 0, count: 256)
        var count: Int32 = Int32(groups.count)
        _ = getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &count)
        return groups.prefix(Int(max(0, count))).contains(80)
    }

    static var macFUSEInstalled: Bool {
        FileManager.default.fileExists(atPath: XTPaths.macFUSEBundle)
            && FileManager.default.fileExists(atPath: XTPaths.macFUSELibrary)
    }

    static var macFUSEVersion: String? {
        let plist = XTPaths.macFUSEBundle + "/Contents/Info.plist"
        guard let d = NSDictionary(contentsOfFile: plist) else { return nil }
        return (d["CFBundleShortVersionString"] as? String) ?? (d["CFBundleVersion"] as? String)
    }

    static var engineVersion: String {
        let path = XTPaths.engineDir + "/NTFS3G_VERSION"
        let v = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.map { "ntfs-3g \($0) + XT raw I/O" } ?? "not installed"
    }

    static func tool(_ name: String) -> String {
        XTPaths.engineDir + "/" + name
    }

    static func isMountPoint(_ path: String) -> Bool {
        MountTable.entries().contains { $0.on == path }
    }

    /// PIDs of ntfs-3g processes serving @bsd.
    static func enginePIDs(bsd: String) -> [Int32] {
        let r = Shell.run("/usr/bin/pgrep", ["-f", "ntfs-3g /dev/r?\(bsd) "], timeout: 10)
        return r.stdout.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    /// Waits until no ntfs-3g process serves @bsd (all data written back).
    @discardableResult
    static func waitForEngineExit(bsd: String, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if enginePIDs(bsd: bsd).isEmpty { return true }
            usleep(150_000)
        }
        return enginePIDs(bsd: bsd).isEmpty
    }

    /// Reads the OEM id of a volume's boot sector ("NTFS    ", "-FVE-FS-", ...).
    static func bootSectorOEM(bsd: String) -> String? {
        let fd = open("/dev/r" + bsd, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var sector = [UInt8](repeating: 0, count: 4096)
        // 4 KiB keeps the read aligned for both 512 and 4096 byte sectors.
        let n = sector.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 4096, 0) }
        guard n >= 11 else { return nil }
        return String(decoding: sector[3..<11], as: UTF8.self)
    }
}
