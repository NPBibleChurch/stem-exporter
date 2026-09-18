import XCTest
@testable import StemExporterKit

final class ExportEngineTests: XCTestCase {

    /// Build a session folder with `parts` files of `framesEach` frames, whose
    /// sample values continue across the part boundary.
    private func makeSession(
        channels: Int = 8,
        parts: Int = 2,
        framesEach: Int = 5_000,
        valueMaker: ((Int, Int) -> Int32)? = nil
    ) throws -> (Session, URL) {
        let dir = Fixtures.makeTempDirectory()
        for part in 0..<parts {
            let url = dir.appendingPathComponent(String(format: "%08d.WAV", part + 1))
            try Fixtures.writeRawWAV(
                at: url,
                channels: channels,
                frames: framesEach,
                firstFrameIndex: part * framesEach,
                valueMaker: valueMaker
            )
        }
        return (try SessionLoader.load(folder: dir), dir)
    }

    // MARK: Import

    func testFolderImportOrdersAndConcatenatesParts() throws {
        let (session, _) = try makeSession(parts: 3, framesEach: 1_000)
        XCTAssertEqual(session.parts.count, 3)
        XCTAssertEqual(session.trackCount, 8)
        XCTAssertEqual(session.totalFrames, 3_000)
        XCTAssertEqual(session.parts[0].startOffsetInSession, 0)
        XCTAssertEqual(session.parts[1].startOffsetInSession, 1_000)
        XCTAssertEqual(session.parts[2].startOffsetInSession, 2_000)
        XCTAssertTrue(session.partsSummary.contains("3 parts"))
        XCTAssertTrue(session.partsSummary.contains("00000001.WAV → 00000003.WAV"))
    }

    func testSingleFileFolderIsJustASessionWithOnePart() throws {
        let (session, _) = try makeSession(parts: 1, framesEach: 480_000)
        XCTAssertEqual(session.includedParts.count, 1)
        XCTAssertTrue(session.partsSummary.hasPrefix("1 file"))
        XCTAssertEqual(session.totalDuration, 10, accuracy: 0.001)
    }

    func testMismatchedFileIsFlaggedNotSilentlyMerged() throws {
        let dir = Fixtures.makeTempDirectory()
        try Fixtures.writeRawWAV(at: dir.appendingPathComponent("00000001.WAV"), channels: 8, frames: 100)
        try Fixtures.writeRawWAV(at: dir.appendingPathComponent("00000002.WAV"), channels: 4, frames: 100)

        let session = try SessionLoader.load(folder: dir)
        XCTAssertEqual(session.includedParts.count, 1)
        XCTAssertEqual(session.totalFrames, 100)
        XCTAssertTrue(session.warnings.contains { $0.severity == .error })
        XCTAssertTrue(session.warnings.contains { $0.message.contains("00000002.WAV") })
    }

    func testEmptyFolderThrows() throws {
        let dir = Fixtures.makeTempDirectory()
        XCTAssertThrowsError(try SessionLoader.load(folder: dir))
    }

    // MARK: Export

    func testExportsMonoStemWithCorrectChannelAndTrim() throws {
        var (session, _) = try makeSession(channels: 8, parts: 1, framesEach: 1_000)
        session.trimInFrames = 100
        session.trimOutFrames = 400

        let out = Fixtures.makeTempDirectory("out-mono")
        let stems = [StemPlan(outputName: "Piano", trackNumbers: [3])]
        let job = ExportJob(outputFolder: out, sessionName: "Service")
        let plan = ExportPlanner.plan(session: session, stems: stems, job: job)
        let result = try ExportEngine(session: session, plan: plan).run()

        XCTAssertEqual(result.stems.count, 1)
        let file = result.stems[0].fileURL
        XCTAssertEqual(file.lastPathComponent, "Service - 03 - Piano.wav")

        let samples = try Fixtures.readAllSamples(file)
        XCTAssertEqual(samples.count, 1, "a mono stem should be a mono file")
        XCTAssertEqual(samples[0].count, 300, "should contain exactly the trimmed range")
        // Channel 3 is index 2; the first exported frame is source frame 100.
        XCTAssertEqual(samples[0][0], Fixtures.sampleValue(channel: 2, frame: 100))
        XCTAssertEqual(samples[0][299], Fixtures.sampleValue(channel: 2, frame: 399))
    }

