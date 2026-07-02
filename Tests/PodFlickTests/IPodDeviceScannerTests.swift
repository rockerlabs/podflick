import XCTest
@testable import PodFlick

/// Scanner tests run against a temp-dir tree of fake volumes — no real
/// device needed. Layouts mirror the operator's proven 5G/5.5G iPods
/// (docs/itunesdb-format.md): iPod_Control/{Device/SysInfo, iTunes/iTunesDB}.
final class IPodDeviceScannerTests: XCTestCase {

    private var volumesRoot: URL!
    private var scanner: IPodDeviceScanner!

    override func setUpWithError() throws {
        volumesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodFlickVolumes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: volumesRoot,
                                                withIntermediateDirectories: true)
        scanner = IPodDeviceScanner(volumesDirectory: volumesRoot)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: volumesRoot)
    }

    /// Builds a fake mounted volume; nil `sysInfo` omits the file entirely.
    @discardableResult
    private func makeVolume(_ name: String,
                            iPodControl: Bool = true,
                            sysInfo: String? = "ModelNumStr: xA146\n",
                            sysInfoExtended: Bool = false,
                            database: Bool = true) throws -> URL {
        let volume = volumesRoot.appendingPathComponent(name)
        let fm = FileManager.default
        try fm.createDirectory(at: volume, withIntermediateDirectories: true)
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
        if database {
            let iTunes = control.appendingPathComponent("iTunes")
            try fm.createDirectory(at: iTunes, withIntermediateDirectories: true)
            try Data("mhbd".utf8).write(to: iTunes.appendingPathComponent("iTunesDB"))
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
