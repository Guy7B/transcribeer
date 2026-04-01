import AVFoundation
import ScreenCaptureKit

public class AudioCapture: NSObject {
    public static let shared = AudioCapture()
    public override init() {}

    private var stream: SCStream?
    private var writer: WAVWriter?

    // Thread-safe accepting flag
    private let acceptingLock = NSLock()
    private var _accepting = true
    private var accepting: Bool {
        get { acceptingLock.withLock { _accepting } }
        set { acceptingLock.withLock { _accepting = newValue } }
    }

    private let dstFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    // Converter is created lazily from the first real sample buffer, not from a
    // hardcoded format — macOS version may deliver audio at different rates/layouts.
    private let converterLock = NSLock()
    private var converter: AVAudioConverter?
    private var lastSrcFormat: AVAudioFormat?

    public func start(writer: WAVWriter) async throws {
        self.writer = writer
        self.accepting = true
        converterLock.withLock {
            converter = nil
            lastSrcFormat = nil
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        try s.addStreamOutput(
            self, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "audio.capture"))
        try await s.startCapture()
        self.stream = s
    }

    public func stopAccepting() { accepting = false }

    public func stop() {
        stopAccepting()
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    // MARK: - Private helpers

    private func converterFor(_ srcFormat: AVAudioFormat) -> AVAudioConverter? {
        return converterLock.withLock { () -> AVAudioConverter? in
            if let c = converter, lastSrcFormat?.isEqual(srcFormat) == true { return c }
            guard let c = AVAudioConverter(from: srcFormat, to: dstFormat) else {
                return nil
            }
            converter = c
            lastSrcFormat = srcFormat
            return c
        }
    }
}

public enum CaptureError: Error {
    case noDisplay
}

extension AudioCapture: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, accepting else { return }

        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return }

        // Read the actual audio format from the sample buffer — do not assume
        // a fixed format because macOS may deliver at a different sample rate.
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: fmtDesc)

        guard let conv = converterFor(srcFormat) else { return }

        // Query the exact ABL size needed, then allocate.
        var ablSizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil)
        guard ablSizeNeeded > 0 else { return }

        let ablPtr = UnsafeMutableRawPointer.allocate(
            byteCount: ablSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablPtr.deallocate() }
        let abl = ablPtr.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockRef: CMBlockBuffer?
        let fillStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: ablSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockRef)
        guard fillStatus == noErr else { return }

        // Copy ABL data into an AVAudioPCMBuffer via its own buffer list.
        guard let srcBuf = AVAudioPCMBuffer(
            pcmFormat: srcFormat,
            frameCapacity: AVAudioFrameCount(numFrames)) else { return }
        srcBuf.frameLength = AVAudioFrameCount(numFrames)

        let dstABL = srcBuf.mutableAudioBufferList
        withUnsafeMutablePointer(to: &abl.pointee.mBuffers) { srcStart in
            let srcBuffers = UnsafeBufferPointer<AudioBuffer>(
                start: srcStart, count: Int(abl.pointee.mNumberBuffers))
            let dstMutableABL = UnsafeMutableAudioBufferListPointer(dstABL)
            for (i, srcEntry) in srcBuffers.enumerated() {
                guard i < dstMutableABL.count,
                      let srcData = srcEntry.mData,
                      let dstData = dstMutableABL[i].mData else { continue }
                let copyBytes = min(Int(srcEntry.mDataByteSize), Int(dstMutableABL[i].mDataByteSize))
                memcpy(dstData, srcData, copyBytes)
            }
        }

        // Convert to 16 kHz mono.
        let ratio = dstFormat.sampleRate / srcFormat.sampleRate
        let outFrames = AVAudioFrameCount(ceil(Double(numFrames) * ratio)) + 1
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outFrames) else { return }

        var convError: NSError?
        conv.convert(to: dstBuf, error: &convError) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuf
        }
        guard convError == nil, dstBuf.frameLength > 0 else { return }

        // Float32 → Int16, clamped per-sample.
        let floats = dstBuf.floatChannelData![0]
        let count = Int(dstBuf.frameLength)
        var int16s = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let clamped = max(-1.0, min(1.0, floats[i]))
            int16s[i] = Int16(clamped * 32767)
        }
        writer?.append(int16s)
    }
}
