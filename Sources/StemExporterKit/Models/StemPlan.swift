import Foundation

/// One row in the review table and one file in the export: a template slot with
/// the session's overrides already folded in.
public struct StemPlan: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var outputName: String
    public var trackNumbers: [Int]
    public var gainDB: Double
    public var skip: Bool
    /// False when this row is a "Track N" placeholder the template didn't cover.
    public var isFromTemplate: Bool
    public var hasNameOverride: Bool
    public var hasGainOverride: Bool
    /// True when this row is skipped because the analysis found it empty rather
    /// than because the template or the user said so.
    public var isAutoSkipped: Bool

    public init(
        id: UUID = UUID(),
        outputName: String,
        trackNumbers: [Int],
        gainDB: Double = 0,
        skip: Bool = false,
        isFromTemplate: Bool = false,
        hasNameOverride: Bool = false,
        hasGainOverride: Bool = false,
        isAutoSkipped: Bool = false
    ) {
        self.id = id
        self.outputName = outputName
        self.trackNumbers = trackNumbers
        self.gainDB = gainDB
        self.skip = skip
        self.isFromTemplate = isFromTemplate
        self.hasNameOverride = hasNameOverride
        self.hasGainOverride = hasGainOverride
        self.isAutoSkipped = isAutoSkipped
    }

    public var isStereo: Bool { trackNumbers.count == 2 }
    public var primaryTrack: Int { trackNumbers.first ?? 0 }
    public var channelCount: Int { trackNumbers.count }
    public var sourceLabel: String {
        "Trk " + trackNumbers.map(String.init).joined(separator: "+")
    }
    /// dB shown as a badge next to the name, e.g. "+3.0 dB".
    public var gainLabel: String {
        String(format: "%@%.1f dB", gainDB > 0 ? "+" : "", gainDB)
    }
}

/// How a template lines up with the session that's actually loaded.
public struct TemplateFit: Sendable, Hashable {
    public var templateTrackCount: Int
    public var sessionTrackCount: Int
    public var uncoveredTracks: [Int]
    /// Template slots that point past the end of this session's channels.
    public var outOfRangeSlots: [String]

    public var matches: Bool { templateTrackCount == sessionTrackCount }

    public var message: String? {
        if !outOfRangeSlots.isEmpty {
            let names = outOfRangeSlots.prefix(3).joined(separator: ", ")
            let more = outOfRangeSlots.count > 3 ? " and \(outOfRangeSlots.count - 3) more" : ""
            return "This template expects \(templateTrackCount) tracks but the session has \(sessionTrackCount). "
                + "\(names)\(more) point past the last channel and won’t export."
        }
        if !uncoveredTracks.isEmpty {
            let count = uncoveredTracks.count
            return "\(count) track\(count == 1 ? "" : "s") aren’t covered by this template — "
                + "they’ll export as “Track N” unless renamed or excluded."
        }
        if !matches {
            return "This template was built for \(templateTrackCount) tracks; the session has \(sessionTrackCount)."
        }
        return nil
    }
}

/// Folds a template and a session's overrides into the list of stems that will
/// actually be written.
///
/// Skip has three layers: the template's own flag, the automatic exclusion of
/// tracks the analysis found empty, and — on top of both — whatever the user
/// ticked for this session.
public enum StemResolver {

    public static func stems(for session: Session, template: Template?) -> [StemPlan] {
        let trackCount = session.trackCount
        guard trackCount > 0 else { return [] }

        var plans: [StemPlan] = []
        var covered = Set<Int>()

        if let template {
            for slot in template.slots {
                // A slot pointing past this session's channels is dropped rather
                // than guessed at; TemplateFit surfaces why.
                guard !slot.trackNumbers.isEmpty,
                      slot.trackNumbers.allSatisfy({ $0 >= 1 && $0 <= trackCount }) else { continue }
                guard slot.trackNumbers.allSatisfy({ !covered.contains($0) }) else { continue }
                covered.formUnion(slot.trackNumbers)

                let key = slot.primaryTrack
                let nameOverride = session.nameOverrides[key]
                let gainOverride = session.gainOverridesDB[key]
                // A pair only auto-skips when both of its sides read as empty.
                let autoSkipped = slot.trackNumbers.allSatisfy { session.autoSkippedTracks.contains($0) }
                plans.append(StemPlan(
                    id: slot.id,
                    outputName: nameOverride ?? slot.outputName,
                    trackNumbers: slot.trackNumbers,
                    gainDB: gainOverride ?? slot.gainDB,
                    skip: session.skipOverrides[key] ?? (autoSkipped || slot.skip),
                    isFromTemplate: true,
                    hasNameOverride: nameOverride != nil && nameOverride != slot.outputName,
                    hasGainOverride: gainOverride != nil && gainOverride != slot.gainDB,
                    isAutoSkipped: autoSkipped
                ))
            }
        }

        // Anything the template didn't cover becomes a "Track N" placeholder,
        // editable inline, rather than blocking the import.
        for track in 1...trackCount where !covered.contains(track) {
            let nameOverride = session.nameOverrides[track]
            let gainOverride = session.gainOverridesDB[track]
            let autoSkipped = session.autoSkippedTracks.contains(track)
            plans.append(StemPlan(
                id: placeholderID(track: track),
                outputName: nameOverride ?? "Track \(track)",
                trackNumbers: [track],
                gainDB: gainOverride ?? 0,
                skip: session.skipOverrides[track] ?? autoSkipped,
                isFromTemplate: false,
                hasNameOverride: nameOverride != nil,
                hasGainOverride: gainOverride != nil,
                isAutoSkipped: autoSkipped
            ))
        }

        return plans.sorted { $0.primaryTrack < $1.primaryTrack }
    }

    public static func fit(of template: Template?, to session: Session) -> TemplateFit? {
        guard let template else { return nil }
        let trackCount = session.trackCount
        let covered = template.coveredTracks.filter { $0 >= 1 && $0 <= trackCount }
        let uncovered = (1...max(trackCount, 1)).filter { !covered.contains($0) }
        let outOfRange = template.slots
            .filter { $0.trackNumbers.contains { $0 > trackCount || $0 < 1 } }
            .map(\.outputName)
        return TemplateFit(
            templateTrackCount: template.trackCount,
            sessionTrackCount: trackCount,
            uncoveredTracks: uncovered,
            outOfRangeSlots: outOfRange
        )
    }

    /// Placeholder rows need an identity that survives a redraw, but they have no
    /// template slot to borrow one from.
    static func placeholderID(track: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x70 // 'p'
        bytes[1] = 0x6C // 'l'
        withUnsafeBytes(of: Int32(track).littleEndian) { raw in
            for (i, b) in raw.enumerated() { bytes[12 + i] = b }
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
