import CoreAudio
import Testing
@testable import TranscribeerApp

/// Pure-logic tests for `OutputDeviceClassifier`. Drive the heuristic
/// directly by feeding raw transport / data-source values, so the suite
/// doesn't need real Core Audio devices to run.
struct OutputDeviceClassifierTests {
    /// FourCC `'hdpn'` — same constant the classifier uses internally for
    /// the headphones data source.
    private static let headphonesFourCC: UInt32 = 0x68647070  // 'hdpp'? no — compute below

    /// Compute FourCC the same way the classifier does so tests don't drift.
    private static func fourCC(_ string: String) -> UInt32 {
        var value: UInt32 = 0
        for scalar in string.unicodeScalars {
            value = (value << 8) | (scalar.value & 0xFF)
        }
        return value
    }

    private static let headphones = fourCC("hdpn")
    private static let speakers = fourCC("spkr")

    @Test(
        "Built-in transport classified by data source",
        arguments: [
            (headphones, OutputDeviceClass.headphonesIsolated),
            (speakers, OutputDeviceClass.speakerLikely),
            (UInt32(0), OutputDeviceClass.speakerLikely),
        ],
    )
    func builtInClassification(dataSource: UInt32, expected: OutputDeviceClass) {
        let result = OutputDeviceClassifier.classify(
            transport: kAudioDeviceTransportTypeBuiltIn,
            dataSource: dataSource,
        )
        #expect(result == expected)
    }

    @Test("Built-in with no data source defaults to speaker")
    func builtInNoDataSource() {
        let result = OutputDeviceClassifier.classify(
            transport: kAudioDeviceTransportTypeBuiltIn,
            dataSource: nil,
        )
        #expect(result == .speakerLikely)
    }

    @Test(
        "Bluetooth transports classify as coupled earbuds",
        arguments: [
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
        ],
    )
    func bluetoothClassification(transport: UInt32) {
        let result = OutputDeviceClassifier.classify(transport: transport, dataSource: nil)
        #expect(result == .earbudsCoupled)
    }

    @Test(
        "Speaker-like transports classify as speaker",
        arguments: [
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeAirPlay,
        ],
    )
    func speakerLikeTransports(transport: UInt32) {
        let result = OutputDeviceClassifier.classify(transport: transport, dataSource: nil)
        #expect(result == .speakerLikely)
    }

    @Test(
        "Ambiguous transports classify as unknown",
        arguments: [
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeAggregate,
            UInt32(0),
        ],
    )
    func unknownTransports(transport: UInt32) {
        let result = OutputDeviceClassifier.classify(transport: transport, dataSource: nil)
        #expect(result == .unknown)
    }

    @Test(
        "AEC recommended for everything except isolated headphones",
        arguments: [
            (OutputDeviceClass.headphonesIsolated, false),
            (OutputDeviceClass.speakerLikely, true),
            (OutputDeviceClass.earbudsCoupled, true),
            (OutputDeviceClass.unknown, true),
        ],
    )
    func aecRecommended(cls: OutputDeviceClass, expected: Bool) {
        #expect(OutputDeviceClassifier.aecRecommended(for: cls) == expected)
    }
}

/// Tests for `CaptureService.resolveEchoCancellation` — the bridge from
/// `AECMode` to the boolean fed to `DualAudioRecorder`. Doesn't touch real
/// devices: passes `nil` for `outputDeviceID` to exercise the deterministic
/// fallback paths, and stubs the auto-mode case via the classifier above.
struct ResolveEchoCancellationTests {
    @Test("Manual modes ignore the output device")
    func manualModesIgnoreDevice() {
        var audio = AppConfig.AudioSettings()

        audio.aec = .on
        let onDecision = CaptureService.resolveEchoCancellation(audio: audio, outputDeviceID: nil)
        #expect(onDecision.enabled == true)
        #expect(onDecision.reason == "manual: on")

        audio.aec = .off
        let offDecision = CaptureService.resolveEchoCancellation(audio: audio, outputDeviceID: nil)
        #expect(offDecision.enabled == false)
        #expect(offDecision.reason == "manual: off")
    }

    @Test("Auto mode with no output device defaults on")
    func autoFallsBackOnWhenDeviceMissing() {
        var audio = AppConfig.AudioSettings()
        audio.aec = .auto
        let decision = CaptureService.resolveEchoCancellation(audio: audio, outputDeviceID: nil)
        #expect(decision.enabled == true)
        #expect(decision.reason.contains("no output detected"))
    }
}
