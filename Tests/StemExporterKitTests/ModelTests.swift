import XCTest
@testable import StemExporterKit

final class TemplateResolutionTests: XCTestCase {

    private func session(trackCount: Int) -> Session {
        let format = AudioFormat(channelCount: trackCount, sampleRate: 48_000, bitDepth: 24)
        let part = SessionFile(
            url: URL(fileURLWithPath: "/tmp/00000001.WAV"),
            format: format,
            dataOffset: 44,
            frameCount: 480_000
        )
        return Session(folderURL: URL(fileURLWithPath: "/tmp"), parts: [part], format: format, name: "Service")
    }

    func testNoTemplateGivesOnePlaceholderPerTrack() {
        let stems = StemResolver.stems(for: session(trackCount: 32), template: nil)
        XCTAssertEqual(stems.count, 32)
        XCTAssertEqual(stems[0].outputName, "Track 1")
        XCTAssertEqual(stems[31].outputName, "Track 32")
        XCTAssertTrue(stems.allSatisfy { !$0.isFromTemplate })
    }

    func testStereoPairBecomesOneStem() {
        let template = Template(name: "T", trackCount: 8, slots: [
            TemplateSlot(outputName: "Piano", trackNumbers: [1]),
            TemplateSlot(outputName: "Overheads", trackNumbers: [5, 6]),
        ])
        let stems = StemResolver.stems(for: session(trackCount: 8), template: template)

        // 8 tracks, one pair merged, so 7 rows.
        XCTAssertEqual(stems.count, 7)
        let overheads = stems.first { $0.outputName == "Overheads" }!
        XCTAssertTrue(overheads.isStereo)
        XCTAssertEqual(overheads.sourceLabel, "Trk 5+6")
        XCTAssertFalse(stems.contains { $0.outputName == "Track 5" || $0.outputName == "Track 6" })
    }

    func testTracksBeyondTheTemplateFallBackToPlaceholders() {
        let template = Template(name: "Small", trackCount: 4, slots: [
            TemplateSlot(outputName: "Piano", trackNumbers: [1]),
            TemplateSlot(outputName: "Violin", trackNumbers: [2]),
        ])
        let stems = StemResolver.stems(for: session(trackCount: 8), template: template)

        XCTAssertEqual(stems.count, 8)
        XCTAssertEqual(stems[0].outputName, "Piano")
        XCTAssertEqual(stems[2].outputName, "Track 3")
        XCTAssertFalse(stems[2].isFromTemplate)
    }

    func testSlotsPastTheChannelCountAreDroppedNotGuessed() {
        let template = Template(name: "Big", trackCount: 32, slots: [
            TemplateSlot(outputName: "Piano", trackNumbers: [1]),
            TemplateSlot(outputName: "Choir", trackNumbers: [30]),
        ])
        let small = session(trackCount: 4)
        let stems = StemResolver.stems(for: small, template: template)

        XCTAssertEqual(stems.count, 4)
        XCTAssertFalse(stems.contains { $0.outputName == "Choir" })

        let fit = StemResolver.fit(of: template, to: small)!
        XCTAssertFalse(fit.matches)
        XCTAssertEqual(fit.outOfRangeSlots, ["Choir"])
        XCTAssertTrue(fit.message!.contains("32 tracks but the session has 4"))
    }

    func testEmptyTracksArriveSkippedAndCanBeUnticked() {
        var s = session(trackCount: 4)
        s.autoSkippedTracks = [3]
        let template = Template(name: "T", trackCount: 4, slots: [
            TemplateSlot(outputName: "Piano", trackNumbers: [1]),
            TemplateSlot(outputName: "Violin", trackNumbers: [2]),
            TemplateSlot(outputName: "Spare", trackNumbers: [3]),
            TemplateSlot(outputName: "Amb", trackNumbers: [4]),
        ])

        var stems = StemResolver.stems(for: s, template: template)
        XCTAssertTrue(stems[2].skip)
        XCTAssertTrue(stems[2].isAutoSkipped)
        XCTAssertFalse(stems[0].skip)

        // An explicit "no, export it" has to win over the automatic guess.
        s.skipOverrides[3] = false
        stems = StemResolver.stems(for: s, template: template)
        XCTAssertFalse(stems[2].skip)
        XCTAssertTrue(stems[2].isAutoSkipped, "the row still says why it was ticked")
    }

