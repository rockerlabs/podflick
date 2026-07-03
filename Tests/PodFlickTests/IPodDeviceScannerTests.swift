import XCTest
@testable import PodFlick

/// Scanner tests run against a temp-dir tree of fake volumes — no real
/// device needed. Layouts mirror the operator's proven 5G/5.5G iPods
/// (docs/itunesdb-format.md): iPod_Control/{Device/SysInfo, iTunes/iTunesDB}.
final class IPodDeviceScannerTests: XCTestCase {

    private var volumesRoot: URL!
    private var scanner: IPodDeviceScanner!

    override func setUpWithError() throws {
        volumesRoot = try makeTempDirectory(prefix: "PodFlickVolumes")
        scanner = IPodDeviceScanner(volumesDirectory: volumesRoot)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: volumesRoot)
    }

    /// Builds a fake mounted volume; nil `sysInfo` omits the file entirely.
    /// `rockbox` creates `/.rockbox/`; non-nil `rockboxInfo` adds
    /// `rockbox-info.txt` with that content.
    @discardableResult
    private func makeVolume(_ name: String,
                            iPodControl: Bool = true,
                            sysInfo: String? = "ModelNumStr: xA146\n",
                            sysInfoExtended: Bool = false,
                            database: Bool = true,
                            prefsJSON: String? = nil,
                            rockbox: Bool = false,
                            rockboxInfo: String? = nil) throws -> URL {
        let volume = volumesRoot.appendingPathComponent(name)
        let fm = FileManager.default
        try fm.createDirectory(at: volume, withIntermediateDirectories: true)
        if rockbox || rockboxInfo != nil {
            let rockboxDir = volume.appendingPathComponent(".rockbox")
            try fm.createDirectory(at: rockboxDir, withIntermediateDirectories: true)
            if let rockboxInfo {
                try rockboxInfo.write(
                    to: rockboxDir.appendingPathComponent("rockbox-info.txt"),
                    atomically: true, encoding: .utf8)
            }
        }
        guard iPodControl else { return volume }

        let control = volume.appendingPathComponent("iPod_Control")
        let deviceDir = control.appendingPathComponent("Device")
        try fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)
        if let sysInfo {
            try sysInfo.write(to: deviceDir.appendingPathComponent("SysInfo"),
                              atomically: true, encoding: .utf8)
        }
        if sysInfoExtended {
            try Data("<plist/>".utf8).write(
                to: deviceDir.appendingPathComponent("SysInfoExtended"))
        }
        let iTunes = control.appendingPathComponent("iTunes")
        try fm.createDirectory(at: iTunes, withIntermediateDirectories: true)
        if database {
            try Data("mhbd".utf8).write(to: iTunes.appendingPathComponent("iTunesDB"))
        }
        if let prefsJSON {
            try prefsJSON.write(to: DevicePrefs.url(onVolume: volume),
                                atomically: true, encoding: .utf8)
        }
        return volume
    }

    // MARK: - Detection

    func testScanFindsOnlyIPodVolumes() throws {
        try makeVolume("IPOD")
        try makeVolume("Macintosh HD", iPodControl: false)
        try makeVolume("Backup Drive", iPodControl: false)

        let devices = scanner.scan()
        XCTAssertEqual(devices.map(\.name), ["IPOD"])
        XCTAssertEqual(devices.first?.volumeURL.lastPathComponent, "IPOD")
    }

    func testScanSortsMultipleIPodsByName() throws {
        try makeVolume("ZUNE_JOKE")
        try makeVolume("APOD")

        XCTAssertEqual(scanner.scan().map(\.name), ["APOD", "ZUNE_JOKE"])
    }

    func testScanOfMissingVolumesRootIsEmpty() {
        let gone = IPodDeviceScanner(volumesDirectory:
            volumesRoot.appendingPathComponent("nonexistent"))
        XCTAssertEqual(gone.scan().count, 0)
    }

    func testIPodControlAsPlainFileIsNotAnIPod() throws {
        let volume = try makeVolume("FAKE", iPodControl: false)
        try Data().write(to: volume.appendingPathComponent("iPod_Control"))

        XCTAssertNil(scanner.inspect(volume: volume))
    }

    // MARK: - Generation guard

    func testSupportedDeviceWithoutSysInfoExtended() throws {
        try makeVolume("IPOD")

        let device = try XCTUnwrap(scanner.scan().first)
        XCTAssertNil(device.rejection)
        XCTAssertTrue(device.isSupported)
    }

    func testSysInfoExtendedRejectsHashRequiredModel() throws {
        try makeVolume("CLASSIC6G", sysInfoExtended: true)

        let device = try XCTUnwrap(scanner.scan().first)
        XCTAssertEqual(device.rejection, .hashRequiredModel)
        XCTAssertFalse(device.isSupported)
    }

    // MARK: - SysInfo model number (display-only)

    func testModelNumberParsedAndXPrefixStripped() throws {
        try makeVolume("IPOD", sysInfo: """
            BoardHwName: iPod Q23
            ModelNumStr: xA146
            pszSerialNumber: ABC123
            """)

        XCTAssertEqual(scanner.scan().first?.modelNumber, "A146")
    }

    func testModelNumberWithoutXPrefixKeptVerbatim() throws {
        try makeVolume("IPOD", sysInfo: "ModelNumStr: MA146\n")

        XCTAssertEqual(scanner.scan().first?.modelNumber, "MA146")
    }

    func testMissingSysInfoStillDetectsDeviceWithoutModel() throws {
        try makeVolume("IPOD", sysInfo: nil)

        let device = try XCTUnwrap(scanner.scan().first)
        XCTAssertNil(device.modelNumber)
        XCTAssertTrue(device.isSupported)
    }

    // MARK: - Device-info cosmetics (B.12)

    func testFirmwareVersionAndSerialParsedFromSysInfo() throws {
        try makeVolume("IPOD", sysInfo: """
            BoardHwName: iPod Q23
            pszSerialNumber: JQ6250BFV9K
            ModelNumStr: xA146
            buildID: 0x04C08000 (4.1)
            visibleBuildID: 0x04C08000 (1.2.1)
            """)

        let device = try XCTUnwrap(scanner.scan().first)
        XCTAssertEqual(device.firmwareVersion, "1.2.1")
        XCTAssertEqual(device.serialNumber, "JQ6250BFV9K")
    }

    func testFirmwareVersionWithoutParenthesesIsHidden() throws {
        try makeVolume("IPOD", sysInfo: "visibleBuildID: 0x04C08000\n")

        XCTAssertNil(scanner.scan().first?.firmwareVersion)
    }

    /// DMRD ships a zero-byte SysInfo: every cosmetic field stays nil and
    /// the device still works.
    func testEmptySysInfoLeavesAllCosmeticFieldsNil() throws {
        try makeVolume("IPOD", sysInfo: "")

        let device = try XCTUnwrap(scanner.scan().first)
        XCTAssertNil(device.firmwareVersion)
        XCTAssertNil(device.serialNumber)
        XCTAssertNil(device.modelNumber)
        XCTAssertTrue(device.isSupported)
    }

    // MARK: - Rockbox detection

    func testRockboxDirectoryWithVersionFile() throws {
        try makeVolume("IPOD", rockboxInfo: """
            Version: rockbox-3.15
            Target: ipodvideo
            """)

        let device = try XCTUnwrap(scanner.scan().first)
        XCTAssertTrue(device.hasRockbox)
        XCTAssertEqual(device.rockboxVersion, "rockbox-3.15")
    }

    func testRockboxDirectoryWithoutInfoFileStillCounts() throws {
        try makeVolume("IPOD", rockbox: true)

        let device = try XCTUnwrap(scanner.scan().first)
        XCTAssertTrue(device.hasRockbox)
        XCTAssertNil(device.rockboxVersion)
    }

    func testRockboxInfoWithoutVersionLineGivesNilVersion() throws {
        try makeVolume("IPOD", rockboxInfo: "Target: ipodvideo\n")

        let device = try XCTUnwrap(scanner.scan().first)
        XCTAssertTrue(device.hasRockbox)
        XCTAssertNil(device.rockboxVersion)
    }

    func testNoRockboxDirectory() throws {
        try makeVolume("IPOD")

        let device = try XCTUnwrap(scanner.scan().first)
        XCTAssertFalse(device.hasRockbox)
        XCTAssertNil(device.rockboxVersion)
    }

    // MARK: - Volume format and capacity

    /// Fake volumes are temp-dir subtrees, so the resource values resolve
    /// against the host filesystem — we can only assert they are populated,
    /// not their exact text.
    func testVolumeFormatAndCapacityReadFromResourceValues() throws {
        try makeVolume("IPOD")

        let device = try XCTUnwrap(scanner.scan().first)
        XCTAssertNotNil(device.volumeFormat)
        XCTAssertGreaterThan(try XCTUnwrap(device.totalBytes), 0)
    }

    // MARK: - Video profile (DevicePrefs sidecar)

    func testNoPrefsFileDefaultsToStandardProfile() throws {
        try makeVolume("IPOD")

        XCTAssertEqual(scanner.scan().first?.videoProfile, .standard)
    }

    func testPrefsFileOptsDeviceIntoHighProfile() throws {
        try makeVolume("IPOD", prefsJSON: #"{"videoProfile":"high"}"#)

        XCTAssertEqual(scanner.scan().first?.videoProfile, .high)
    }

    /// A 5G must never end up on the black-screen recipe because of a
    /// damaged or newer-app prefs file — anything unreadable is .standard.
    func testCorruptOrUnknownPrefsFallBackToStandardProfile() throws {
        try makeVolume("CORRUPT", prefsJSON: "not json at all")
        try makeVolume("UNKNOWN", prefsJSON: #"{"videoProfile":"ultra8k"}"#)

        let profiles = scanner.scan().map(\.videoProfile)
        XCTAssertEqual(profiles, [.standard, .standard])
    }

    func testPrefsRoundTripThroughSaveAndRescan() throws {
        let volume = try makeVolume("IPOD")
        var prefs = DevicePrefs.load(volumeURL: volume)
        XCTAssertEqual(prefs, DevicePrefs())

        prefs.videoProfile = .high
        try prefs.save(volumeURL: volume)

        XCTAssertEqual(DevicePrefs.load(volumeURL: volume).videoProfile, .high)
        XCTAssertEqual(scanner.scan().first?.videoProfile, .high)
    }

    // MARK: - Database presence

    func testDatabasePresenceAndURL() throws {
        try makeVolume("IPOD")
        try makeVolume("RESTORED", database: false)

        let devices = scanner.scan()
        let withDB = try XCTUnwrap(devices.first { $0.name == "IPOD" })
        let withoutDB = try XCTUnwrap(devices.first { $0.name == "RESTORED" })

        XCTAssertTrue(withDB.databaseExists)
        XCTAssertFalse(withoutDB.databaseExists)
        XCTAssertEqual(withDB.databaseURL.path,
                       withDB.volumeURL.path + "/iPod_Control/iTunes/iTunesDB")
    }

    // MARK: - Free space

    func testFreeSpaceSnapshotAndFitCheck() throws {
        try makeVolume("IPOD")

        let device = try XCTUnwrap(scanner.scan().first)
        // The fake volume sits on the local filesystem, which has SOME room.
        XCTAssertGreaterThan(device.freeBytes, 0)
        XCTAssertTrue(device.canFit(fileOfSize: 1))
        // No filesystem can fit a file bigger than its free space + slack.
        XCTAssertFalse(device.canFit(fileOfSize: device.freeBytes))
    }
}
