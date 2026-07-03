import Foundation

/// A mounted iPod volume, as discovered by `IPodDeviceScanner`.
///
/// Snapshot semantics: every field reflects the state at scan time; rescan
/// to refresh (mounts and free space change underneath us).
struct IPodDevice {

    /// Why a detected iPod cannot be used by PodFlick v1.
    enum Rejection: Equatable {
        /// `SysInfoExtended` is present: the device expects a hashed
        /// (hash58/72) iTunesDB — classic 6G+ / nano 3G+. An unhashed DB
        /// write would be ignored by that firmware. The proven 5G/5.5G
        /// devices lack this file (docs/itunesdb-format.md, "Scope and
        /// ground rules"); hash support is backlogged as B.8.
        case hashRequiredModel
    }

    let volumeURL: URL
    let name: String            // volume name, e.g. "IPOD"
    let modelNumber: String?    // SysInfo ModelNumStr sans "x" prefix, e.g. "A146"; display-only
    let rejection: Rejection?
    let databaseExists: Bool    // iPod_Control/iTunes/iTunesDB present at scan time
    let freeBytes: Int64
    let videoProfile: VideoProfile  // from DevicePrefs; .standard unless opted in

    // Display-only cosmetics (B.12), all read from the volume — no USB
    // protocol. Each is optional: some devices ship an empty SysInfo, and
    // the UI hides whatever is absent.
    let firmwareVersion: String?    // SysInfo visibleBuildID "0x… (N.M)" → "N.M"
    let serialNumber: String?       // SysInfo pszSerialNumber
    let hasRockbox: Bool            // /.rockbox/ directory present
    let rockboxVersion: String?     // /.rockbox/rockbox-info.txt "Version:" line
    let volumeFormat: String?       // e.g. "MS-DOS (FAT32)", from URL resource values
    let totalBytes: Int64?          // volume capacity, shown next to free space

    var isSupported: Bool { rejection == nil }

    var databaseURL: URL { Self.databaseURL(onVolume: volumeURL) }

    /// Single source of the on-device DB path; the scanner probes it too.
    static func databaseURL(onVolume volume: URL) -> URL {
        volume.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
    }

    /// Slack the free-space check reserves beyond the incoming file itself:
    /// the pre-write DB backup, the spliced DB growth, and FAT32 cluster
    /// overhead. 64 MiB dwarfs all three (the DB is single-digit MB).
    static let freeSpaceSlack: Int64 = 64 << 20

    /// Free-space check for one incoming video file.
    func canFit(fileOfSize bytes: Int64) -> Bool {
        bytes + Self.freeSpaceSlack <= freeBytes
    }
}