    func testAPairIsAutoSkippedOnlyWhenBothSidesAreEmpty() {
        var s = session(trackCount: 8)
        s.autoSkippedTracks = [5]
        let template = Template(name: "T", trackCount: 8, slots: [
            TemplateSlot(outputName: "Overheads", trackNumbers: [5, 6]),
        ])

        XCTAssertFalse(StemResolver.stems(for: s, template: template)[4].skip)

        s.autoSkippedTracks = [5, 6]
        let both = StemResolver.stems(for: s, template: template)[4]
        XCTAssertTrue(both.skip)
        XCTAssertTrue(both.isAutoSkipped)
    }

    func testSessionOverridesSitOnTopOfTheTemplate() {
        var s = session(trackCount: 4)
        s.nameOverrides[1] = "Grand Piano"
        s.gainOverridesDB[2] = -4
        s.skipOverrides[3] = true

        let template = Template(name: "T", trackCount: 4, slots: [
            TemplateSlot(outputName: "Piano", trackNumbers: [1], gainDB: 2),
            TemplateSlot(outputName: "Violin", trackNumbers: [2], gainDB: 3),
            TemplateSlot(outputName: "Vox", trackNumbers: [3]),
            TemplateSlot(outputName: "Amb", trackNumbers: [4]),
        ])
        let stems = StemResolver.stems(for: s, template: template)

        XCTAssertEqual(stems[0].outputName, "Grand Piano")
        XCTAssertTrue(stems[0].hasNameOverride)
        XCTAssertEqual(stems[0].gainDB, 2, "an untouched gain still comes from the template")
        XCTAssertEqual(stems[1].gainDB, -4)
        XCTAssertTrue(stems[1].hasGainOverride)
        XCTAssertTrue(stems[2].skip)

        // The template itself is untouched.
        XCTAssertEqual(template.slots[0].outputName, "Piano")
        XCTAssertEqual(template.slots[1].gainDB, 3)
    }

    func testValidationCatchesDuplicateTracksAndNames() {
        let template = Template(name: "T", trackCount: 4, slots: [
            TemplateSlot(outputName: "Piano", trackNumbers: [1]),
            TemplateSlot(outputName: "Piano", trackNumbers: [1, 2]),
        ])
        let issues = template.validationIssues()
        XCTAssertTrue(issues.contains { $0.contains("Track 1") })
        XCTAssertTrue(issues.contains { $0.contains("named") })
    }

    func testTemplateJSONRoundTrip() throws {
        let template = Template(name: "Sunday Service", trackCount: 32, slots: [
            TemplateSlot(outputName: "Overheads", trackNumbers: [7, 8], gainDB: -1.5),
            TemplateSlot(outputName: "Spare", trackNumbers: [9], skip: true),
        ])
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(Template.self, from: data)

        XCTAssertEqual(decoded, template)
        XCTAssertTrue(decoded.slots[0].isStereo)
        XCTAssertTrue(decoded.slots[1].skip)
        // The spec's data model names isStereo, so it's in the file for readers that want it.
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("isStereo"))
    }
}

final class SessionNameTests: XCTestCase {

    private func session(folder: String, name: String? = nil) -> Session {
        let url = URL(fileURLWithPath: folder)
        let format = AudioFormat(channelCount: 4, sampleRate: 48_000, bitDepth: 24)
        let part = SessionFile(
            url: url.appendingPathComponent("00000001.WAV"),
            format: format,
            dataOffset: 44,
            frameCount: 480_000
        )
        return Session(
            folderURL: url,
            parts: [part],
            format: format,
            name: name ?? SessionLoader.defaultSessionName(for: url)
        )
    }

