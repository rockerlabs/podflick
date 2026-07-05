import Foundation

/// Per-device conversion target.
///
/// `.standard` is the 5G hardware-decoder envelope and plays on both
/// generations. `.high` is the 5.5G envelope (reference
/// `convert_to_ipod.sh`); a real 5G decodes it to a BLACK screen (B.5.1
/// smoke, 2026-07-04), so it is strictly a per-device opt-in and never a
/// default. Generation cannot be auto-detected reliably — the operator's
/// 5.5G-era device has an EMPTY `Device/SysInfo` — hence the explicit
/// setting, persisted on the device by `DevicePrefs`.
enum VideoProfile: String, Codable, CaseIterable {
    /// 320×240, H.264 Baseline L1.3, ≤768 kbps — safe on 5G and 5.5G.
    case standard
    /// 640×480, H.264 Baseline L3.0, ≤1.5 Mbps — 5.5G only.
    case high

    // The knobs that differ between the two proven recipes; the rest of
    // the ffmpeg invocation is shared (IPodVideoConverter).

    var h264Level: String {
        switch self {
        case .standard: "1.3"
        case .high: "3.0"
        }
    }

    /// Fit-inside bounds for the scale filter (aspect ratio preserved).
    var maxWidth: Int {
        switch self {
        case .standard: 320
        case .high: 640
        }
    }

    var maxHeight: Int {
        switch self {
        case .standard: 240
        case .high: 480
        }
    }

    var videoBitrate: String {
        switch self {
        case .standard: "700k"
        case .high: "1200k"
        }
    }

    var videoMaxrate: String {
        switch self {
        case .standard: "768k"
        case .high: "1500k"
        }
    }

    var videoBufsize: String {
        switch self {
        case .standard: "1536k"
        case .high: "3000k"
        }
    }

    /// Menu label; must scream the risk at the point of choice.
    var displayName: String {
        switch self {
        case .standard: "320×240 (safe)"
        case .high: "640×480 (5.5G only)"
        }
    }
}
