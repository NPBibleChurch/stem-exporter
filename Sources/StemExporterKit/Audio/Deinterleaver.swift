import Foundation

/// The stems being pulled out of one interleaved source block, flattened so the
/// hot loop indexes contiguous memory instead of walking arrays of arrays.
struct StemLayout {
    /// Source channel indices, 0-based, all stems end to end.
    var channels: [Int32] = []
    /// Where each stem's channels start in `channels`.
    var starts: [Int] = []
    /// How many channels each stem takes.
    var widths: [Int] = []
    var gains: [Double] = []

    var count: Int { widths.count }

    init(stems: [StemPlan]) {
        for stem in stems {
            starts.append(channels.count)
            widths.append(stem.trackNumbers.count)
            gains.append(SampleCodec.linearGain(dB: stem.gainDB))
            channels.append(contentsOf: stem.trackNumbers.map { Int32($0 - 1) })
        }
    }
}

/// Clip bookkeeping for one worker: how many samples hit the rails per stem, and
/// the earliest frame (block-relative) where it happened.
struct ClipTally {
    var counts: [Int64]
    var firstFrames: [Int64]

    init(stemCount: Int) {
        counts = [Int64](repeating: 0, count: stemCount)
        firstFrames = [Int64](repeating: -1, count: stemCount)
    }

    mutating func reset() {
        for i in counts.indices { counts[i] = 0; firstFrames[i] = -1 }
    }
}

/// Splits one interleaved source block into per-stem output buffers.
///
/// The source frame is wider than the stems that come out of it — 32 channels in,
/// one or two per stem — so the order of the loops decides how much memory traffic
/// this costs. Walking the whole block once per stem touches every cache line
/// thirty-odd times and only uses three bytes of each. Instead the block is cut
/// into tiles small enough to sit in L1, and every stem is served out of a tile
/// while it's still hot: the source is pulled from memory once, not once per stem.
///
/// Callers hand out disjoint frame ranges to run this on several cores at once.
enum Deinterleaver {

    /// Frames per tile, chosen so a tile of source stays inside L1 (128 KB on the
    /// cores this runs on) alongside the output rows it feeds.
    static func tileFrames(bytesPerFrame: Int) -> Int {
        max(64, 48 * 1024 / max(bytesPerFrame, 1))
    }

    /// De-interleave `frames` of `source` into `destinations`.
    ///
    /// Destination pointers are the base of each stem's buffer for the whole block;
    /// this writes only the rows in `frames`, so parallel callers don't overlap.
    static func run(
        source: UnsafeRawPointer,
        frames: Range<Int>,
        format: AudioFormat,
        layout: StemLayout,
        destinations: UnsafePointer<UnsafeMutableRawPointer>,
        tally: inout ClipTally
    ) {
        let bytesPerFrame = format.bytesPerFrame
        let sampleBytes = format.bytesPerSample
        let isFloat = format.isFloat
        let fullScale = format.fullScale
        let tile = tileFrames(bytesPerFrame: bytesPerFrame)
        let stemCount = layout.count
        guard stemCount > 0, !frames.isEmpty else { return }

        layout.channels.withUnsafeBufferPointer { channelBuf in
        layout.starts.withUnsafeBufferPointer { startBuf in
        layout.widths.withUnsafeBufferPointer { widthBuf in
        layout.gains.withUnsafeBufferPointer { gainBuf in
        tally.counts.withUnsafeMutableBufferPointer { countBuf in
        tally.firstFrames.withUnsafeMutableBufferPointer { firstBuf in
            let channels = channelBuf.baseAddress!
            let starts = startBuf.baseAddress!
            let widths = widthBuf.baseAddress!
            let gains = gainBuf.baseAddress!
            let counts = countBuf.baseAddress!
            let firsts = firstBuf.baseAddress!

            var tileStart = frames.lowerBound
            while tileStart < frames.upperBound {
                let tileEnd = min(tileStart + tile, frames.upperBound)
                for stem in 0..<stemCount {
                    let width = widths[stem]
                    let map = channels + starts[stem]
                    let dst = destinations[stem]
                    let gain = gains[stem]
                    let unity = (gain == 1.0)

                    // `sampleBytes` and `mode` reach the kernel as literals here, so
                    // the per-sample width switch folds away instead of branching
                    // on every one of the billions of samples in a session.
                    switch (isFloat, sampleBytes, unity) {
                    case (false, 2, true):  kernel(source, dst, tileStart, tileEnd, bytesPerFrame, 2, map, width, gain, fullScale, .intUnity, counts + stem, firsts + stem)
                    case (false, 2, false): kernel(source, dst, tileStart, tileEnd, bytesPerFrame, 2, map, width, gain, fullScale, .intGain, counts + stem, firsts + stem)
                    case (false, 3, true):  kernel(source, dst, tileStart, tileEnd, bytesPerFrame, 3, map, width, gain, fullScale, .intUnity, counts + stem, firsts + stem)
                    case (false, 3, false): kernel(source, dst, tileStart, tileEnd, bytesPerFrame, 3, map, width, gain, fullScale, .intGain, counts + stem, firsts + stem)
                    case (false, 4, true):  kernel(source, dst, tileStart, tileEnd, bytesPerFrame, 4, map, width, gain, fullScale, .intUnity, counts + stem, firsts + stem)
                    case (false, 4, false): kernel(source, dst, tileStart, tileEnd, bytesPerFrame, 4, map, width, gain, fullScale, .intGain, counts + stem, firsts + stem)
                    case (true, 4, _):      kernel(source, dst, tileStart, tileEnd, bytesPerFrame, 4, map, width, gain, fullScale, .float, counts + stem, firsts + stem)
                    case (true, 8, _):      kernel(source, dst, tileStart, tileEnd, bytesPerFrame, 8, map, width, gain, fullScale, .float, counts + stem, firsts + stem)
                    default:
                        kernel(source, dst, tileStart, tileEnd, bytesPerFrame, sampleBytes, map, width, gain, fullScale,
                               isFloat ? .float : (unity ? .intUnity : .intGain), counts + stem, firsts + stem)
                    }
                }
                tileStart = tileEnd
            }
        }}}}}}
    }

