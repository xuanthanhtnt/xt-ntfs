import Foundation
import XTShared

struct BenchmarkResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var volumeName: String
    var driver: String
    var fileSystem: String
    var sizeMB: Int
    var writeMBps: Double
    var readMBps: Double
    var smallFilesPerSecond: Double
}

enum BenchmarkError: LocalizedError {
    case notWritable
    case noSpace
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notWritable: return NSLocalizedString("The volume is read-only.", comment: "")
        case .noSpace: return NSLocalizedString("Not enough free space for the test file.", comment: "")
        case .io(let s): return s
        }
    }
}

/// Sequential write/read and small-file test on a mounted volume. Uses
/// F_NOCACHE so results reflect the driver and the disk, not RAM.
final class BenchmarkRunner {
    private(set) var cancelled = false
    func cancel() { cancelled = true }

    func run(volume: Volume, sizeMB: Int, progress: @escaping (Double, String) -> Void) throws -> BenchmarkResult {
        guard let mp = volume.mountPoint else { throw BenchmarkError.notWritable }
        if volume.readOnly { throw BenchmarkError.notWritable }
        if let free = MountTable.usage(of: mp)?.free, free < Int64(sizeMB + 64) << 20 {
            throw BenchmarkError.noSpace
        }
        let dir = mp + "/.xtntfs-benchmark-\(UUID().uuidString.prefix(8))"
        guard mkdir(dir, 0o755) == 0 else { throw BenchmarkError.io(errnoText("mkdir")) }
        defer { removeTree(dir) }

        let chunk = 8 << 20
        let total = Int64(sizeMB) << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buffer.deallocate() }
        arc4random_buf(buffer, chunk)
        let file = dir + "/seq.bin"

        // Sequential write
        progress(0, NSLocalizedString("Writing…", comment: ""))
        var fd = open(file, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { throw BenchmarkError.io(errnoText("open")) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var written: Int64 = 0
        let t0 = Date()
        while written < total {
            if cancelled { close(fd); throw CancellationError() }
            let n = write(fd, buffer, chunk)
            if n <= 0 { let e = errnoText("write"); close(fd); throw BenchmarkError.io(e) }
            written += Int64(n)
            progress(Double(written) / Double(total) * 0.45, NSLocalizedString("Writing…", comment: ""))
        }
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        close(fd)
        let writeTime = Date().timeIntervalSince(t0)

        // Sequential read
        progress(0.45, NSLocalizedString("Reading…", comment: ""))
        fd = open(file, O_RDONLY)
        guard fd >= 0 else { throw BenchmarkError.io(errnoText("open")) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var readBytes: Int64 = 0
        let t1 = Date()
        while true {
            if cancelled { close(fd); throw CancellationError() }
            let n = read(fd, buffer, chunk)
            if n < 0 { let e = errnoText("read"); close(fd); throw BenchmarkError.io(e) }
            if n == 0 { break }
            readBytes += Int64(n)
            progress(0.45 + Double(readBytes) / Double(total) * 0.4, NSLocalizedString("Reading…", comment: ""))
        }
        close(fd)
        let readTime = Date().timeIntervalSince(t1)
        unlink(file)

        // Small files: create, write 4 KiB, close; then make it durable.
        progress(0.85, NSLocalizedString("Small files…", comment: ""))
        let count = 500
        let small = dir + "/small"
        mkdir(small, 0o755)
        let t2 = Date()
        for i in 0..<count {
            if cancelled { throw CancellationError() }
            let f = open(small + "/f\(i).dat", O_CREAT | O_WRONLY | O_TRUNC, 0o644)
            if f < 0 { throw BenchmarkError.io(errnoText("open")) }
            _ = write(f, buffer, 4096)
            close(f)
            if i % 50 == 0 { progress(0.85 + Double(i) / Double(count) * 0.15, NSLocalizedString("Small files…", comment: "")) }
        }
        let dfd = open(small, O_RDONLY)
        if dfd >= 0 { if fcntl(dfd, F_FULLFSYNC) != 0 { fsync(dfd) }; close(dfd) }
        let smallTime = Date().timeIntervalSince(t2)
        progress(1, NSLocalizedString("Done", comment: ""))

        let mb = Double(total) / 1_048_576
        return BenchmarkResult(volumeName: volume.name,
                               driver: volume.driverName ?? "?",
                               fileSystem: volume.fileSystemName,
                               sizeMB: sizeMB,
                               writeMBps: mb / max(writeTime, 0.001),
                               readMBps: Double(readBytes) / 1_048_576 / max(readTime, 0.001),
                               smallFilesPerSecond: Double(count) / max(smallTime, 0.001))
    }

    private func errnoText(_ op: String) -> String {
        "\(op): \(String(cString: strerror(errno)))"
    }

    private func removeTree(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

enum BenchmarkHistory {
    private static let key = "benchmarkHistory"

    static func load() -> [BenchmarkResult] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([BenchmarkResult].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [BenchmarkResult]) {
        if let data = try? JSONEncoder().encode(Array(list.prefix(50))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
