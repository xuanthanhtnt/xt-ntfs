import Foundation
import IOKit
import XTShared

/// Speed of the USB link a disk is connected through, read from the I/O
/// Registry. A slow cable, port or enclosure caps every driver: USB 2.0
/// tops out around 40 MB/s, so it is worth telling the user.
enum LinkSpeed {
    /// Bits per second of the USB link of @bsd's disk, nil when the disk is
    /// not on USB or the speed is unknown.
    static func bitsPerSecond(bsd: String) -> Int64? {
        let whole = NTFSNames.wholeDisk(of: bsd)
        guard NTFSNames.isValidBSDName(whole),
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, whole) else { return nil }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }

        // The nearest USB device above the disk is the enclosure itself.
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        func search(_ key: String) -> Int64? {
            (IORegistryEntrySearchCFProperty(media, kIOServicePlane, key as CFString,
                                             kCFAllocatorDefault, options) as? NSNumber)?.int64Value
        }
        if let bps = search("UsbLinkSpeed"), bps > 0 { return bps }
        // IOUSBHostDevice "USBSpeed": 1 full, 2 high, 3 super, 4 super+.
        if let code = search("USBSpeed") {
            switch code {
            case 1: return 12_000_000
            case 2: return 480_000_000
            case 3: return 5_000_000_000
            case 4: return 10_000_000_000
            default: break
            }
        }
        // Legacy IOUSBDevice "Device Speed": 0 low, 1 full, 2 high, 3 super.
        if let code = search("Device Speed") {
            switch code {
            case 1: return 12_000_000
            case 2: return 480_000_000
            case 3: return 5_000_000_000
            default: break
            }
        }
        return nil
    }

    /// "USB 2.0 · 480 Mb/s", "USB 3 · 5 Gb/s", ...
    static func describe(_ bps: Int64) -> String {
        let generation: String
        switch bps {
        case ..<100_000_000: generation = "USB 1.1"
        case ..<1_000_000_000: generation = "USB 2.0"
        case ..<20_000_000_000: generation = "USB 3"
        case ..<40_000_000_000: generation = "USB 3.2 Gen 2x2"
        default: generation = "USB4"
        }
        let rate = bps >= 1_000_000_000
            ? String(format: "%g Gb/s", Double(bps) / 1_000_000_000)
            : String(format: "%g Mb/s", Double(bps) / 1_000_000)
        return "\(generation) · \(rate)"
    }

    /// USB 2.0 and slower links cap the disk at roughly 40 MB/s.
    static func isSlow(_ bps: Int64) -> Bool { bps < 1_000_000_000 }
}