    func testStereoPairExportsAsOneInterleavedFile() throws {
        var (session, _) = try makeSession(channels: 8, parts: 1, framesEach: 500)
        session.trimInFrames = 0
        session.trimOutFrames = 500

        let out = Fixtures.makeTempDirectory("out-stereo")
        let stems = [StemPlan(outputName: "Overheads", trackNumbers: [5, 6])]
        let job = ExportJob(outputFolder: out, sessionName: "Service")
        let plan = ExportPlanner.plan(session: session, stems: stems, job: job)
        let result = try ExportEngine(session: session, plan: plan).run()

        let file = result.stems[0].fileURL
        XCTAssertEqual(file.lastPathComponent, "Service - 05+06 - Overheads.wav")
        XCTAssertTrue(result.stems[0].isStereo)

        let wav = try WAVFile.open(file)
        XCTAssertEqual(wav.format.channelCount, 2)
        XCTAssertEqual(wav.frameCount, 500)

        let samples = try Fixtures.readAllSamples(file)
        XCTAssertEqual(samples[0][10], Fixtures.sampleValue(channel: 4, frame: 10), "left should be track 5")
        XCTAssertEqual(samples[1][10], Fixtures.sampleValue(channel: 5, frame: 10), "right should be track 6")
    }

    func testStemSpanningTwoPartsIsContinuous() throws {
        var (session, _) = try makeSession(channels: 4, parts: 2, framesEach: 3_000)
        // A window that starts inside part 1 and ends inside part 2.
        session.trimInFrames = 2_500
        session.trimOutFrames = 3_500

        let out = Fixtures.makeTempDirectory("out-span")
        let stems = [StemPlan(outputName: "Vox", trackNumbers: [1])]
        let job = ExportJob(outputFolder: out, sessionName: "Service")
        let plan = ExportPlanner.plan(session: session, stems: stems, job: job)
        let result = try ExportEngine(session: session, plan: plan).run()

        let samples = try Fixtures.readAllSamples(result.stems[0].fileURL)[0]
        XCTAssertEqual(samples.count, 1_000)
        // The seam lands at exported index 500; the values must simply keep counting.
        for offset in 0..<1_000 {
            XCTAssertEqual(
                samples[offset],
                Fixtures.sampleValue(channel: 0, frame: 2_500 + offset),
                "discontinuity at exported frame \(offset)"
            )
        }
    }

    func testAllStemsComeFromASingleReadPass() throws {
        // 24 stems from an 8-channel source: whatever the count, the result has to
        // be identical to reading each channel on its own.
        var (session, _) = try makeSession(channels: 8, parts: 2, framesEach: 2_000)
        session.trimInFrames = 0
        session.trimOutFrames = session.totalFrames

        let out = Fixtures.makeTempDirectory("out-many")
        let stems = (1...8).map { StemPlan(outputName: "Trk\($0)", trackNumbers: [$0]) }
        let job = ExportJob(outputFolder: out, sessionName: "S")
        let plan = ExportPlanner.plan(session: session, stems: stems, job: job)
        let result = try ExportEngine(session: session, plan: plan).run()

        XCTAssertEqual(result.stems.count, 8)
        for (index, stem) in result.stems.enumerated() {
            let samples = try Fixtures.readAllSamples(stem.fileURL)[0]
            XCTAssertEqual(samples.count, 4_000)
            XCTAssertEqual(samples[0], Fixtures.sampleValue(channel: index, frame: 0))
            XCTAssertEqual(samples[3_999], Fixtures.sampleValue(channel: index, frame: 3_999))
        }
    }

