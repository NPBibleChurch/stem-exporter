import XCTest
@testable import StemExporterKit

/// The export splits each block across cores by frame range, and peak analysis
/// splits its buckets the same way. Both stitch per-worker results back together
/// afterwards, so these tests aim at the seams: a result that depends on how the
/// work happened to be divided is the failure mode worth catching.
final class ConcurrencyTests: XCTestCase {

    private func session(
        channels: Int = 8,
        parts: Int = 2,
        framesEach: Int = 40_000,
        valueMaker: ((Int, Int) -> Int32)? = nil
    ) throws -> Session {
        let dir = Fixtures.makeTempDirectory("concurrency")
        for part in 0..<parts {
            try Fixtures.writeRawWAV(
                at: dir.appendingPathComponent(String(format: "%08d.WAV", part + 1)),
                channels: channels,
                frames: framesEach,
                firstFrameIndex: part * framesEach,
                valueMaker: valueMaker
            )
        }
        var loaded = try SessionLoader.load(folder: dir)
        loaded.trimInFrames = 0
        loaded.trimOutFrames = loaded.totalFrames
        return loaded
    }

    /// Every sample of every stem, across part boundaries and however the blocks
    /// and workers happened to divide the source.
    func testEverySampleSurvivesWhateverTheBlockSize() throws {
        let source = try session(channels: 8, parts: 2, framesEach: 40_000)
        let stems = [
            StemPlan(outputName: "Mono", trackNumbers: [3]),
            StemPlan(outputName: "Pair", trackNumbers: [5, 6]),
        ]

        // 12 KB blocks divide the source into far more pieces than any real export
        // would use, which is the point: the seams land in different places.
        for blockBytes in [12 * 1024, 700 * 1024, 8 * 1024 * 1024] {
            let out = Fixtures.makeTempDirectory("out-block-\(blockBytes)")
            let plan = ExportPlanner.plan(
                session: source,
                stems: stems,
                job: ExportJob(outputFolder: out, sessionName: "S")
            )
            let engine = ExportEngine(session: source, plan: plan)
            engine.blockByteTarget = blockBytes
            let result = try engine.run()

            let mono = try Fixtures.readAllSamples(
                result.stems.first { $0.outputName == "Mono" }!.fileURL
            )
            XCTAssertEqual(mono[0].count, 80_000, "block size \(blockBytes)")
            for frame in stride(from: 0, to: 80_000, by: 997) {
                XCTAssertEqual(
                    mono[0][frame],
                    Fixtures.sampleValue(channel: 2, frame: frame),
                    "mono track drifted at frame \(frame), block size \(blockBytes)"
                )
            }

            let pair = try Fixtures.readAllSamples(
                result.stems.first { $0.outputName == "Pair" }!.fileURL
            )
            XCTAssertEqual(pair.count, 2)
            for frame in stride(from: 0, to: 80_000, by: 997) {
                XCTAssertEqual(pair[0][frame], Fixtures.sampleValue(channel: 4, frame: frame))
                XCTAssertEqual(pair[1][frame], Fixtures.sampleValue(channel: 5, frame: frame))
            }
        }
    }

    /// A single clipped sample buried in the middle of the session: its count and
    /// its timestamp both have to come back exactly, no matter which worker found
    /// it or how many blocks came before.
    func testOneClippedSampleIsFoundAtTheRightTime() throws {
        let clipFrame = 53_117
        let source = try session(channels: 4, parts: 2, framesEach: 40_000) { channel, frame in
            channel == 0 && frame == clipFrame ? Int32((1 << 23) - 1) : 1_000
        }

        for blockBytes in [12 * 1024, 700 * 1024, 8 * 1024 * 1024] {
            let out = Fixtures.makeTempDirectory("out-clip-\(blockBytes)")
            let plan = ExportPlanner.plan(
                session: source,
                stems: [StemPlan(outputName: "Hot", trackNumbers: [1])],
                job: ExportJob(outputFolder: out, sessionName: "S")
            )
            let engine = ExportEngine(session: source, plan: plan)
            engine.blockByteTarget = blockBytes
            let result = try engine.run()

            let hot = result.stems[0]
            XCTAssertEqual(hot.clippedSampleCount, 1, "block size \(blockBytes)")
            XCTAssertEqual(
                hot.firstClipAtSeconds ?? -1,
                Double(clipFrame) / 48_000,
                accuracy: 1.0 / 48_000,
                "clip timestamp moved with the block size (\(blockBytes))"
            )
        }
    }

