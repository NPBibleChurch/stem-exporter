import Foundation

/// Templates on disk: one JSON file each, under Application Support.
///
/// Keeping them as separate standalone files (rather than one blob) means the
/// same format works for the export/import-a-single-template feature — a file
/// copied to another Mac is just dropped in.
public final class TemplateStore: @unchecked Sendable {

    public static let fileExtension = "stemtemplate"

    public let folderURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "template-store")

    public init(folderURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let folderURL {
            self.folderURL = folderURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.folderURL = support
                .appendingPathComponent("Stem Exporter", isDirectory: true)
                .appendingPathComponent("Templates", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.folderURL, withIntermediateDirectories: true)
    }

    // MARK: Loading

    public func loadAll() -> [Template] {
        queue.sync {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }

            let decoder = JSONDecoder()
            return urls
                .filter { $0.pathExtension == Self.fileExtension || $0.pathExtension == "json" }
                .compactMap { url -> Template? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decoder.decode(Template.self, from: data)
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: Saving

    public func save(_ template: Template) throws {
        try queue.sync {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(template)
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try data.write(to: url(for: template), options: .atomic)
        }
    }

    public func delete(_ template: Template) throws {
        try queue.sync {
            let target = url(for: template)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }
    }

    private func url(for template: Template) -> URL {
        folderURL
            .appendingPathComponent(template.id.uuidString)
            .appendingPathExtension(Self.fileExtension)
    }

    // MARK: Import / export

    /// Write a template to an arbitrary location, for backup or moving to another Mac.
    public func exportTemplate(_ template: Template, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(template).write(to: url, options: .atomic)
    }

    /// Read a template file and store it. A template whose id is already present
    /// comes in as a copy rather than quietly replacing what's there.
    @discardableResult
    public func importTemplate(from url: URL) throws -> Template {
        let data = try Data(contentsOf: url)
        var template = try JSONDecoder().decode(Template.self, from: data)
        let existing = loadAll()
        if existing.contains(where: { $0.id == template.id }) {
            template.id = UUID()
            template.name = Self.uniqueName(base: template.name, among: existing.map(\.name))
        }
        try save(template)
        return template
    }

    /// "Sunday Service" → "Sunday Service copy" → "Sunday Service copy 2".
    public static func uniqueName(base: String, among names: [String]) -> String {
        guard names.contains(base) else { return base }
        let candidate = "\(base) copy"
        guard names.contains(candidate) else { return candidate }
        var index = 2
        while names.contains("\(candidate) \(index)") { index += 1 }
        return "\(candidate) \(index)"
    }

    /// The starter template a first launch gets, so the app isn't empty on open.
    public static func starterTemplate(trackCount: Int = 32) -> Template {
        // Gains that stick week to week: a violin mic that runs quiet, a vocal
        // that runs hot. Exactly what a template default is for.
        let named: [(String, Double)] = [
            ("Piano", 0), ("Violin", 3), ("Lead Vocal", -2), ("Backing Vox", 0),
        ]
        var slots: [TemplateSlot] = named.enumerated().map { index, entry in
            TemplateSlot(outputName: entry.0, trackNumbers: [index + 1], gainDB: entry.1)
        }
        slots.append(TemplateSlot(outputName: "Overheads", trackNumbers: [5, 6]))
        slots.append(TemplateSlot(outputName: "Track 7", trackNumbers: [7], skip: true))
        slots.append(TemplateSlot(outputName: "Guitar Acoustic", trackNumbers: [8]))
        for track in 9...max(9, trackCount) where track <= trackCount {
            slots.append(TemplateSlot(outputName: "Track \(track)", trackNumbers: [track]))
        }
        return Template(name: "Sunday Service", trackCount: trackCount, slots: slots)
    }
}
