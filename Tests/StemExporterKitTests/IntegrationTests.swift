import XCTest
@testable import StemExporterKit

/// The whole path a real week runs through: a folder of 32-channel parts, a
/// template with a stereo pair and a skipped input, a trim, and an export.
final class IntegrationTests: XCTestCase {

    func testFullWeeklyRun() throws {
        let folder = Fixtures.makeTempDirectory("weekly-session")
        let rate = 48_000
        let framesPerPart = rate * 2   // 2s each, 4s total

        for part in 0..<2 {
            try Fixtures.writeRawWAV(
                at: folder.appendingPathComponent(String(format: "%08d.WAV", part + 1)),
                channels: 32,
                frames: framesPerPart,
                firstFrameIndex: part * framesPerPart
            ) { channel, frame in
                // Channel 1 sits at the rails so it clips under any boost.
                if channel == 1 { return Int32(8_300_000) }
                return Int32((channel + 1) * 1_000 + frame % 1_000)
            }
        }

        var session = try SessionLoader.load(folder: folder)
        XCTAssertEqual(session.trackCount, 32)
        XCTAssertEqual(session.totalFrames, Int64(framesPerPart * 2))
        XCTAssertTrue(session.warnings.isEmpty)

        let template = TemplateStore.starterTemplate(trackCount: 32)
        session.name = "2026-09-13 Service"
        session.trimInFrames = Int64(rate / 2)              // 0.5s
        session.trimOutFrames = Int64(framesPerPart * 2 - rate / 2)

        let stems = StemResolver.stems(for: session, template: template)
        // 32 tracks, tracks 5+6 merged into one stereo stem.
        XCTAssertEqual(stems.count, 31)
        XCTAssertEqual(stems.filter(\.skip).count, 1)

        let out = Fixtures.makeTempDirectory("weekly-out")
        let job = ExportJob(outputFolder: out, sessionName: session.name)
        let plan = ExportPlanner.plan(session: session, stems: stems, job: job)
        XCTAssertEqual(plan.items.count, 30, "the skipped input should not be written")

        let result = try ExportEngine(session: session, plan: plan).run()

        // MARK: Files

        let written = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        XCTAssertEqual(written.count, 30)
        XCTAssertTrue(written.contains { $0.lastPathComponent == "2026-09-13 Service - 01 - Piano.wav" })
        XCTAssertTrue(written.contains { $0.lastPathComponent == "2026-09-13 Service - 05+06 - Overheads.wav" })
        XCTAssertFalse(written.contains { $0.lastPathComponent.contains("Track 7") })

        // MARK: Lengths — one trim, applied identically everywhere

        let expectedFrames = Int64(framesPerPart * 2 - rate)
        for stem in result.stems {
            XCTAssertEqual(stem.durationSamples, expectedFrames, "\(stem.outputName) came out the wrong length")
        }

        // MARK: Stereo pair

        let overheads = result.stems.first { $0.outputName == "Overheads" }!
        let overheadsFile = try WAVFile.open(overheads.fileURL)
        XCTAssertEqual(overheadsFile.format.channelCount, 2)
        XCTAssertEqual(overheadsFile.format.bitDepth, 24)
        XCTAssertEqual(overheadsFile.format.sampleRate, 48_000)
        XCTAssertEqual(overheads.byteCount, expectedFrames * 2 * 3)

        // MARK: Format passthrough

        let piano = result.stems.first { $0.outputName == "Piano" }!
        let pianoFile = try WAVFile.open(piano.fileURL)
        XCTAssertEqual(pianoFile.format.channelCount, 1)
        XCTAssertEqual(pianoFile.format, AudioFormat(channelCount: 1, sampleRate: 48_000, bitDepth: 24))

        // MARK: BWF traceability

        let bext = try XCTUnwrap(pianoFile.broadcast)
        XCTAssertEqual(bext.originator, "Stem Exporter")
        XCTAssertTrue(bext.description.contains("Piano"))
        XCTAssertTrue(bext.description.contains("2026-09-13 Service"))
        XCTAssertEqual(bext.originationDate, "2026-09-13", "the source's own date should carry through")
        // The source's timestamp, pushed forward by the trim.
        XCTAssertEqual(bext.timeReference, 1_000_000 + UInt64(rate / 2))

        // MARK: Clipping is reported, and only where it happened

        let violin = result.stems.first { $0.outputName == "Violin" }!
        XCTAssertTrue(violin.didClip, "+3 dB on a channel at the rails must be flagged")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("Violin"))
        XCTAssertFalse(piano.didClip)

        // MARK: Gain actually applied

        let vocal = result.stems.first { $0.outputName == "Lead Vocal" }!
        let vocalSamples = try Fixtures.readAllSamples(vocal.fileURL)[0]
        // Track 3 is channel index 2, and this fixture's value formula is
        // (channel + 1) * 1000 + frame % 1000 — at frame 24000 that's 3000.
        let sourceValue = Double((2 + 1) * 1_000 + (rate / 2) % 1_000)
        XCTAssertEqual(
            Double(vocalSamples[0]),
            sourceValue * pow(10.0, -2.0 / 20.0),
            accuracy: 1,
            "the template's -2 dB should be baked into the file"
        )
    }

    func testSessionReaderStitchesAcrossParts() throws {
        let folder = Fixtures.makeTempDirectory("reader")
        for part in 0..<3 {
            try Fixtures.writeRawWAV(
                at: folder.appendingPathComponent("part\(part).wav"),
                channels: 2,
                frames: 100,
                firstFrameIndex: part * 100
            )
        }
        let session = try SessionLoader.load(folder: folder)
        let reader = SessionReader(session: session)

        // A read that starts in part 0 and ends in part 2.
        let block = try reader.read(fromFrame: 50, frames: 200)
        XCTAssertEqual(block.count, 200 * session.format.bytesPerFrame)

        block.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            for offset in [0, 49, 50, 150, 199] {
                let value = SampleCodec.readInt(
                    base.advanced(by: offset * session.format.bytesPerFrame),
                    bytes: 3
                )
                XCTAssertEqual(value, Fixtures.sampleValue(channel: 0, frame: 50 + offset))
            }
        }

        let mono = try reader.readMonoDownmix(fromFrame: 0, frames: 10)
        XCTAssertEqual(mono.count, 10)
    }
}
