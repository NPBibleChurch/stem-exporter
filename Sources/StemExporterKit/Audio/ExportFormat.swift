import Foundation

/// The container and codec an export writes.
///
/// WAV is the pass-through case: the stem is written in the source's own PCM
/// format, byte for byte, with BWF metadata. Everything else is encoded on the
/// way out by the system's own codecs, so nothing is bundled and nothing is
/// shelled out to.
///
/// There is deliberately no MP3 case. macOS decodes MP3 but has never shipped an
/// encoder for it — `kAudioFormatMPEGLayer3` is absent from
/// `kAudioFormatProperty_EncodeFormatIDs`, and every route (AudioConverter,
/// ExtAudioFile, AVAudioFile, AVAssetWriter) refuses it — so offering MP3 would
/// mean bundling a third-party encoder. AAC is the lossy option instead: smaller
/// than MP3 at the same quality, and playable anywhere MP3 is.
public enum ExportFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Broadcast WAV, in the source's own bit depth and sample rate.
    case wav
    /// Uncompressed AIFF, in the source's own bit depth and sample rate.
    case aiff
    /// FLAC, lossless, roughly half the size of the WAV.
    case flac
    /// Apple Lossless in an M4A container.
    case alac
    /// AAC in an M4A container, at the chosen bitrate.
    case aac

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .flac: return "flac"
        case .alac, .aac: return "m4a"
        }
    }

    public var title: String {
        switch self {
        case .wav: return "WAV (BWF)"
        case .aiff: return "AIFF"
        case .flac: return "FLAC"
        case .alac: return "Apple Lossless (M4A)"
        case .aac: return "AAC (M4A)"
        }
    }

    public var isLossless: Bool { self != .aac }

    /// True when the bitrate setting applies to this format.
    public var usesBitrate: Bool { self == .aac }

    /// True when stems are written in the source's own PCM format with no
    /// conversion pass — the fast path, and the only one that carries BWF
    /// metadata.
    public var isPassthrough: Bool { self == .wav }

    public var detail: String {
        switch self {
        case .wav:
            return "Source bit depth and sample rate, with BWF metadata pointing back at the session."
        case .aiff:
            return "Uncompressed, source bit depth and sample rate. Same size as WAV."
        case .flac:
            return "Lossless compression, around half the size of the WAV."
        case .alac:
            return "Lossless compression in an M4A container, for Apple-native workflows."
        case .aac:
            return "Lossy, for rough mixes, podcast feeds and anything emailed around."
        }
    }

    /// Why the list has no MP3 entry, phrased for the Settings pane.
    public static let mp3Note =
        "macOS has no MP3 encoder — only a decoder — so MP3 isn’t offered. AAC is the lossy "
        + "option here: smaller than MP3 at the same quality, and it plays anywhere MP3 does."
}

/// A format plus the settings that go with it.
public struct ExportEncoding: Codable, Hashable, Sendable {
    /// Bitrates offered for lossy export, in kbps.
    public static let bitrateChoices = [128, 192, 256, 320]
    public static let defaultBitrateKbps = 256

    public static let `default` = ExportEncoding(format: .wav)

    public var format: ExportFormat
    /// Only read for formats where `usesBitrate` is true.
    public var lossyBitrateKbps: Int

    public init(format: ExportFormat, lossyBitrateKbps: Int = ExportEncoding.defaultBitrateKbps) {
        self.format = format
        self.lossyBitrateKbps = ExportEncoding.clampBitrate(lossyBitrateKbps)
    }

    /// Snap a stored or typed bitrate to the nearest offered choice, so a stale
    /// preference can never reach the encoder as something it would reject.
    public static func clampBitrate(_ kbps: Int) -> Int {
        bitrateChoices.min(by: { abs($0 - kbps) < abs($1 - kbps) }) ?? defaultBitrateKbps
    }

    public var fileExtension: String { format.fileExtension }

    /// A one-line description, e.g. "AAC (M4A) · 256 kbps".
    public var summary: String {
        format.usesBitrate ? "\(format.title) · \(lossyBitrateKbps) kbps" : format.title
    }
}
