import Foundation

/// Finds mounted iPods: volumes carrying an `iPod_Control` directory.
///
/// The volumes root is injectable so tests can point it at a temp-dir tree
/// of fake volumes; the default is the real mount table under `/Volumes`.
struct IPodDeviceScanner {

    var volumesDirectory = URL(fileURLWithPath: "/Volumes", isDirectory: true)

    private let fileManager = FileManager.default

    /// Every iPod mounted right now, sorted by volume name.
    func scan() -> [IPodDevice] {
        let volumes = (try? fileManager.contentsOfDirectory(
            at: volumesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return volumes.compactMap(inspect(volume:)).sorted { $0.name < $1.name }
    }

    /// One volume → a device snapshot, or nil when it is not an iPod.
    func inspect(volume: URL) -> IPodDevice? {
        let control = volume.appendingPathComponent("iPod_Control", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: control.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let deviceDir = control.appendingPathComponent("Device", isDirectory: true)
        let hashRequired = fileManager.fileExists(
            atPath: deviceDir.appendingPathComponent("SysInfoExtended").path)
        let databaseExists = fileManager.fileExists(
            atPath: IPodDevice.databaseURL(onVolume: volume).path)
        let sysInfo = keyValueFields(at: deviceDir.appendingPathComponent("SysInfo"))
        let rockbox = rockbox(onVolume: volume)
        // NSURL caches volume resource values per instance (purged only at
        // run-loop checkpoints); drop the cache so a same-tick re-inspect of
        // a stored URL — e.g. the pre-copy free-space re-check — reads fresh.
        var volume = volume
        volume.removeAllCachedResourceValues()
        let resources = try? volume.resourceValues(forKeys:
            [.volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
             .volumeAvailableCapacityKey])

        return IPodDevice(
            volumeURL: volume,
            name: volume.lastPathComponent,
            modelNumber: modelNumber(sysInfo: sysInfo),
            rejection: hashRequired ? .hashRequiredModel : nil,
            databaseExists: databaseExists,
            freeBytes: (resources?.volumeAvailableCapacity).map(Int64.init) ?? 0,
            videoProfile: DevicePrefs.load(volumeURL: volume).videoProfile,
            firmwareVersion: firmwareVersion(sysInfo: sysInfo),
            serialNumber: sysInfo["pszSerialNumber"],
            hasRockbox: rockbox.present,
            rockboxVersion: rockbox.version,
            volumeFormat: resources?.volumeLocalizedFormatDescription,
            totalBytes: (resources?.volumeTotalCapacity).map(Int64.init))
    }

    /// One-pass parse of a "Key: value" line file (`SysInfo`,
    /// `rockbox-info.txt`) into a field map; unreadable file → empty map.
    /// Everything read this way is display-only and absent on some devices
    /// (DMRD ships an empty SysInfo); the support guard is the
    /// SysInfoExtended check above, not these files.
    private func keyValueFields(at url: URL) -> [String: String] {
        // Cap the read: these files are well under a KB on real devices, but
        // they live on an untrusted mounted volume — a huge (or corrupt) file
        // must not be slurped whole into memory during a scan.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            fields[parts[0].trimmingCharacters(in: .whitespaces)] = value
        }
        return fields
    }

    /// "ModelNumStr: xA146" → "A146".
    private func modelNumber(sysInfo: [String: String]) -> String? {
        guard let value = sysInfo["ModelNumStr"] else { return nil }
        return value.hasPrefix("x") ? String(value.dropFirst()) : value
    }

    /// "visibleBuildID: 0x04C08000 (1.2.1)" → "1.2.1". Only the parenthesized
    /// human-readable version is worth showing; a bare hex build ID is not.
    private func firmwareVersion(sysInfo: [String: String]) -> String? {
        guard let value = sysInfo["visibleBuildID"],
              let open = value.firstIndex(of: "("),
              let close = value.firstIndex(of: ")"), open < close else { return nil }
        let version = value[value.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        return version.isEmpty ? nil : version
    }

    /// Rockbox lives in `/.rockbox/`; its build stamps a "Version:" line
    /// into `rockbox-info.txt`. Directory without the file (or without the
    /// line) still counts as installed — version is a bonus.
    private func rockbox(onVolume volume: URL) -> (present: Bool, version: String?) {
        let dir = volume.appendingPathComponent(".rockbox", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return (false, nil) }
        let info = keyValueFields(at: dir.appendingPathComponent("rockbox-info.txt"))
        return (true, info["Version"])
    }
}
