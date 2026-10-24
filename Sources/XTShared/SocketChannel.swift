import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum HelperSocketError: Error, LocalizedError {
    case notRunning
    case io(String)
    case badReply(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return NSLocalizedString("The XT NTFS engine service is not running.", comment: "")
        case .io(let s):
            return String(format: NSLocalizedString("Communication with the engine failed: %@", comment: ""), s)
        case .badReply(let s):
            return String(format: NSLocalizedString("Unexpected reply from the engine: %@", comment: ""), s)
        case .failed(let s):
            return NSLocalizedString(s, comment: "")
        }
    }
}

/// Newline-delimited JSON over a UNIX domain socket. One request and one
/// reply per connection.
public enum SocketIO {
    public static let maxMessage = 8 << 20

    public static func setTimeouts(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw HelperSocketError.io(String(cString: strerror(errno)))
                }
                p = p.advanced(by: n)
                left -= n
            }
        }
    }

    /// Reads up to (and excluding) the first newline.
    public static func readLine(_ fd: Int32) throws -> Data {
        var result = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw HelperSocketError.io(String(cString: strerror(errno)))
            }
            if n == 0 { break }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                result.append(contentsOf: buf[0..<nl])
                return result
            }
            result.append(contentsOf: buf[0..<n])
            if result.count > maxMessage {
                throw HelperSocketError.io("message too large")
            }
        }
        if result.isEmpty { throw HelperSocketError.io("connection closed") }
        return result
    }

    static func makeAddress(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let n = min(bytes.count, buf.count - 1)
            for i in 0..<n { buf[i] = bytes[i] }
            buf[n] = 0
        }
        #if os(macOS)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return addr
    }

    /// Connects to the helper, sends one request and waits for the reply.
    public static func send(_ request: HelperRequest, timeout: Double = 30,
                            path: String = XTPaths.socketPath) throws -> HelperResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperSocketError.io(String(cString: strerror(errno))) }
        defer { close(fd) }
        var addr = makeAddress(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { throw HelperSocketError.notRunning }
        setTimeouts(fd, seconds: timeout)
        var data = try XTCoding.encoder().encode(request)
        data.append(0x0A)
        try writeAll(fd, data)
        let line = try readLine(fd)
        do {
            return try XTCoding.decoder().decode(HelperResponse.self, from: line)
        } catch {
            throw HelperSocketError.badReply(String(describing: error))
        }
    }

    /// Creates a listening socket at @path with the given permissions.
    public static func listen(path: String, mode: mode_t) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperSocketError.io(String(cString: strerror(errno))) }
        var addr = makeAddress(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw HelperSocketError.io("bind: \(msg)")
        }
        chmod(path, mode)
        guard Darwin.listen(fd, 16) == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw HelperSocketError.io("listen: \(msg)")
        }
        return fd
    }
}
