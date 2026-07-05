import Foundation

/// PodFlick's per-device settings, stored as a small JSON sidecar on the
/// iPod itself (`iPod_Control/iTunes/PodFlickPrefs.json`).
///
/// On the device rather than in UserDefaults because the setting belongs
/// to the hardware: it survives across Macs, and FAT32 volumes expose no
/// reliable UUID to key a host-side store by. The firmware ignores unknown
/// files in that directory (iMazing, Rockbox and the v2-era manifest all
/// coexisted there).
///
/// Missing, corrupt or unrecognized prefs load as defaults — the safe
/// video profile — so no on-disk state can opt a 5G into the
/// black-screen 640×480 recipe.
struct DevicePrefs: Codable, Equatable {
    var videoProfile: VideoProfile = .standard

    static func url(onVolume volume: URL) -> URL {
        volume.appendingPathComponent("iPod_Control/iTunes/PodFlickPrefs.json")
    }

    static func load(volumeURL: URL) -> DevicePrefs {
        guard let data = try? Data(contentsOf: url(onVolume: volumeURL)),
              let prefs = try? JSONDecoder().decode(DevicePrefs.self, from: data)
        else { return DevicePrefs() }
        return prefs
    }

    func save(volumeURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(onVolume: volumeURL),
                                       options: .atomic)
    }
}
