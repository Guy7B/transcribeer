import Foundation

/// A segment with speaker assignment.
struct LabeledSegment {
    let start: Double
    let end: Double
    let speaker: String
    let text: String
}

/// Ports assign_speakers() and format_output() from Python transcribe.py.
enum TranscriptFormatter {

    /// Assign a speaker label to each whisper segment based on overlap
    /// with diarization segments. Falls back to midpoint containment.
    static func assignSpeakers(
        whisperSegments: [TranscriptSegment],
        diarSegments: [DiarSegment]
    ) -> [LabeledSegment] {
        whisperSegments.map { ws in
            let wsMid = (ws.start + ws.end) / 2
            var bestSpeaker = "UNKNOWN"
            var bestOverlap = 0.0

            for ds in diarSegments {
                let overlap = max(0, min(ws.end, ds.end) - max(ws.start, ds.start))
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = ds.speaker
                }
                if bestOverlap == 0 && ds.start <= wsMid && wsMid <= ds.end {
                    bestSpeaker = ds.speaker
                }
            }

            return LabeledSegment(
                start: ws.start, end: ws.end,
                speaker: bestSpeaker, text: ws.text
            )
        }
    }

    /// Format labeled segments: rename speakers, merge consecutive
    /// same-speaker lines, produce `[MM:SS -> MM:SS] Speaker N: text`.
    static func format(_ segments: [LabeledSegment]) -> String {
        guard !segments.isEmpty else { return "" }

        // Build stable speaker name mapping (first-seen order)
        var speakerMap: [String: String] = [:]
        var counter = 1
        for seg in segments where seg.speaker != "UNKNOWN" {
            if speakerMap[seg.speaker] == nil {
                speakerMap[seg.speaker] = "Speaker \(counter)"
                counter += 1
            }
        }
        speakerMap["UNKNOWN"] = "???"

        // Merge consecutive same-speaker segments
        var merged: [(start: Double, end: Double, speaker: String, text: String)] = []
        for seg in segments {
            let friendly = speakerMap[seg.speaker] ?? seg.speaker
            if let last = merged.last, last.speaker == friendly {
                let prev = merged.removeLast()
                merged.append((prev.start, seg.end, friendly, prev.text + " " + seg.text))
            } else {
                merged.append((seg.start, seg.end, friendly, seg.text))
            }
        }

        return merged.map { seg in
            let ts = "[\(formatTimestamp(seg.start)) -> \(formatTimestamp(seg.end))]"
            return "\(ts) \(seg.speaker): \(seg.text)"
        }.joined(separator: "\n")
    }

    /// Formats seconds as MM:SS.
    static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
