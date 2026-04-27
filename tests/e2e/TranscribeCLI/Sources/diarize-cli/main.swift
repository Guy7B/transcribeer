import Foundation
import SpeakerKit
import WhisperKit

// Usage: diarize-cli <audio> [--num-speakers N] [--models-dir <path>]
//
// Runs Pyannote speaker diarization via SpeakerKit and prints a JSON array of
// {start, end, speaker} segments to stdout. Progress/info go to stderr so a
// caller can capture clean JSON via shell redirection.
//
// Matches the behavior of gui/Sources/TranscribeerCore/DiarizationService.swift
// so the comparison harness sees the exact same diarization the production
// pipeline uses.

struct Args {
    var audio: URL
    var numSpeakers: Int?
    var modelsDir: URL
}

func parseArgs() -> Args {
    let argv = CommandLine.arguments
    guard argv.count >= 2 else {
        fputs("Usage: diarize-cli <audio> [--num-speakers N] [--models-dir <path>]\n", stderr)
        exit(2)
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let defaultModelsDir = home.appendingPathComponent(".transcribeer/models", isDirectory: true)

    var numSpeakers: Int?
    var modelsDir = defaultModelsDir
    var positional: String?

    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--num-speakers":
            i += 1
            guard i < argv.count, let n = Int(argv[i]), n > 0 else {
                fputs("--num-speakers requires a positive integer\n", stderr)
                exit(2)
            }
            numSpeakers = n
        case "--models-dir":
            i += 1
            guard i < argv.count else { fputs("--models-dir requires value\n", stderr); exit(2) }
            modelsDir = URL(fileURLWithPath: (argv[i] as NSString).expandingTildeInPath, isDirectory: true)
        default:
            positional = a
        }
        i += 1
    }

    guard let path = positional else {
        fputs("Missing audio path\n", stderr)
        exit(2)
    }
    return Args(
        audio: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
        numSpeakers: numSpeakers,
        modelsDir: modelsDir
    )
}

let args = parseArgs()

try? FileManager.default.createDirectory(at: args.modelsDir, withIntermediateDirectories: true)

fputs("[diarize-cli] audio=\(args.audio.path)\n", stderr)
fputs("[diarize-cli] num_speakers=\(args.numSpeakers.map(String.init) ?? "auto")\n", stderr)

let loadStart = Date()
let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: args.audio.path)
fputs("[diarize-cli] loaded \(audioArray.count) samples in \(Int(-loadStart.timeIntervalSinceNow))s\n", stderr)

guard !audioArray.isEmpty else {
    fputs("[diarize-cli] empty audio\n", stderr)
    print("[]")
    exit(0)
}

let config = PyannoteConfig(
    download: true,
    load: true,
    verbose: false,
    logLevel: .none
)

let kitStart = Date()
let kit = try await SpeakerKit(config)
fputs("[diarize-cli] SpeakerKit loaded in \(Int(-kitStart.timeIntervalSinceNow))s\n", stderr)

let diarStart = Date()
let options = PyannoteDiarizationOptions(numberOfSpeakers: args.numSpeakers)
let result = try await kit.diarize(audioArray: audioArray, options: options)
fputs("[diarize-cli] diarized in \(Int(-diarStart.timeIntervalSinceNow))s\n", stderr)
fputs("[diarize-cli] segments=\(result.segments.count)\n", stderr)

// Match DiarizationService.speakerLabel(_:): use "Speaker <id>" when present,
// "Unknown" otherwise. The harness will rename these sequentially later.
func labelFor(_ info: SpeakerInfo) -> String {
    if let id = info.speakerId { return "Speaker \(id)" }
    return "Unknown"
}

struct Segment: Encodable {
    let start: Double
    let end: Double
    let speaker: String
}

let segments = result.segments.map { seg in
    Segment(
        start: Double(seg.startTime),
        end: Double(seg.endTime),
        speaker: labelFor(seg.speaker)
    )
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(segments)
if let text = String(data: data, encoding: .utf8) {
    print(text)
}