    func testImportedSessionStartsOnTheFolderName() {
        let session = self.session(folder: "/tmp/5D319CBD")
        XCTAssertEqual(session.name, "5D319CBD")
        XCTAssertFalse(session.hasCustomName)
    }

    func testRenamingTrimsAndSticks() {
        var session = self.session(folder: "/tmp/5D319CBD")
        session.rename(to: "  2026-09-13 Service  ")
        XCTAssertEqual(session.name, "2026-09-13 Service")
        XCTAssertTrue(session.hasCustomName)
    }

    func testClearingTheNameFallsBackToTheFolderName() {
        var session = self.session(folder: "/tmp/5D319CBD", name: "Service")
        session.rename(to: "   ")
        XCTAssertEqual(session.name, "5D319CBD")
        XCTAssertFalse(session.hasCustomName)
    }

    func testARenamedSessionNamesTheExportedFiles() {
        var session = self.session(folder: "/tmp/5D319CBD")
        session.rename(to: "Youth Band: take 2")
        let name = NamingPattern.default.fileName(
            session: session.name,
            trackNumbers: [3],
            stemName: "Piano",
            trackCount: session.trackCount
        )
        // Illegal characters are the filename layer's problem, not the field's.
        XCTAssertEqual(name, "Youth Band- take 2 - 03 - Piano")
    }
}

final class NamingTests: XCTestCase {

    func testDefaultPatternZeroPadsForFinderSorting() {
        let pattern = NamingPattern.default
        XCTAssertEqual(
            pattern.fileName(session: "2026-09-13 Service", trackNumbers: [3], stemName: "Piano"),
            "2026-09-13 Service - 03 - Piano"
        )
        XCTAssertEqual(
            pattern.fileName(session: "S", trackNumbers: [7, 8], stemName: "Overheads"),
            "S - 07+08 - Overheads"
        )
    }

    func testIllegalCharactersAreReplaced() {
        XCTAssertEqual(FileNameSanitizer.sanitize("Vox / Choir: take 2"), "Vox - Choir- take 2")
        XCTAssertEqual(FileNameSanitizer.sanitize("   "), "Untitled")
    }

    func testTwoStemsWithTheSameNameAreAlwaysDisambiguated() throws {
        let out = Fixtures.makeTempDirectory("naming-dupes")
        let format = AudioFormat(channelCount: 4, sampleRate: 48_000, bitDepth: 24)
        let session = Session(
            folderURL: out,
            parts: [SessionFile(url: out, format: format, dataOffset: 0, frameCount: 10)],
            format: format,
            name: "S"
        )
        let stems = [
            StemPlan(outputName: "Vox", trackNumbers: [1]),
            StemPlan(outputName: "Vox", trackNumbers: [1]),
        ]
        let plan = ExportPlanner.plan(
            session: session,
            stems: stems,
            job: ExportJob(outputFolder: out, sessionName: "S")
        )
        XCTAssertEqual(plan.items[0].fileName, "S - 01 - Vox.wav")
        XCTAssertEqual(plan.items[1].fileName, "S - 01 - Vox (2).wav")
    }

    func testExistingFilesAreReportedAndSuffixedWhenAsked() throws {
        let out = Fixtures.makeTempDirectory("naming-collide")
        let existing = out.appendingPathComponent("S - 01 - Vox.wav")
        try Data("x".utf8).write(to: existing)

        let format = AudioFormat(channelCount: 4, sampleRate: 48_000, bitDepth: 24)
        let session = Session(
            folderURL: out,
            parts: [SessionFile(url: out, format: format, dataOffset: 0, frameCount: 10)],
            format: format,
            name: "S"
        )
        let stems = [StemPlan(outputName: "Vox", trackNumbers: [1])]
        let job = ExportJob(outputFolder: out, sessionName: "S")

        let overwritePlan = ExportPlanner.plan(session: session, stems: stems, job: job, policy: .overwrite)
        XCTAssertEqual(overwritePlan.collisions.count, 1)
        XCTAssertEqual(overwritePlan.items[0].url, existing)

        let keepBothPlan = ExportPlanner.plan(session: session, stems: stems, job: job, policy: .appendSuffix)
        XCTAssertEqual(keepBothPlan.items[0].fileName, "S - 01 - Vox (2).wav")
    }

