import Foundation

/// Builds the peak cache for a session, once, on import.
///
/// This is a preview pass, not the export pass: rather than decoding every one of
/// the billions of samples in a multi-gigabyte session, it reads a contiguous
/// window out of each bucket and seeks over the rest. That keeps import to a few
/// seconds on a 12 GB session while still being representative enough to scrub
/// against and to show where a channel is running hot. Exact clip detection
/// happens during export, where every sample really is touched.
///
/// Buckets don't depend on each other, so they're analysed a chunk at a time
/// across every core: the reads go through `pread`, which doesn't share a file
/// offset, and each chunk owns the slice of the output it writes.
public struct PeakAnalyzer: Sendable {

    /// How many buckets to build across the whole session.
    public var bucketCount: Int
    /// Frames actually read from each bucket. Buckets shorter than this are read whole.
    public var framesSampledPerBucket: Int64

    public init(bucketCount: Int = 4000, framesSampledPerBucket: Int64 = 4096) {
        self.bucketCount = max(16, bucketCount)
        self.framesSampledPerBucket = max(64, framesSampledPerBucket)
    }

    public struct Progress: Sendable {
        public var fractionComplete: Double
    }

    public func analyze(
        session: Session,
        progress: (@Sendable (Progress) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> PeakData {
        let format = session.format
        let parts = session.includedParts
        let totalFrames = session.totalFrames
        let channelCount = format.channelCount

        guard totalFrames > 0, channelCount > 0 else {
            return PeakData(
                sampleRate: format.sampleRate,
                totalFrames: 0,
                framesPerBucket: 1,
                tracks: Array(repeating: .empty, count: max(channelCount, 0)),
                mix: .empty
            )
        }

        let buckets = min(bucketCount, max(1, Int(totalFrames)))
        let framesPerBucket = max(1, totalFrames / Int64(buckets))

        // Channel-major and flat, so a worker's buckets are a contiguous run in
        // each channel's row and the rows come out ready to hand to PeakData.
        var mins = [Float](repeating: 0, count: channelCount * buckets)
        var maxs = [Float](repeating: 0, count: channelCount * buckets)
        var mixMin = [Float](repeating: 0, count: buckets)
        var mixMax = [Float](repeating: 0, count: buckets)

        // Descriptors stay open for the whole pass so we aren't reopening a file
        // per bucket, and `pread` lets every worker share them.
        let handles: [ReadFD?] = parts.map { ReadFD(url: $0.url) }

        let bytesPerFrame = format.bytesPerFrame
        let sampleBytes = format.bytesPerSample
        let isFloat = format.isFloat
        // Full scale is a power of two, so scaling by the reciprocal is exact.
        let invFullScale = 1.0 / format.fullScale
        let readCapacity = Int(framesSampledPerBucket) * bytesPerFrame

        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunkBuckets = max(1, (buckets + cores * 4 - 1) / (cores * 4))
        let chunks = (buckets + chunkBuckets - 1) / chunkBuckets

        // Each worker keeps its own peaks and its own progress tally; the locked
        // section runs once per chunk, not once per bucket.
        var chunkPeaks = [Float](repeating: 0, count: chunks * channelCount)
        var chunkMixPeak = [Float](repeating: 0, count: chunks)
        let state = AnalysisState()

        mins.withUnsafeMutableBufferPointer { minBuf in
        maxs.withUnsafeMutableBufferPointer { maxBuf in
        mixMin.withUnsafeMutableBufferPointer { mixMinBuf in
        mixMax.withUnsafeMutableBufferPointer { mixMaxBuf in
        chunkPeaks.withUnsafeMutableBufferPointer { peakBuf in
        chunkMixPeak.withUnsafeMutableBufferPointer { mixPeakBuf in
            let minBase = minBuf.baseAddress!
            let maxBase = maxBuf.baseAddress!
            let mixMinBase = mixMinBuf.baseAddress!
            let mixMaxBase = mixMaxBuf.baseAddress!
            let peakBase = peakBuf.baseAddress!
            let mixPeakBase = mixPeakBuf.baseAddress!

            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                if state.isStopped { return }
                if isCancelled?() == true { state.stop(); return }

                let block = UnsafeMutableRawPointer.allocate(byteCount: max(readCapacity, 1), alignment: 64)
                defer { block.deallocate() }
                let scratch = UnsafeMutablePointer<Float>.allocate(capacity: channelCount * 2)
                defer { scratch.deallocate() }
                let bucketMin = scratch
                let bucketMax = scratch + channelCount
                let peaks = peakBase + chunk * channelCount
                var mixPeak: Float = 0

                let first = chunk * chunkBuckets
                let last = min(first + chunkBuckets, buckets)

                for bucket in first..<last {
                    let bucketStart = Int64(bucket) * framesPerBucket
                    let bucketEnd = bucket == buckets - 1 ? totalFrames : bucketStart + framesPerBucket
                    let readFrames = min(framesSampledPerBucket, bucketEnd - bucketStart)
                    guard readFrames > 0 else { continue }

                    // A bucket can straddle a part boundary; read whatever each part supplies.
                    var frameCursor = bucketStart
                    var framesRemaining = readFrames
                    var have = false
                    var mixLow: Float = 0
                    var mixHigh: Float = 0

                    while framesRemaining > 0 {
                        guard let partIndex = parts.firstIndex(where: {
                            frameCursor >= $0.startOffsetInSession && frameCursor < $0.endOffsetInSession
                        }), let handle = handles[partIndex] else { break }
                        let part = parts[partIndex]

                        let frameInPart = frameCursor - part.startOffsetInSession
                        let available = min(framesRemaining, part.frameCount - frameInPart)
                        guard available > 0 else { break }

                        let byteOffset = part.dataOffset + frameInPart * Int64(bytesPerFrame)
                        let got = handle.readFully(
                            into: block, count: Int(available) * bytesPerFrame, at: byteOffset
                        )
                        let framesRead = got / bytesPerFrame
                        guard framesRead > 0 else { break }

                        Self.scan(
                            block, framesRead, bytesPerFrame, sampleBytes, channelCount,
                            isFloat, invFullScale,
                            bucketMin, bucketMax, peaks,
                            &have, &mixLow, &mixHigh, &mixPeak
                        )

                        frameCursor += Int64(framesRead)
                        framesRemaining -= Int64(framesRead)
                    }

                    if have {
                        for channel in 0..<channelCount {
                            minBase[channel * buckets + bucket] = bucketMin[channel]
                            maxBase[channel * buckets + bucket] = bucketMax[channel]
                        }
                        mixMinBase[bucket] = mixLow
                        mixMaxBase[bucket] = mixHigh
                    }
                }

                mixPeakBase[chunk] = mixPeak
                state.finish(chunk: last - first, of: buckets, progress: progress)
            }
        }}}}}}

        if state.isStopped { throw CancellationError() }
        progress?(Progress(fractionComplete: 1))

        var absPeaks = [Float](repeating: 0, count: channelCount)
        var mixPeak: Float = 0
        for chunk in 0..<chunks {
            mixPeak = Swift.max(mixPeak, chunkMixPeak[chunk])
            for channel in 0..<channelCount {
                absPeaks[channel] = Swift.max(absPeaks[channel], chunkPeaks[chunk * channelCount + channel])
            }
        }

        let tracks = (0..<channelCount).map { channel -> PeakData.Track in
            let row = channel * buckets
            return PeakData.Track(
                min: Array(mins[row..<(row + buckets)]),
                max: Array(maxs[row..<(row + buckets)]),
                absolutePeak: absPeaks[channel]
            )
        }
        return PeakData(
            sampleRate: format.sampleRate,
            totalFrames: totalFrames,
            framesPerBucket: framesPerBucket,
            tracks: tracks,
            mix: PeakData.Track(min: mixMin, max: mixMax, absolutePeak: mixPeak)
        )
    }

    /// Fold one block of interleaved frames into a bucket's running min/max.
    ///
    /// Force-inlined with the sample width as a literal, so the width switch inside
    /// the codec folds away rather than branching on every sample.
    @inline(__always)
    private static func scan(
        _ base: UnsafeRawPointer,
        _ framesRead: Int,
        _ bytesPerFrame: Int,
        _ sampleBytes: Int,
        _ channelCount: Int,
        _ isFloat: Bool,
        _ invFullScale: Double,
        _ bucketMin: UnsafeMutablePointer<Float>,
        _ bucketMax: UnsafeMutablePointer<Float>,
        _ peaks: UnsafeMutablePointer<Float>,
        _ have: inout Bool,
        _ mixLow: inout Float,
        _ mixHigh: inout Float,
        _ mixPeak: inout Float
    ) {
        @inline(__always)
        func loop(_ width: Int, _ float: Bool) {
            for frame in 0..<framesRead {
                let row = base.advanced(by: frame * bytesPerFrame)
                var frameLow: Float = 0
                var frameHigh: Float = 0
                let firstFrame = !have
                for channel in 0..<channelCount {
                    let p = row.advanced(by: channel * width)
                    let value: Float = float
                        ? Float(SampleCodec.readFloat(p, bytes: width))
                        : Float(Double(SampleCodec.readInt(p, bytes: width)) * invFullScale)
                    if firstFrame {
                        bucketMin[channel] = value
                        bucketMax[channel] = value
                    } else {
                        if value < bucketMin[channel] { bucketMin[channel] = value }
                        if value > bucketMax[channel] { bucketMax[channel] = value }
                    }
                    let magnitude = abs(value)
                    if magnitude > peaks[channel] { peaks[channel] = magnitude }
                    // The summary is the envelope across channels, not their average:
                    // averaging 32 inputs where only a few are playing flattens the
                    // session into a line you can't scrub against.
                    if channel == 0 {
                        frameLow = value
                        frameHigh = value
                    } else {
                        if value < frameLow { frameLow = value }
                        if value > frameHigh { frameHigh = value }
                    }
                }
                if firstFrame {
                    mixLow = frameLow
                    mixHigh = frameHigh
                    have = true
                } else {
                    if frameLow < mixLow { mixLow = frameLow }
                    if frameHigh > mixHigh { mixHigh = frameHigh }
                }
                mixPeak = Swift.max(mixPeak, Swift.max(abs(frameLow), abs(frameHigh)))
            }
        }

        switch (isFloat, sampleBytes) {
        case (false, 2): loop(2, false)
        case (false, 3): loop(3, false)
        case (false, 4): loop(4, false)
        case (true, 4): loop(4, true)
        case (true, 8): loop(8, true)
        default: loop(sampleBytes, isFloat)
        }
    }
}

/// Cancellation and progress shared by the bucket workers.
private final class AnalysisState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var done = 0

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    func finish(chunk count: Int, of total: Int, progress: (@Sendable (PeakAnalyzer.Progress) -> Void)?) {
        guard let progress else { return }
        lock.lock()
        done += count
        let fraction = Double(done) / Double(total)
        lock.unlock()
        progress(PeakAnalyzer.Progress(fractionComplete: fraction))
    }
}

