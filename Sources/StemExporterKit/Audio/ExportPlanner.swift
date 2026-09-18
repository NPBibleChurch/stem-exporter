import Foundation

/// One stem matched to the file it will be written to.
public struct PlannedStem: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var stem: StemPlan
    public var url: URL

    public init(stem: StemPlan, url: URL) {
        self.id = stem.id
        self.stem = stem
        self.url = url
    }

    public var fileName: String { url.lastPathComponent }
}

/// The files an export would write, worked out before a byte is read.
public struct ExportPlan: Sendable {
    public var folder: URL
    public var items: [PlannedStem]
    /// Destination files that already exist and would be replaced.
    public var collisions: [URL]

    public var hasCollisions: Bool { !collisions.isEmpty }
}

/// Turns stems plus a job into concrete filenames, resolving both kinds of
/// collision: with files already in the folder, and between two stems that
/// resolve to the same name.
public enum ExportPlanner {

    public static func plan(
        session: Session,
        stems: [StemPlan],
        job: ExportJob,
        policy: CollisionPolicy? = nil,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) -> ExportPlan {
        let folder = job.resolvedFolder(date: date)
        let effectivePolicy = policy ?? job.collisionPolicy
        var items: [PlannedStem] = []
        var claimed = Set<String>()
        var collisions: [URL] = []

        for stem in stems where !stem.skip {
            let base = job.namingPattern.fileName(
                session: job.sessionName,
                trackNumbers: stem.trackNumbers,
                stemName: stem.outputName,
                trackCount: session.trackCount
            )

            var candidate = base
            var url = folder.appendingPathComponent(candidate).appendingPathExtension("wav")
            let existsOnDisk = fileManager.fileExists(atPath: url.path)
            if existsOnDisk { collisions.append(url) }

            // Two stems resolving to the same name always get disambiguated —
            // silently overwriting a file this very export just wrote would be a bug,
            // not a policy choice.
            var suffix = 2
            let mustRename = claimed.contains(candidate.lowercased())
                || (existsOnDisk && effectivePolicy == .appendSuffix)
            if mustRename {
                repeat {
                    candidate = "\(base) (\(suffix))"
                    url = folder.appendingPathComponent(candidate).appendingPathExtension("wav")
                    suffix += 1
                } while claimed.contains(candidate.lowercased()) || fileManager.fileExists(atPath: url.path)
            }

            claimed.insert(candidate.lowercased())
            items.append(PlannedStem(stem: stem, url: url))
        }

        return ExportPlan(folder: folder, items: items, collisions: collisions)
    }
}