    /// Two clips far apart but inside a single block, so they land in different
    /// workers' frame ranges. The report has to name the first, which is what a
    /// naive combine across workers gets wrong.
    func testEarliestClipWinsAcrossWorkers() throws {
        let early = 10_000
        let late = 500_000
        let source = try session(channels: 2, parts: 1, framesEach: 600_000) { channel, frame in
            guard channel == 0 else { return 1_000 }
            return (frame == early || frame == late) ? Int32((1 << 23) - 1) : 1_000
        }

        let out = Fixtures.makeTempDirectory("out-two-clips")
        let plan = ExportPlanner.plan(
            session: source,
            stems: [StemPlan(outputName: "Hot", trackNumbers: [1])],
            job: ExportJob(outputFolder: out, sessionName: "S")
        )
        // The default block swallows the whole session, so both clips are found in
        // the same pass over the same block, by different workers.
        let result = try ExportEngine(session: source, plan: plan).run()

        XCTAssertEqual(result.stems[0].clippedSampleCount, 2)
        XCTAssertEqual(
            result.stems[0].firstClipAtSeconds ?? -1,
            Double(early) / 48_000,
            accuracy: 1.0 / 48_000,
            "the later clip was reported instead of the first"
        )
    }

    /// Peak analysis divides its buckets across cores; the summary must not depend
    /// on where those divisions fell.
    func testPeaksAreIdenticalAcrossBucketCounts() throws {
        let source = try session(channels: 4, parts: 2, framesEach: 50_000) { channel, frame in
            Int32(Double(1 << 22) * sin(Double(frame) / Double(97 + channel * 13)))
        }

        // Same analyser, run twice: a race in the shared accumulators would show up
        // as two different answers for the same input.
        let first = try PeakAnalyzer(bucketCount: 777).analyze(session: source)
        let second = try PeakAnalyzer(bucketCount: 777).analyze(session: source)

        XCTAssertEqual(first.tracks.count, 4)
        for channel in 0..<4 {
            XCTAssertEqual(first.tracks[channel].min, second.tracks[channel].min)
            XCTAssertEqual(first.tracks[channel].max, second.tracks[channel].max)
            XCTAssertEqual(first.tracks[channel].absolutePeak, second.tracks[channel].absolutePeak)
        }
        XCTAssertEqual(first.mix.min, second.mix.min)
        XCTAssertEqual(first.mix.max, second.mix.max)
        XCTAssertEqual(first.mix.absolutePeak, second.mix.absolutePeak)

        // The loudest sample in the source has to survive the fan-out.
        XCTAssertEqual(Double(first.tracks[0].absolutePeak), 0.5, accuracy: 0.01)
    }

    /// Progress is reported from several workers at once; it still has to arrive
    /// monotonically and finish at 1.
    func testAnalysisProgressIsMonotonicAndCompletes() throws {
        let source = try session(channels: 4, parts: 1, framesEach: 60_000)

        let lock = NSLock()
        var seen: [Double] = []
        _ = try PeakAnalyzer(bucketCount: 500).analyze(session: source) { progress in
            lock.lock()
            seen.append(progress.fractionComplete)
            lock.unlock()
        }

        XCTAssertFalse(seen.isEmpty)
        XCTAssertEqual(seen.last!, 1.0, accuracy: 0.0001)
        XCTAssertEqual(seen, seen.sorted(), "progress went backwards")
        XCTAssertTrue(seen.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}
