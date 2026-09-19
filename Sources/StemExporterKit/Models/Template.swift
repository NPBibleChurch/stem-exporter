import Foundation

/// One output stem in a template: either a single track, or two tracks linked as
/// a stereo pair that exports as one interleaved file.
public struct TemplateSlot: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var outputName: String
    /// `[3]` for a mono stem, `[7, 8]` for a stereo pair (left first). The two
    /// tracks do not have to be adjacent.
    public var trackNumbers: [Int]
    public var skip: Bool
    /// Default level trim in dB for this stem, for inputs that run reliably hot
    /// or quiet week to week. Overridable per session without touching the template.
    public var gainDB: Double

    public init(
        id: UUID = UUID(),
        outputName: String,
        trackNumbers: [Int],
        skip: Bool = false,
        gainDB: Double = 0
    ) {
        self.id = id
        self.outputName = outputName
        self.trackNumbers = trackNumbers
        self.skip = skip
        self.gainDB = gainDB
    }

    public var isStereo: Bool { trackNumbers.count == 2 }
    public var primaryTrack: Int { trackNumbers.first ?? 0 }

    /// The trim range every gain field offers and the model enforces. Kept in
    /// one place so a value typed into a field and the value stored can't drift.
    public static let gainRangeDB: ClosedRange<Double> = -60...24

    public static func clampGain(_ dB: Double) -> Double {
        min(max(dB, gainRangeDB.lowerBound), gainRangeDB.upperBound)
    }

    /// "Trk 5" or "Trk 5+6".
    public var sourceLabel: String {
        "Trk " + trackNumbers.map(String.init).joined(separator: "+")
    }

    // `isStereo` is derived, but the spec's data model names it, and older exported
    // files may carry it — accept it on decode and ignore it in favour of the count.
    private enum CodingKeys: String, CodingKey {
        case id, outputName, trackNumbers, skip, gainDB, isStereo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        outputName = try c.decode(String.self, forKey: .outputName)
        trackNumbers = try c.decode([Int].self, forKey: .trackNumbers)
        skip = try c.decodeIfPresent(Bool.self, forKey: .skip) ?? false
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(outputName, forKey: .outputName)
        try c.encode(trackNumbers, forKey: .trackNumbers)
        try c.encode(skip, forKey: .skip)
        try c.encode(gainDB, forKey: .gainDB)
        try c.encode(isStereo, forKey: .isStereo)
    }
}

/// A saved mapping from physical input tracks to output stem names.
public struct Template: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// The channel count this template was built for. A session with a different
    /// count still opens — anything the template doesn't cover falls back to
    /// "Track N" rather than being guessed at.
    public var trackCount: Int
    public var slots: [TemplateSlot]

    public init(id: UUID = UUID(), name: String, trackCount: Int, slots: [TemplateSlot]) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.slots = slots
    }

    /// A blank template: one mono slot per track, named "Track N".
    public static func placeholder(name: String, trackCount: Int) -> Template {
        Template(
            name: name,
            trackCount: trackCount,
            slots: (1...max(trackCount, 1)).map {
                TemplateSlot(outputName: "Track \($0)", trackNumbers: [$0])
            }
        )
    }

    public func slot(containingTrack track: Int) -> TemplateSlot? {
        slots.first { $0.trackNumbers.contains(track) }
    }

    /// Every track number the template has an opinion about.
    public var coveredTracks: Set<Int> {
        Set(slots.flatMap(\.trackNumbers))
    }

    public var exportingSlotCount: Int {
        slots.filter { !$0.skip }.count
    }

    /// Problems worth surfacing before a template is saved.
    public func validationIssues() -> [String] {
        var issues: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("The template needs a name.")
        }
        var seen: [Int: String] = [:]
        for slot in slots {
            for track in slot.trackNumbers {
                if let other = seen[track] {
                    issues.append("Track \(track) is used by both “\(other)” and “\(slot.outputName)”.")
                }
                seen[track] = slot.outputName
            }
        }
        let names = slots.filter { !$0.skip }.map {
            $0.outputName.trimmingCharacters(in: .whitespaces).lowercased()
        }
        let duplicated = Set(names.filter { n in names.filter { $0 == n }.count > 1 })
        for name in duplicated where !name.isEmpty {
            issues.append("More than one stem is named “\(name)”.")
        }
        return issues
    }
}
