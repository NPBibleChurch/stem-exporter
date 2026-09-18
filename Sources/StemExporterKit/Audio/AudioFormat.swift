import Foundation

/// The PCM layout of a WAV file, as read from its `fmt ` chunk.
///
/// Nothing here is hardcoded to 32 channels — the channel count is whatever the
/// file says it is, so other recorders and configurations work unchanged.
public struct AudioFormat: Equatable, Hashable, Sendable {
    public var channelCount: Int
    public var sampleRate: Double
    public var bitDepth: Int
    public var isFloat: Bool

    public init(channelCount: Int, sampleRate: Double, bitDepth: Int, isFloat: Bool = false) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.isFloat = isFloat
    }

    public var bytesPerSample: Int { (bitDepth + 7) / 8 }
    public var bytesPerFrame: Int { bytesPerSample * channelCount }

    /// The largest magnitude a sample of this depth can hold, as a Double.
    public var fullScale: Double {
        isFloat ? 1.0 : Double(Int64(1) << (bitDepth - 1))
    }

    /// True when two files can be concatenated into one session without resampling
    /// or re-packing. Channel count, rate and depth all have to line up.
    public func isCompatible(with other: AudioFormat) -> Bool {
        channelCount == other.channelCount
            && sampleRate == other.sampleRate
            && bitDepth == other.bitDepth
            && isFloat == other.isFloat
    }

    /// A short human description, e.g. "24-bit/48kHz".
    public var shortDescription: String {
        let khz = sampleRate / 1000
        let rate = khz == khz.rounded()
            ? String(format: "%.0f", khz)
            : String(format: "%.1f", khz)
        return "\(bitDepth)-bit/\(rate)kHz"
    }
}
