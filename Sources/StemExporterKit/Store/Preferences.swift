import Foundation

public enum AppearanceSetting: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// User defaults, wrapped so the keys live in one place.
public final class Preferences: @unchecked Sendable {

    private enum Key {
        static let appearance = "appearance"
        static let lastDestinationBookmark = "lastDestinationBookmark"
        static let lastSessionFolderBookmark = "lastSessionFolderBookmark"
        static let lastTemplateID = "lastTemplateID"
        static let namingPattern = "namingPattern"
        static let collisionPolicy = "collisionPolicy"
        static let createDatedSubfolder = "createDatedSubfolder"
        static let silenceThresholdDB = "silenceThresholdDB"
        static let autoSkipEmptyTracks = "autoSkipEmptyTracks"
        static let emptyTrackThresholdDB = "emptyTrackThresholdDB"
        static let hasSeededTemplates = "hasSeededTemplates"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var appearance: AppearanceSetting {
        get { AppearanceSetting(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    public var namingPattern: NamingPattern {
        get {
            guard let raw = defaults.string(forKey: Key.namingPattern), !raw.isEmpty else {
                return .default
            }
            return NamingPattern(pattern: raw)
        }
        set { defaults.set(newValue.pattern, forKey: Key.namingPattern) }
    }

    public var collisionPolicy: CollisionPolicy {
        get { CollisionPolicy(rawValue: defaults.string(forKey: Key.collisionPolicy) ?? "") ?? .ask }
        set { defaults.set(newValue.rawValue, forKey: Key.collisionPolicy) }
    }

    public var createDatedSubfolder: Bool {
        get { defaults.bool(forKey: Key.createDatedSubfolder) }
        set { defaults.set(newValue, forKey: Key.createDatedSubfolder) }
    }

    public var silenceThresholdDB: Double {
        get {
            let stored = defaults.double(forKey: Key.silenceThresholdDB)
            return stored == 0 ? -50 : stored
        }
        set { defaults.set(newValue, forKey: Key.silenceThresholdDB) }
    }

    /// Pre-tick Skip on tracks the analysis finds empty. On by default: an unused
    /// input is the common case on a big desk, and the box is still a box.
    public var autoSkipEmptyTracks: Bool {
        get {
            guard defaults.object(forKey: Key.autoSkipEmptyTracks) != nil else { return true }
            return defaults.bool(forKey: Key.autoSkipEmptyTracks)
        }
        set { defaults.set(newValue, forKey: Key.autoSkipEmptyTracks) }
    }

    public var emptyTrackThresholdDB: Double {
        get {
            let stored = defaults.double(forKey: Key.emptyTrackThresholdDB)
            return stored == 0 ? SilenceDetector.defaultEmptyTrackThresholdDB : stored
        }
        set { defaults.set(newValue, forKey: Key.emptyTrackThresholdDB) }
    }

    public var lastTemplateID: UUID? {
        get { defaults.string(forKey: Key.lastTemplateID).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Key.lastTemplateID) }
    }

    public var hasSeededTemplates: Bool {
        get { defaults.bool(forKey: Key.hasSeededTemplates) }
        set { defaults.set(newValue, forKey: Key.hasSeededTemplates) }
    }

    // MARK: Folder access

    public var lastDestination: URL? {
        get { BookmarkStore.resolve(defaults.data(forKey: Key.lastDestinationBookmark)) }
        set { defaults.set(BookmarkStore.bookmark(for: newValue), forKey: Key.lastDestinationBookmark) }
    }

    public var lastSessionFolder: URL? {
        get { BookmarkStore.resolve(defaults.data(forKey: Key.lastSessionFolderBookmark)) }
        set { defaults.set(BookmarkStore.bookmark(for: newValue), forKey: Key.lastSessionFolderBookmark) }
    }
}

/// Security-scoped bookmarks for folders the user has picked.
///
/// The app ships unsandboxed (it needs to reach NAS mounts and arbitrary
/// folders), but macOS still gates Desktop/Documents/Downloads and some network
/// volumes behind TCC. Holding a bookmark means the user grants access to a
/// destination once rather than on every launch.
public enum BookmarkStore {

    public static func bookmark(for url: URL?) -> Data? {
        guard let url else { return nil }
        return try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public static func resolve(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return url
    }

    /// Run `body` with the folder's security scope held open.
    public static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
