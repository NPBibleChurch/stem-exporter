import Foundation

/// A min/max summary of a session's audio, one bucket per horizontal pixel-ish
/// unit, used to draw every waveform in the app.
///
/// Peaks are stored at unity gain. A gain change doesn't need a re-analysis: the
/// views scale the stored values, which is what makes the waveform (and its red
/// clipped regions) update live as the dB field is dragged.
public struct PeakData: Codable, Sendable, Hashable {
    /// Peaks for one track, normalised to -1.0...1.0.
    public struct Track: Codable, Sendable, Hashable {
        public var min: [Float]
        public var max: [Float]
        /// Largest absolute sample seen anywhere in the track, at unity.
        public var absolutePeak: Float

        public init(min: [Float], max: [Float], absolutePeak: Float) {
            self.min = min
            self.max = max
            self.absolutePeak = absolutePeak
        }
    }

    public var sampleRate: Double
    public var totalFrames: Int64
    public var framesPerBucket: Int64
    public var tracks: [Track]
    /// A rough mono downmix of every track, for the trim scrubber.
    public var mix: Track

    public init(sampleRate: Double, totalFrames: Int64, framesPerBucket: Int64, tracks: [Track], mix: Track) {
        self.sampleRate = sampleRate
        self.totalFrames = totalFrames
        self.framesPerBucket = framesPerBucket
        self.tracks = tracks
        self.mix = mix
    }

    public var bucketCount: Int { mix.min.count }
    public var trackCount: Int { tracks.count }

    /// Peaks for a stem, which may be one track or a linked stereo pair. A pair is
    /// summarised as the envelope of both sides, since they share one gain anyway.
    public func envelope(forTracks trackNumbers: [Int]) -> Track? {
        let indices = trackNumbers.map { $0 - 1 }.filter { $0 >= 0 && $0 < tracks.count }
        guard let first = indices.first else { return nil }
        guard indices.count > 1 else { return tracks[first] }

        var mins = tracks[first].min
        var maxs = tracks[first].max
        var peak = tracks[first].absolutePeak
        for index in indices.dropFirst() {
            let other = tracks[index]
            peak = Swift.max(peak, other.absolutePeak)
            for i in 0..<Swift.min(mins.count, other.min.count) {
                mins[i] = Swift.min(mins[i], other.min[i])
                maxs[i] = Swift.max(maxs[i], other.max[i])
            }
        }
        return Track(min: mins, max: maxs, absolutePeak: peak)
    }

    /// The bucket range covering a frame range, for drawing only the trimmed part.
    public func bucketRange(fromFrame: Int64, toFrame: Int64) -> Range<Int> {
        guard framesPerBucket > 0, bucketCount > 0 else { return 0..<0 }
        let lower = Int(max(0, fromFrame / framesPerBucket))
        let upper = Int(min(Int64(bucketCount), (toFrame + framesPerBucket - 1) / framesPerBucket))
        return lower..<Swift.max(lower, upper)
    }
}

public extension PeakData.Track {
    /// True when applying `gainDB` would push this track into the rails.
    func clips(atGainDB gainDB: Double) -> Bool {
        Double(absolutePeak) * SampleCodec.linearGain(dB: gainDB) >= 0.999
    }

    /// The headroom left before clipping, in dB. Negative means already over.
    func headroomDB(atGainDB gainDB: Double) -> Double {
        let level = Double(absolutePeak) * SampleCodec.linearGain(dB: gainDB)
        guard level > 0 else { return .infinity }
        return -20 * log10(level)
    }

    /// True when the loudest sample in this track never reaches `thresholdDB` —
    /// an input that was patched but never used, or one carrying only hiss.
    func isSilent(belowDB thresholdDB: Double) -> Bool {
        Double(absolutePeak) < pow(10.0, thresholdDB / 20.0)
    }

    static var empty: Self { .init(min: [], max: [], absolutePeak: 0) }
}
