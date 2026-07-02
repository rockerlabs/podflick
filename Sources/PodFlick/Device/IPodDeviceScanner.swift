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

        return IPodDevice(
            volumeURL: volume,
            name: volume.lastPathComponent,
            modelNumber: modelNumber(sysInfo: deviceDir.appendingPathComponent("SysInfo")),
            rejection: hashRequired ? .hashRequiredModel : nil,
            databaseExists: databaseExists,
            freeBytes: freeBytes(of: volume))
    }

    /// `ModelNumStr` from `iPod_Control/Device/SysInfo` — "ModelNumStr: xA146"
    /// → "A146". Display-only and absent on some devices; the support guard
    /// is the SysInfoExtended check above, not this string.
    private func modelNumber(sysInfo: URL) -> String? {
        guard let text = try? String(contentsOf: sysInfo, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0] == "ModelNumStr" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            return value.hasPrefix("x") ? String(value.dropFirst()) : value
        }
        return nil
    }

    private func freeBytes(of volume: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfFileSystem(forPath: volume.path)
        return (attributes?[.systemFreeSize] as? Int64) ?? 0
    }
}