    func testGainIsAppliedAndClippingIsReported() throws {
        // Channel 0 sits near full scale; channel 1 is quiet.
        var (session, _) = try makeSession(channels: 2, parts: 1, framesEach: 200) { channel, _ in
            channel == 0 ? Int32(8_000_000) : Int32(100_000)
        }
        session.trimInFrames = 0
        session.trimOutFrames = 200

        let out = Fixtures.makeTempDirectory("out-gain")
        let stems = [
            StemPlan(outputName: "Hot", trackNumbers: [1], gainDB: 6),
            StemPlan(outputName: "Quiet", trackNumbers: [2], gainDB: 6),
        ]
        let job = ExportJob(outputFolder: out, sessionName: "S")
        let plan = ExportPlanner.plan(session: session, stems: stems, job: job)
        let result = try ExportEngine(session: session, plan: plan).run()

        let hot = result.stems.first { $0.outputName == "Hot" }!
        let quiet = result.stems.first { $0.outputName == "Quiet" }!

        XCTAssertTrue(hot.didClip)
        XCTAssertEqual(hot.clippedSampleCount, 200)
        XCTAssertNotNil(hot.firstClipAtSeconds)
        XCTAssertFalse(quiet.didClip)

        let hotSamples = try Fixtures.readAllSamples(hot.fileURL)[0]
        XCTAssertEqual(hotSamples[0], Int32((1 << 23) - 1), "clipped samples should sit at the rail, not wrap")

        let quietSamples = try Fixtures.readAllSamples(quiet.fileURL)[0]
        XCTAssertEqual(Double(quietSamples[0]), 100_000 * pow(10.0, 6.0 / 20.0), accuracy: 1)

        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("clipped"))
    }

    func testStereoPairSharesOneGain() throws {
        var (session, _) = try makeSession(channels: 4, parts: 1, framesEach: 50) { _, _ in 1_000_000 }
        session.trimOutFrames = 50

        let out = Fixtures.makeTempDirectory("out-pairgain")
        let stems = [StemPlan(outputName: "OH", trackNumbers: [1, 2], gainDB: -6)]
        let plan = ExportPlanner.plan(
            session: session,
            stems: stems,
            job: ExportJob(outputFolder: out, sessionName: "S")
        )
        let result = try ExportEngine(session: session, plan: plan).run()

        let samples = try Fixtures.readAllSamples(result.stems[0].fileURL)
        XCTAssertEqual(samples[0][0], samples[1][0], "both sides of a pair must get the same gain")
        XCTAssertEqual(Double(samples[0][0]), 1_000_000 * pow(10.0, -6.0 / 20.0), accuracy: 1)
    }

    func testSkippedStemsAreNotWritten() throws {
        var (session, _) = try makeSession(channels: 4, parts: 1, framesEach: 100)
        session.trimOutFrames = 100

        let out = Fixtures.makeTempDirectory("out-skip")
        let stems = [
            StemPlan(outputName: "Keep", trackNumbers: [1]),
            StemPlan(outputName: "Drop", trackNumbers: [2], skip: true),
        ]
        let plan = ExportPlanner.plan(
            session: session,
            stems: stems,
            job: ExportJob(outputFolder: out, sessionName: "S")
        )
        XCTAssertEqual(plan.items.count, 1)

        let result = try ExportEngine(session: session, plan: plan).run()
        XCTAssertEqual(result.stems.count, 1)
        XCTAssertEqual(result.stems[0].outputName, "Keep")
    }

    func testExcludedPartContributesNoAudio() throws {
        var (session, _) = try makeSession(channels: 2, parts: 2, framesEach: 1_000)
        session.parts[0].isExcluded = true
        session.reindexParts()
        XCTAssertEqual(session.totalFrames, 1_000)

        let out = Fixtures.makeTempDirectory("out-excluded")
        let plan = ExportPlanner.plan(
            session: session,
            stems: [StemPlan(outputName: "A", trackNumbers: [1])],
            job: ExportJob(outputFolder: out, sessionName: "S")
        )
        let result = try ExportEngine(session: session, plan: plan).run()
        let samples = try Fixtures.readAllSamples(result.stems[0].fileURL)[0]

        XCTAssertEqual(samples.count, 1_000)
        // Part 2's audio starts at source frame 1000.
        XCTAssertEqual(samples[0], Fixtures.sampleValue(channel: 0, frame: 1_000))
    }

    func testEmptyTrimIsRejected() throws {
        var (session, _) = try makeSession(channels: 2, parts: 1, framesEach: 100)
        session.trimInFrames = 50
        session.trimOutFrames = 50

        let out = Fixtures.makeTempDirectory("out-badtrim")
        let plan = ExportPlanner.plan(
            session: session,
            stems: [StemPlan(outputName: "A", trackNumbers: [1])],
            job: ExportJob(outputFolder: out, sessionName: "S")
        )
        XCTAssertThrowsError(try ExportEngine(session: session, plan: plan).run())
    }

    func testCancellationLeavesNoPartialFiles() throws {
        var (session, _) = try makeSession(channels: 8, parts: 1, framesEach: 200_000)
        session.trimOutFrames = session.totalFrames

        let out = Fixtures.makeTempDirectory("out-cancel")
        let plan = ExportPlanner.plan(
            session: session,
            stems: (1...8).map { StemPlan(outputName: "T\($0)", trackNumbers: [$0]) },
            job: ExportJob(outputFolder: out, sessionName: "S")
        )
        let engine = ExportEngine(session: session, plan: plan)
        engine.blockByteTarget = 64 * 1024

        let cancelAfter = LockedCounter()
        let result = try engine.run(progress: { _ in cancelAfter.increment() }, isCancelled: { cancelAfter.value > 2 })

        XCTAssertTrue(result.wasCancelled)
        let leftovers = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "a cancelled export should not leave half-written stems behind")
    }

    func testProgressReachesCompletion() throws {
        var (session, _) = try makeSession(channels: 4, parts: 2, framesEach: 20_000)
        session.trimOutFrames = session.totalFrames

        let out = Fixtures.makeTempDirectory("out-progress")
        let plan = ExportPlanner.plan(
            session: session,
            stems: (1...4).map { StemPlan(outputName: "T\($0)", trackNumbers: [$0]) },
            job: ExportJob(outputFolder: out, sessionName: "S")
        )
        let engine = ExportEngine(session: session, plan: plan)
        engine.blockByteTarget = 32 * 1024

        let last = LockedBox<Double>(0)
        _ = try engine.run(progress: { last.value = $0.fractionComplete })
        XCTAssertEqual(last.value, 1.0, accuracy: 0.0001)
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
