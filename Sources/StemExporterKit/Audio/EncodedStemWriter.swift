#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Writes one stem through a system codec — AIFF, FLAC, Apple Lossless or AAC.
///
/// The export engine hands every writer the same thing: blocks of interleaved PCM
/// in the source's own depth. This one converts each block to the deinterleaved
/// float the encoder wants, a chunk at a time out of a buffer allocated once, so a
/// long session costs no more memory than a short one. Nothing is bundled and
/// nothing is shelled out to: the codecs are the ones already in macOS.
///
/// Not internally synchronised — one writer per stem, driven from that stem's
/// serial queue.
final class EncodedStemWriter: StemWriter {

    /// Frames converted per pass. Small enough to stay cache-friendly, large
    /// enough that the per-call overhead of the encoder disappears.
    private static let chunkFrames = 16 * 1024

    let url: URL

    private let sourceFormat: AudioFormat
    private var file: AVAudioFile?
    private let buffer: AVAudioPCMBuffer
    /// Bytes of a frame that arrived split across two blocks.
    private var pending = Data()
    private var frames: Int64 = 0
    private var bytes: Int64 = 0
    private var finalized = false

    init(url: URL, format: AudioFormat, encoding: ExportEncoding) throws {
        self.url = url
        self.sourceFormat = format

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }

        let settings = Self.settings(for: encoding, format: format)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw ExportError.encoderUnavailable(encoding.summary)
        }
        self.file = file

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(Self.chunkFrames)
        ) else {
            self.file = nil
            try? fm.removeItem(at: url)
            throw ExportError.encoderUnavailable(encoding.summary)
        }
        self.buffer = buffer
    }

    // MARK: Settings

    static func settings(for encoding: ExportEncoding, format: AudioFormat) -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]

        switch encoding.format {
        case .wav, .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = format.isFloat ? 32 : format.bitDepth
            settings[AVLinearPCMIsFloatKey] = format.isFloat
            settings[AVLinearPCMIsBigEndianKey] = true
            settings[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = losslessBitDepth(for: format)
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = losslessBitDepth(for: format)
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = aacBitsPerSecond(
                kbps: encoding.lossyBitrateKbps,
                channelCount: format.channelCount
            )
        }
        return settings
    }

    /// FLAC and ALAC take 16, 20, 24 or 32 bits. Anything else — 8-bit sources,
    /// float sources — is mapped to the nearest depth they accept.
    static func losslessBitDepth(for format: AudioFormat) -> Int {
        if format.isFloat { return 24 }
        if format.bitDepth <= 16 { return 16 }
        if format.bitDepth <= 24 { return 24 }
        return 32
    }

    /// AAC won't take an arbitrary rate: a mono stem tops out well below a stereo
    /// one, and asking for more than the encoder offers fails the whole export.
    static func aacBitsPerSecond(kbps: Int, channelCount: Int) -> Int {
        let ceiling = channelCount >= 2 ? 320 : 256
        return min(ExportEncoding.clampBitrate(kbps), ceiling) * 1000
    }

    // MARK: Writing

    func write(_ data: Data) throws {
        guard !data.isEmpty, let file else { return }

        var payload = data
        if !pending.isEmpty {
            pending.append(data)
            payload = pending
            pending = Data()
        }

        let bytesPerFrame = max(sourceFormat.bytesPerFrame, 1)
        let wholeFrames = payload.count / bytesPerFrame
        let consumed = wholeFrames * bytesPerFrame
        if consumed < payload.count {
            pending = payload.subdata(in: consumed..<payload.count)
        }
        guard wholeFrames > 0 else { return }

        try payload.withUnsafeBytes { raw -> Void in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < wholeFrames {
                let chunk = min(Self.chunkFrames, wholeFrames - offset)
                fill(buffer, from: base, firstFrame: offset, frames: chunk)
                try file.write(from: buffer)
                frames += Int64(chunk)
                offset += chunk
            }
        }
    }

    /// Deinterleave `frames` of source PCM into the float buffer the encoder reads.
    private func fill(
        _ buffer: AVAudioPCMBuffer,
        from base: UnsafeRawPointer,
        firstFrame: Int,
        frames: Int
    ) {
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let channels = buffer.floatChannelData else { return }

        let channelCount = sourceFormat.channelCount
        let bytesPerFrame = sourceFormat.bytesPerFrame
        let bytesPerSample = sourceFormat.bytesPerSample

        for channel in 0..<channelCount {
            let destination = channels[channel]
            var cursor = base + (firstFrame * bytesPerFrame) + (channel * bytesPerSample)
            for frame in 0..<frames {
                let value = SampleCodec.readNormalized(cursor, format: sourceFormat)
                destination[frame] = Float(min(max(value, -1.0), 1.0))
                cursor += bytesPerFrame
            }
        }
    }

    var byteCount: Int64 { bytes }

    @discardableResult
    func finalize() throws -> Int64 {
        guard !finalized else { return frames }
        finalized = true

        // Releasing the file is what closes it: the encoder flushes its tail and
        // patches the container's sizes on the way out, so the size on disk is
        // only trustworthy afterwards.
        file = nil

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return frames
    }

    func cancelAndRemove() {
        finalized = true
        file = nil
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
