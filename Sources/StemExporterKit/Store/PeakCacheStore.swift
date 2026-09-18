import Foundation
import CryptoKit

/// Caches the analysed peaks for a session so re-opening the same folder is
/// instant instead of another pass over several gigabytes.
///
/// The key fingerprints the parts that make up the session — their paths, sizes
/// and modification dates — so a folder that has gained, lost or had a file
/// rewritten is re-analysed rather than drawn from a stale cache.
public final class PeakCacheStore: @unchecked Sendable {

    public let folderURL: URL
    private let fileManager: FileManager

    public init(folderURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let folderURL {
            self.folderURL = folderURL
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.folderURL = caches.appendingPathComponent("Stem Exporter/Peaks", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.folderURL, withIntermediateDirectories: true)
    }

    public func fingerprint(for session: Session) -> String {
        var hasher = SHA256()
        for part in session.includedParts {
            hasher.update(data: Data(part.url.path.utf8))
            let attrs = try? fileManager.attributesOfItem(atPath: part.url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            hasher.update(data: Data(String(size).utf8))
            hasher.update(data: Data(String(Int(modified)).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func load(for session: Session) -> PeakData? {
        let url = cacheURL(fingerprint: fingerprint(for: session))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PeakData.self, from: data)
    }

    public func store(_ peaks: PeakData, for session: Session) {
        let url = cacheURL(fingerprint: fingerprint(for: session))
        guard let data = try? JSONEncoder().encode(peaks) else { return }
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func cacheURL(fingerprint: String) -> URL {
        folderURL.appendingPathComponent(fingerprint).appendingPathExtension("peaks")
    }

    /// Drop everything; offered in Settings for when the cache folder gets big.
    public func clear() {
        guard let urls = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { return }
        urls.forEach { try? fileManager.removeItem(at: $0) }
    }

    public var cacheSizeBytes: Int64 {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return urls.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }
}
