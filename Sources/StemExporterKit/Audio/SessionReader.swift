import Foundation

/// Random-access reader over a session's virtual timeline.
///
/// The parts are separate files, but callers ask for a frame range on the session
/// as a whole and get back one contiguous block — the reader works out which part
/// each frame lives in and stitches across the boundary. Handles stay open so
/// scrubbing doesn't reopen a file on every seek.
public final class SessionReader: @unchecked Sendable {

    public let session: Session
    private var handles: [URL: FileHandle] = [:]
    /// Reads are serialised: playback produces buffers on its own queue while the
    /// main actor may still be asking for a scrub preview.
    private let lock = NSLock()

    public init(session: Session) {
        self.session = session
    }

    deinit {
        handles.values.forEach { try? $0.close() }
    }

    public var format: AudioFormat { session.format }
    public var totalFrames: Int64 { session.totalFrames }

    /// Interleaved source frames starting at `fromFrame`. Returns fewer frames
    /// than asked for at the end of the session.
    public func read(fromFrame: Int64, frames: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try locked_read(fromFrame: fromFrame, frames: frames)
    }

    private func locked_read(fromFrame: Int64, frames: Int) throws -> Data {
        guard frames > 0, fromFrame >= 0, fromFrame < session.totalFrames else { return Data() }
        let bytesPerFrame = format.bytesPerFrame
        var output = Data()
        output.reserveCapacity(frames * bytesPerFrame)

        var cursor = fromFrame
        var remaining = Int64(min(Int64(frames), session.totalFrames - fromFrame))

        while remaining > 0 {
            guard let part = session.includedParts.first(where: {
                cursor >= $0.startOffsetInSession && cursor < $0.endOffsetInSession
            }) else { break }

            let handle = try handle(for: part.url)
            let frameInPart = cursor - part.startOffsetInSession
            let available = min(remaining, part.frameCount - frameInPart)
            guard available > 0 else { break }

            try handle.seek(toOffset: UInt64(part.dataOffset + frameInPart * Int64(bytesPerFrame)))
            guard let block = try handle.read(upToCount: Int(available) * bytesPerFrame), !block.isEmpty else { break }

            output.append(block)
            let framesRead = Int64(block.count / bytesPerFrame)
            guard framesRead > 0 else { break }
            cursor += framesRead
            remaining -= framesRead
        }

        return output
    }

    /// A mono downmix of the requested range, as float samples — what playback and
    /// the scrub preview need, without pushing 32 live channels through an engine.
    public func readMonoDownmix(fromFrame: Int64, frames: Int) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let block = try locked_read(fromFrame: fromFrame, frames: frames)
        let bytesPerFrame = format.bytesPerFrame
        let bytesPerSample = format.bytesPerSample
        let channels = format.channelCount
        let frameCount = block.count / max(bytesPerFrame, 1)
        guard frameCount > 0 else { return [] }

        var result = [Float](repeating: 0, count: frameCount)
        let scale = Float(1.0 / format.fullScale)
        let isFloat = format.isFloat

        block.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channels {
                    let p = base.advanced(by: frame * bytesPerFrame + channel * bytesPerSample)
                    if isFloat {
                        sum += Float(SampleCodec.readFloat(p, bytes: bytesPerSample))
                    } else {
                        sum += Float(SampleCodec.readInt(p, bytes: bytesPerSample)) * scale
                    }
                }
                result[frame] = sum / Float(channels)
            }
        }
        return result
    }

    private func handle(for url: URL) throws -> FileHandle {
        if let existing = handles[url] { return existing }
        let opened = try FileHandle(forReadingFrom: url)
        handles[url] = opened
        return opened
    }
}
