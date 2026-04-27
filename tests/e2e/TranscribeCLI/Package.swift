// swift-tools-version: 6.0
import PackageDescription

// Tiny CLIs used by the e2e harness and STT-comparison benchmark. Keeping them
// in a separate package avoids test-only dependencies on the GUI target.
//
// Tools built from this package:
//   - transcribe-cli : WhisperKit transcription (text or JSON with timestamps)
//   - diarize-cli    : SpeakerKit (Pyannote) diarization → JSON speaker segments
let package = Package(
    name: "TranscribeCLI",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
    ],
    targets: [
        .executableTarget(
            name: "transcribe-cli",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/transcribe-cli",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "diarize-cli",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ],
            path: "Sources/diarize-cli",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
