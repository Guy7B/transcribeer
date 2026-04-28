import CaptureCore
import CoreAudio
import Foundation

/// Coarse acoustic-coupling classification for an output device.
///
/// Used by `CaptureService` to decide whether to engage Voice Processing IO
/// (acoustic echo cancellation) when `AECMode == .auto`. The categories are
/// intentionally broad — we only need to know whether speakers and the mic
/// share an acoustic path, not exactly what device is plugged in.
enum OutputDeviceClass: Equatable, Sendable {
    /// Wired headphones (3.5 mm jack, USB headsets, Lightning) — the
    /// transducer is sealed against the user's ear. No acoustic feedback to
    /// the laptop mic, so AEC is unnecessary and only degrades fidelity.
    case headphonesIsolated

    /// In-room speakers: built-in laptop speakers, BT speakers, HDMI/
    /// DisplayPort monitor speakers, AirPlay receivers. Mic and speaker
    /// share the room, so without AEC the mic track will pick up everything
    /// the speakers play.
    case speakerLikely

    /// Bluetooth earbuds (AirPods, Beats, similar). The transducer is closer
    /// to the user's mouth than open speakers, but still leaks into the
    /// device's own mic — and Apple's Voice Processing chain on the AirPods
    /// is what makes them sound clean on Zoom calls. Treat as needing AEC.
    case earbudsCoupled

    /// USB / FireWire / Thunderbolt / aggregate / unknown transports. Could
    /// be anything from a studio interface to a USB headset. We can't
    /// reliably tell, so caller should fall back to a safe default (AEC on).
    case unknown
}

/// Pure heuristic that maps a Core Audio output device to an acoustic-
/// coupling class. Stateless — easy to drive from tests by feeding the
/// transport / data-source pair directly.
enum OutputDeviceClassifier {
    /// Convenience wrapper that resolves the transport + data source for the
    /// supplied device, then routes through the pure decision function.
    /// Returns `.unknown` if Core Audio refuses to answer (e.g. the device
    /// disappeared between the picker selection and the recording start).
    static func classify(deviceID: AudioDeviceID) -> OutputDeviceClass {
        guard let transport = AudioDevices.transportType(deviceID: deviceID) else {
            return .unknown
        }
        let dataSource = AudioDevices.outputDataSource(deviceID: deviceID)
        return classify(transport: transport, dataSource: dataSource)
    }

    /// Pure decision function. Takes the raw values that Core Audio returns
    /// and decides which acoustic-coupling bucket the device falls into.
    /// Extracted so tests can pin inputs without driving real hardware.
    static func classify(transport: UInt32, dataSource: UInt32?) -> OutputDeviceClass {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // The built-in audio device on Apple Silicon Macs covers both
            // the speakers and the headphone jack via a single AudioDeviceID.
            // Distinguish them via the active data source.
            return dataSource == headphonesDataSource ? .headphonesIsolated : .speakerLikely

        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            // Conservative: most Bluetooth output paired with a Mac is
            // earbuds/headphones with bidirectional coupling. We could try
            // to be smarter (e.g. look at the device class), but the cost
            // of a wrong "off" decision (echo on the mic track) is much
            // worse than a wrong "on" decision (slightly compressed output).
            return .earbudsCoupled

        case kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeAirPlay:
            return .speakerLikely

        default:
            // USB / FireWire / Thunderbolt / aggregate / Continuity /
            // anything else — too ambiguous to commit a side either way.
            return .unknown
        }
    }

    /// Whether echo cancellation is recommended for a given class. Wraps the
    /// "are speakers and mic acoustically coupled?" decision so callers
    /// don't have to know the enum cases.
    static func aecRecommended(for cls: OutputDeviceClass) -> Bool {
        switch cls {
        case .headphonesIsolated:
            return false
        case .speakerLikely, .earbudsCoupled, .unknown:
            return true
        }
    }

    /// FourCC `'hdpn'` — Core Audio's "Headphones" data source identifier.
    /// Computed at type-init time so the run-time decision path stays
    /// allocation-free.
    private static let headphonesDataSource: UInt32 = fourCC("hdpn")

    private static func fourCC(_ string: String) -> UInt32 {
        var value: UInt32 = 0
        for scalar in string.unicodeScalars {
            value = (value << 8) | (scalar.value & 0xFF)
        }
        return value
    }
}
