import Foundation

/// What to do when a file of the same name is already in the destination folder.
public enum CollisionPolicy: String, Codable, CaseIterable, Sendable {
    case ask
    case overwrite
    case appendSuffix

    public var title: String {
        switch self {
        case .ask: return "Ask each time"
        case .overwrite: return "Replace existing files"
        case .appendSuffix: return "Keep both (append “ (2)”)"
        }
    }
}

/// The filename pattern for exported stems.
///
/// The default puts a zero-padded track number ahead of the name so Finder sorts
/// the stems back into input order. The pattern itself is a small token string so
/// it can be made user-editable without touching the export engine.
public struct NamingPattern: Codable, Hashable, Sendable {
    public static let sessionToken = "{session}"
    public static let trackToken = "{track}"
    public static let nameToken = "{name}"

    public static let `default` = NamingPattern(
        pattern: "\(sessionToken) - \(trackToken) - \(nameToken)"
    )

    public var pattern: String

    public init(pattern: String) {
        self.pattern = pattern
    }

    /// Render one filename (without extension), zero-padding the track number to
    /// two digits, or to whatever the session's track count needs.
    public func fileName(session: String, trackNumbers: [Int], stemName: String, trackCount: Int = 32) -> String {
        let width = max(2, String(max(trackCount, 1)).count)
        let trackText = trackNumbers
            .map { String(format: "%0\(width)d", $0) }
            .joined(separator: "+")
        let rendered = pattern
            .replacingOccurrences(of: Self.sessionToken, with: session)
            .replacingOccurrences(of: Self.trackToken, with: trackText)
            .replacingOccurrences(of: Self.nameToken, with: stemName)
        return FileNameSanitizer.sanitize(rendered)
    }
}

public enum FileNameSanitizer {
    /// Strip the characters HFS+/APFS and Finder object to, and collapse the
    /// whitespace that renaming tends to leave behind.
    public static func sanitize(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>\u{0}")
        var cleaned = raw.components(separatedBy: illegal).joined(separator: "-")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        if cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(200))
    }
}

/// Where and how one export run writes its files.
public struct ExportJob: Sendable {
    public var outputFolder: URL
    public var sessionName: String
    public var namingPattern: NamingPattern
    public var collisionPolicy: CollisionPolicy
    /// Put the stems in a dated subfolder of the destination instead of loose in it.
    public var createDatedSubfolder: Bool
    /// The container and codec the stems are written in.
    public var encoding: ExportEncoding

    public init(
        outputFolder: URL,
        sessionName: String,
        namingPattern: NamingPattern = .default,
        collisionPolicy: CollisionPolicy = .ask,
        createDatedSubfolder: Bool = false,
        encoding: ExportEncoding = .default
    ) {
        self.outputFolder = outputFolder
        self.sessionName = sessionName
        self.namingPattern = namingPattern
        self.collisionPolicy = collisionPolicy
        self.createDatedSubfolder = createDatedSubfolder
        self.encoding = encoding
    }

    /// The folder the files actually land in, once the dated-subfolder option is applied.
    public func resolvedFolder(date: Date = Date()) -> URL {
        guard createDatedSubfolder else { return outputFolder }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let folderName = FileNameSanitizer.sanitize("\(formatter.string(from: date)) \(sessionName)")
        return outputFolder.appendingPathComponent(folderName, isDirectory: true)
    }
}

/// One file the export wrote, for the summary screen.
public struct ExportedStem: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var outputName: String
    public var fileURL: URL
    public var sourceTrackNumbers: [Int]
    public var durationSamples: Int64
    public var byteCount: Int64
    public var isStereo: Bool
    /// Seconds into the exported file where the first clipped sample landed.
    public var firstClipAtSeconds: TimeInterval?
    public var clippedSampleCount: Int64

    public init(
        id: UUID = UUID(),
        outputName: String,
        fileURL: URL,
        sourceTrackNumbers: [Int],
        durationSamples: Int64,
        byteCount: Int64,
        isStereo: Bool,
        firstClipAtSeconds: TimeInterval? = nil,
        clippedSampleCount: Int64 = 0
    ) {
        self.id = id
        self.outputName = outputName
        self.fileURL = fileURL
        self.sourceTrackNumbers = sourceTrackNumbers
        self.durationSamples = durationSamples
        self.byteCount = byteCount
        self.isStereo = isStereo
        self.firstClipAtSeconds = firstClipAtSeconds
        self.clippedSampleCount = clippedSampleCount
    }

    public var didClip: Bool { clippedSampleCount > 0 }
    public var displayName: String {
        fileURL.lastPathComponent + (isStereo ? " (stereo)" : "")
    }
}

/// Everything the summary screen needs after a run finishes.
public struct ExportResult: Sendable {
    public var folder: URL
    public var stems: [ExportedStem]
    public var warnings: [String]
    public var trimmedDuration: TimeInterval
    public var sourceDuration: TimeInterval
    public var wasCancelled: Bool

    public init(
        folder: URL,
        stems: [ExportedStem],
        warnings: [String],
        trimmedDuration: TimeInterval,
        sourceDuration: TimeInterval,
        wasCancelled: Bool = false
    ) {
        self.folder = folder
        self.stems = stems
        self.warnings = warnings
        self.trimmedDuration = trimmedDuration
        self.sourceDuration = sourceDuration
        self.wasCancelled = wasCancelled
    }

    public var totalBytes: Int64 { stems.reduce(0) { $0 + $1.byteCount } }
    public var clippedStems: [ExportedStem] { stems.filter(\.didClip) }
}