    enum Mode { case intUnity, intGain, float }

    /// One stem, one tile. Force-inlined so the caller's literal width and mode
    /// specialise it.
    @inline(__always)
    private static func kernel(
        _ source: UnsafeRawPointer,
        _ destination: UnsafeMutableRawPointer,
        _ frameStart: Int,
        _ frameEnd: Int,
        _ bytesPerFrame: Int,
        _ sampleBytes: Int,
        _ map: UnsafePointer<Int32>,
        _ width: Int,
        _ gain: Double,
        _ fullScale: Double,
        _ mode: Mode,
        _ clipCount: UnsafeMutablePointer<Int64>,
        _ firstClip: UnsafeMutablePointer<Int64>
    ) {
        let stemStride = width * sampleBytes
        // Integer full scale is a power of two, so the rail test is exact in Int64 —
        // and a comparison per sample beats a conversion to Double per sample.
        let railThreshold = Int64(fullScale) - 1
        var clipped: Int64 = 0
        var first: Int64 = -1

        for frame in frameStart..<frameEnd {
            let srcRow = source.advanced(by: frame * bytesPerFrame)
            let dstRow = destination.advanced(by: frame * stemStride)
            for channel in 0..<width {
                let p = srcRow.advanced(by: Int(map[channel]) * sampleBytes)
                let q = dstRow.advanced(by: channel * sampleBytes)
                switch mode {
                case .float:
                    var value = SampleCodec.readFloat(p, bytes: sampleBytes) * gain
                    if value >= 1.0 || value <= -1.0 {
                        value = value > 0 ? 1.0 : -1.0
                        clipped += 1
                        if first < 0 { first = Int64(frame) }
                    }
                    SampleCodec.writeFloat(value, to: q, bytes: sampleBytes)
                case .intUnity:
                    let raw = SampleCodec.readInt(p, bytes: sampleBytes)
                    // Already at the rails in the source: worth telling the user
                    // about, even though we didn't cause it.
                    if abs(Int64(raw)) >= railThreshold {
                        clipped += 1
                        if first < 0 { first = Int64(frame) }
                    }
                    SampleCodec.writeInt(raw, to: q, bytes: sampleBytes)
                case .intGain:
                    let raw = SampleCodec.readInt(p, bytes: sampleBytes)
                    let result = SampleCodec.scaleAndClamp(raw, gain: gain, maxMagnitude: fullScale)
                    if result.clipped {
                        clipped += 1
                        if first < 0 { first = Int64(frame) }
                    }
                    SampleCodec.writeInt(result.value, to: q, bytes: sampleBytes)
                }
            }
        }

        if clipped > 0 {
            clipCount.pointee += clipped
            if firstClip.pointee < 0 { firstClip.pointee = first }
        }
    }
}
