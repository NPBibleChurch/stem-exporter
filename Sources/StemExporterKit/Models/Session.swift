import Foundation

/// One WAV file that forms part of a session, with its place on the session's
/// virtual sample timeline.
public struct SessionFile: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public var url: URL
    public var format: AudioFormat
    public var dataOffset: Int64
    public var frameCount: Int64
    /// Running sample offset of this part's first frame within the whole session.
    public var startOffsetInSession: Int64
    public var broadcast: BroadcastMetadata?
    /// Excluded parts stay in the list so they can be put back, but contribute no audio.
    public var isExcluded: Bool = false

    public init(
        url: URL,
        format: AudioFormat,
        dataOffset: Int64,
        frameCount: Int64,
        startOffsetInSession: Int64 = 0,
        broadcast: BroadcastMetadata? = nil,
        isExcluded: Bool = false
    ) {
        self.url = url
        self.format = format
        self.dataOffset = dataOffset
        self.frameCount = frameCount
        self.startOffsetInSession = startOffsetInSession
        self.broadcast = broadcast
        self.isExcluded = isExcluded
    }

    public init(wav: WAVFile, startOffsetInSession: Int64 = 0) {
        self.init(
            url: wav.url,
            format: wav.format,
            dataOffset: wav.dataOffset,
            frameCount: wav.frameCount,
            startOffsetInSession: startOffsetInSession,
            broadcast: wav.broadcast
        )
    }

    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var duration: TimeInterval {
        format.sampleRate > 0 ? Double(frameCount) / format.sampleRate : 0
    }
    /// One past the last session frame this part supplies.
    public var endOffsetInSession: Int64 { startOffsetInSession + frameCount }
}

/// Something the importer noticed that the user should see, but which doesn't
/// necessarily stop the session opening.
public struct SessionWarning: Identifiable, Hashable, Sendable {
    public enum Severity: Sendable, Hashable { case info, warning, error }
    public var id = UUID()
    public var severity: Severity
    public var message: String

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}

/// One import batch: every WAV in a folder, ordered and treated as one continuous
/// recording. Built at runtime; not persisted between launches.
public struct Session: Sendable {
    public var folderURL: URL
    /// Ordered parts. Filename order by default, correctable by hand.
    public var parts: [SessionFile]
    public var format: AudioFormat
    /// Session name used in exported filenames; editable per export.
    public var name: String
    public var warnings: [SessionWarning]

    public var templateID: UUID?
    /// Per-track-number session overrides sitting on top of the template's gainDB.
    public var gainOverridesDB: [Int: Double] = [:]
    /// Per-track-number session overrides sitting on top of the template's outputName.
    public var nameOverrides: [Int: String] = [:]
    /// Per-track-number session overrides of the template's skip flag.
    public var skipOverrides: [Int: Bool] = [:]
    /// Track numbers the peak pass found empty, pre-ticked as skipped on import.
    /// Kept apart from `skipOverrides` so an automatic guess never counts as
    /// something the user typed, and so unticking one is a real override.
    public var autoSkippedTracks: Set<Int> = []
    /// Set once the empty-track pass has run, so a re-analysis (a part reordered
    /// or excluded) doesn't re-tick a box the user has since cleared.
    public var didAutoSkipEmptyTracks = false

    public var trimInFrames: Int64 = 0
    public var trimOutFrames: Int64 = 0

    public init(
        folderURL: URL,
        parts: [SessionFile],
        format: AudioFormat,
        name: String,
        warnings: [SessionWarning] = []
    ) {
        self.folderURL = folderURL
        self.parts = parts
        self.format = format
        self.name = name
        self.warnings = warnings
        self.trimOutFrames = parts.filter { !$0.isExcluded }.reduce(0) { $0 + $1.frameCount }
    }

    // MARK: Timeline

    public var includedParts: [SessionFile] { parts.filter { !$0.isExcluded } }
    public var trackCount: Int { format.channelCount }
    public var sampleRate: Double { format.sampleRate }
    public var bitDepth: Int { format.bitDepth }

    public var totalFrames: Int64 { includedParts.reduce(0) { $0 + $1.frameCount } }
    public var totalDuration: TimeInterval {
        sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
    }

    public var trimInSeconds: TimeInterval { sampleRate > 0 ? Double(trimInFrames) / sampleRate : 0 }
    public var trimOutSeconds: TimeInterval { sampleRate > 0 ? Double(trimOutFrames) / sampleRate : 0 }
    public var trimmedFrames: Int64 { max(0, trimOutFrames - trimInFrames) }
    public var trimmedDuration: TimeInterval {
        sampleRate > 0 ? Double(trimmedFrames) / sampleRate : 0
    }
    /// A zero-length or reversed selection can't be exported.
    public var hasValidTrim: Bool { trimmedFrames > 0 }

    /// Recompute each part's offset after a reorder or an exclusion, and clamp the
    /// trim so it still lands inside the (possibly shorter) timeline.
    public mutating func reindexParts() {
        var offset: Int64 = 0
        for index in parts.indices {
            parts[index].startOffsetInSession = offset
            if !parts[index].isExcluded {
                offset += parts[index].frameCount
            }
        }
        let total = totalFrames
        if trimOutFrames == 0 || trimOutFrames > total { trimOutFrames = total }
        trimInFrames = min(max(0, trimInFrames), max(0, total))
        if trimInFrames >= trimOutFrames {
            trimInFrames = 0
            trimOutFrames = total
        }
    }

    /// e.g. "2 parts, 00000001.WAV → 00000002.WAV, 18m 42s total" or "1 file, 12m 10s".
    public var partsSummary: String {
        let included = includedParts
        let length = Timecode.compactDuration(totalDuration)
        guard let first = included.first else { return "No usable files" }
        if included.count == 1 {
            return "1 file, \(first.url.lastPathComponent), \(length)"
        }
        let last = included[included.count - 1]
        return "\(included.count) parts, \(first.url.lastPathComponent) → \(last.url.lastPathComponent), \(length) total"
    }
}
