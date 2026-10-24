import Foundation
import XTShared

// xtntfsd - XT NTFS privileged helper (LaunchDaemon).

if CommandLine.arguments.contains("--version") {
    print(XTBuild.fullVersion)
    exit(0)
}

guard getuid() == 0 else {
    FileHandle.standardError.write("xtntfsd must run as root (it is started by launchd).\n".data(using: .utf8)!)
    exit(1)
}

signal(SIGPIPE, SIG_IGN)
setvbuf(stderr, nil, _IOLBF, 0)

let helper = Helper()
helper.start()

let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
termSource.setEventHandler {
    // Mounts stay up: ntfs-3g runs independently of the helper.
    Log.info("Helper stopping")
    unlink(XTPaths.socketPath)
    exit(0)
}
termSource.resume()

dispatchMain()