/// Finds the first and last points where the session is actually making sound,
/// so "Snap to Silence" can nudge the handles past dead air at the head and tail.
public enum SilenceDetector {

    /// Returns the frame range that excludes leading and trailing silence, using
    /// the mono summary and a threshold in dBFS.
    public static func contentRange(in peaks: PeakData, thresholdDB: Double = -50) -> (inFrame: Int64, outFrame: Int64)? {
        let threshold = Float(pow(10.0, thresholdDB / 20.0))
        let buckets = peaks.bucketCount
        guard buckets > 0 else { return nil }

        func isLoud(_ index: Int) -> Bool {
            max(abs(peaks.mix.min[index]), abs(peaks.mix.max[index])) > threshold
        }

        guard let first = (0..<buckets).first(where: isLoud),
              let last = (0..<buckets).reversed().first(where: isLoud) else {
            return nil
        }

        let inFrame = Int64(first) * peaks.framesPerBucket
        let outFrame = min(peaks.totalFrames, Int64(last + 1) * peaks.framesPerBucket)
        guard outFrame > inFrame else { return nil }
        return (inFrame, outFrame)
    }

    /// The default level below which a channel counts as never used.
    ///
    /// Well under the -50 dBFS "dead air" threshold on purpose: dead air is a gap
    /// in a track that is otherwise in use, whereas this decides a track isn't
    /// worth a file at all. A patched-but-idle input sits in preamp hiss around
    /// -70 dBFS; anything a player actually made lands far above -60.
    public static let defaultEmptyTrackThresholdDB: Double = -60

    /// Track numbers (1-based) whose loudest sample never reaches `thresholdDB` —
    /// inputs that were patched but never used.
    ///
    /// Judged over the whole session rather than the trim, so the decision is made
    /// once on import and doesn't shuffle around underneath the user as they drag
    /// the handles. Peaks come from the sampled analysis pass, so a single stray
    /// click can be missed; that's why this only pre-ticks a checkbox rather than
    /// dropping the track outright.
    public static func emptyTracks(
        in peaks: PeakData,
        thresholdDB: Double = defaultEmptyTrackThresholdDB
    ) -> Set<Int> {
        var empty = Set<Int>()
        for (index, track) in peaks.tracks.enumerated() where track.isSilent(belowDB: thresholdDB) {
            empty.insert(index + 1)
        }
        return empty
    }
}