    func testDatedSubfolder() {
        var job = ExportJob(outputFolder: URL(fileURLWithPath: "/tmp/Stems"), sessionName: "Sunday Service")
        job.createDatedSubfolder = true
        let date = Date(timeIntervalSince1970: 1_789_000_000)  // 2026-09-08 UTC-ish
        XCTAssertTrue(job.resolvedFolder(date: date).lastPathComponent.contains("Sunday Service"))
        XCTAssertTrue(job.resolvedFolder(date: date).lastPathComponent.hasPrefix("20"))

        job.createDatedSubfolder = false
        XCTAssertEqual(job.resolvedFolder(date: date).lastPathComponent, "Stems")
    }
}

final class TimecodeTests: XCTestCase {

    func testFormatting() {
        XCTAssertEqual(Timecode.string(from: 0), "00:00:00.000")
        XCTAssertEqual(Timecode.string(from: 102.18), "00:01:42.180")
        XCTAssertEqual(Timecode.string(from: 2865.52), "00:47:45.520")
    }

    func testParsing() {
        XCTAssertEqual(Timecode.seconds(from: "00:01:42.180")!, 102.18, accuracy: 0.0005)
        XCTAssertEqual(Timecode.seconds(from: "1:42.18")!, 102.18, accuracy: 0.0005)
        XCTAssertEqual(Timecode.seconds(from: "42.5")!, 42.5, accuracy: 0.0005)
        XCTAssertNil(Timecode.seconds(from: "not a time"))
        XCTAssertNil(Timecode.seconds(from: "1:2:3:4"))
    }

    func testCompactDuration() {
        XCTAssertEqual(Timecode.compactDuration(2763), "46m 03s")
        XCTAssertEqual(Timecode.compactDuration(1122), "18m 42s")
        XCTAssertEqual(Timecode.compactDuration(4324), "1h 12m 04s")
        XCTAssertEqual(Timecode.compactDuration(58), "58s")
    }

    func testRoundTrip() {
        for seconds in [0.0, 1.5, 102.18, 3661.999] {
            let text = Timecode.string(from: seconds)
            XCTAssertEqual(Timecode.seconds(from: text)!, seconds, accuracy: 0.001)
        }
    }
}

final class TemplateStoreTests: XCTestCase {

    func testSaveLoadDelete() throws {
        let store = TemplateStore(folderURL: Fixtures.makeTempDirectory("templates"))
        let template = Template(name: "Youth Band", trackCount: 16, slots: [
            TemplateSlot(outputName: "Kick", trackNumbers: [1]),
        ])
        try store.save(template)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Youth Band")

        try store.delete(template)
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testImportingATemplateThatIsAlreadyThereMakesACopy() throws {
        let store = TemplateStore(folderURL: Fixtures.makeTempDirectory("templates-import"))
        let template = Template(name: "Sunday Service", trackCount: 32, slots: [])
        try store.save(template)

        let exportURL = Fixtures.makeTempDirectory("templates-export")
            .appendingPathComponent("Sunday Service.json")
        try store.exportTemplate(template, to: exportURL)

        let imported = try store.importTemplate(from: exportURL)
        XCTAssertNotEqual(imported.id, template.id)
        XCTAssertEqual(imported.name, "Sunday Service copy")
        XCTAssertEqual(store.loadAll().count, 2)
    }

    func testUniqueNaming() {
        XCTAssertEqual(TemplateStore.uniqueName(base: "A", among: []), "A")
        XCTAssertEqual(TemplateStore.uniqueName(base: "A", among: ["A"]), "A copy")
        XCTAssertEqual(TemplateStore.uniqueName(base: "A", among: ["A", "A copy"]), "A copy 2")
    }
}
