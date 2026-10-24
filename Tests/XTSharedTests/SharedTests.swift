import XCTest
@testable import XTShared

final class SharedTests: XCTestCase {
    func testMountName() {
        XCTAssertEqual(NTFSNames.mountName(for: "My/Disk", bsdName: "disk4s1"), "My-Disk")
        XCTAssertEqual(NTFSNames.mountName(for: "  ", bsdName: "disk4s1"), "NTFS disk4s1")
        XCTAssertEqual(NTFSNames.mountName(for: nil, bsdName: "disk9s2"), "NTFS disk9s2")
        XCTAssertEqual(NTFSNames.mountName(for: "Ổ đĩa Windows", bsdName: "disk4s1"), "Ổ đĩa Windows")
    }

    func testWholeDisk() {
        XCTAssertEqual(NTFSNames.wholeDisk(of: "disk4s1"), "disk4")
        XCTAssertEqual(NTFSNames.wholeDisk(of: "disk12s3"), "disk12")
        XCTAssertEqual(NTFSNames.wholeDisk(of: "disk3"), "disk3")
    }

    func testBSDValidation() {
        XCTAssertTrue(NTFSNames.isValidBSDName("disk4s1"))
        XCTAssertTrue(NTFSNames.isValidBSDName("disk4"))
        XCTAssertFalse(NTFSNames.isValidBSDName("disk4s1; rm -rf /"))
        XCTAssertFalse(NTFSNames.isValidBSDName("../disk4"))
        XCTAssertFalse(NTFSNames.isValidBSDName("sda1"))
    }

    func testPrefsKey() {
        XCTAssertEqual(NTFSNames.prefsKey(uuid: "abc-def", bsdName: "disk4s1", label: "X"), "ABC-DEF")
        XCTAssertEqual(NTFSNames.prefsKey(uuid: nil, bsdName: "disk4s1", label: "X"), "disk4s1|X")
    }

    func testConfigDecodingIsLenient() throws {
        let json = #"{"driverEnabled": false, "profile": "turbo", "unknownKey": 1}"#
        let c = try XTCoding.decoder().decode(EngineConfig.self, from: Data(json.utf8))
        XCTAssertFalse(c.driverEnabled)
        XCTAssertEqual(c.profile, .turbo)
        XCTAssertEqual(c.dirtyPolicy, .verifyBeforeMount)
        XCTAssertTrue(c.windowsNames)
        XCTAssertEqual(c.backend, .automatic)
    }

    func testManagedMountWithoutBackendDecodes() throws {
        let json = #"{"bsdName":"disk4s1","devicePath":"/dev/rdisk4s1","mountPoint":"/Volumes/D","volumeName":"D","readOnly":false,"profile":"balanced","mountedAt":0}"#
        let m = try XTCoding.decoder().decode(ManagedMount.self, from: Data(json.utf8))
        XCTAssertNil(m.backend)
        XCTAssertEqual(m.profile, .balanced)
    }

    func testRequestRoundTrip() throws {
        let req = HelperRequest(command: .erase, bsdName: "disk4s1", label: "Data", format: .ntfs)
        let data = try XTCoding.encoder().encode(req)
        let back = try XTCoding.decoder().decode(HelperRequest.self, from: data)
        XCTAssertEqual(back.command, .erase)
        XCTAssertEqual(back.format, .ntfs)
        XCTAssertEqual(back.label, "Data")
    }

    func testMountEntryParsing() {
        let e = MountEntry(from: "/dev/rdisk4s1", on: "/Volumes/Data", fsType: "macfuse",
                           readOnly: false, noBrowse: false, totalBytes: 0, freeBytes: 0)
        XCTAssertEqual(e.bsdName, "disk4s1")
        XCTAssertTrue(e.isXT)
        XCTAssertEqual(e.driverName, "XT NTFS")
        let p = MountEntry(from: "/dev/disk4s1", on: "/Volumes/Data", fsType: "ufsd_NTFS",
                           readOnly: false, noBrowse: false, totalBytes: 0, freeBytes: 0)
        XCTAssertFalse(p.isXT)
        XCTAssertEqual(p.driverName, "Paragon NTFS")
    }

    func testMountTableReadable() {
        // The root file system is always mounted.
        XCTAssertTrue(MountTable.entries().contains { $0.on == "/" })
    }
}
