import XCTest
@testable import StemExporterKit

final class PeakTests: XCTestCase {

    private func loudQuietSession() throws -> Session {
        let dir = Fixtures.makeTempDirectory("peaks")
        // 3 seconds: silent, loud, silent — the shape "Snap to Silence" exists for.
        let rate = 48_000
        try Fixtures.writeRawWAV(
            at: dir.appendingPathComponent("00000001.WAV"),
            channels: 2,
            frames: rate * 3
        ) { channel, frame in
            guard frame >= rate && frame < rate * 2 else { return 0 }
            let amplitude: Int32 = channel == 0 ? 4_000_000 : 400_000
            return frame % 2 == 0 ? amplitude : -amplitude
        }
        return try SessionLoader.load(folder: dir)
    }

    func testAnalysisProducesPerTrackAndMixPeaks() throws {
        let session = try loudQuietSession()
        let peaks = try PeakAnalyzer(bucketCount: 300).analyze(session: session)

        XCTAssertEqual(peaks.trackCount, 2)
        XCTAssertEqual(peaks.bucketCount, 300)
        XCTAssertEqual(peaks.totalFrames, 144_000)

        // Track 1 is ten times as loud as track 2.
        XCTAssertEqual(Double(peaks.tracks[0].absolutePeak), 4_000_000 / Double(1 << 23), accuracy: 0.001)
        XCTAssertEqual(Double(peaks.tracks[1].absolutePeak), 400_000 / Double(1 << 23), accuracy: 0.001)
        XCTAssertGreaterThan(peaks.mix.absolutePeak, 0)
    }

    func testSilentHeadAndTailAreQuietInTheSummary() throws {
        let session = try loudQuietSession()
        let peaks = try PeakAnalyzer(bucketCount: 300).analyze(session: session)

        XCTAssertEqual(peaks.mix.max[5], 0, accuracy: 0.0001, "the first second should read as silence")
        XCTAssertGreaterThan(peaks.mix.max[150], 0.01, "the middle second should read as loud")
        XCTAssertEqual(peaks.mix.max[295], 0, accuracy: 0.0001, "the last second should read as silence")
    }

    func testSnapToSilenceFindsTheContentRange() throws {
        let session = try loudQuietSession()
        let peaks = try PeakAnalyzer(bucketCount: 300).analyze(session: session)

        let range = SilenceDetector.contentRange(in: peaks, thresholdDB: -50)!
        XCTAssertEqual(Double(range.inFrame), 48_000, accuracy: 1_000)
        XCTAssertEqual(Double(range.outFrame), 96_000, accuracy: 1_000)
    }

    func testClipPredictionTracksGainWithoutReanalysis() throws {
        let session = try loudQuietSession()
        let peaks = try PeakAnalyzer(bucketCount: 100).analyze(session: session)
        let hot = peaks.tracks[0]

        XCTAssertFalse(hot.clips(atGainDB: 0))
        XCTAssertTrue(hot.clips(atGainDB: 12), "+12 dB on a track already at -6 dBFS should clip")
        XCTAssertEqual(hot.headroomDB(atGainDB: 0), 6.4, accuracy: 0.3)
    }

    func testStereoPairEnvelopeCoversBothSides() throws {
        let session = try loudQuietSession()
        let peaks = try PeakAnalyzer(bucketCount: 100).analyze(session: session)

        let pair = peaks.envelope(forTracks: [1, 2])!
        XCTAssertEqual(pair.absolutePeak, peaks.tracks[0].absolutePeak, "the louder side sets the pair's peak")
        XCTAssertEqual(pair.min.count, 100)
    }

    func testEmptyTracksAreFoundFromThePeaks() throws {
        let dir = Fixtures.makeTempDirectory("empty-tracks")
        let rate = 48_000
        // Track 1 plays, track 2 is dead, track 3 carries hiss at about -72 dBFS.
        try Fixtures.writeRawWAV(
            at: dir.appendingPathComponent("00000001.WAV"),
            channels: 3,
            frames: rate * 2
        ) { channel, frame in
            switch channel {
            case 0: return frame % 2 == 0 ? 2_000_000 : -2_000_000
            case 1: return 0
            default: return frame % 2 == 0 ? 2_000 : -2_000
            }
        }
        let session = try SessionLoader.load(folder: dir)
        let peaks = try PeakAnalyzer(bucketCount: 200).analyze(session: session)

        XCTAssertEqual(SilenceDetector.emptyTracks(in: peaks), [2, 3])
        XCTAssertEqual(
            SilenceDetector.emptyTracks(in: peaks, thresholdDB: -80), [2],
            "hiss counts as content once the threshold drops below it"
        )
    }

    func testAStereoPairIsOnlyEmptyWhenBothSidesAre() throws {
        let session = try loudQuietSession()
        let peaks = try PeakAnalyzer(bucketCount: 100).analyze(session: session)

        // Track 2 is quiet but real; the pair's envelope follows the louder side.
        let pair = peaks.envelope(forTracks: [1, 2])!
        XCTAssertFalse(pair.isSilent(belowDB: -60))
        XCTAssertTrue(PeakData.Track.empty.isSilent(belowDB: -60))
    }

    func testCachePersistsAndInvalidatesOnChange() throws {
        let session = try loudQuietSession()
        let cache = PeakCacheStore(folderURL: Fixtures.makeTempDirectory("peak-cache"))
        XCTAssertNil(cache.load(for: session))

        let peaks = try PeakAnalyzer(bucketCount: 100).analyze(session: session)
        cache.store(peaks, for: session)
        XCTAssertEqual(cache.load(for: session)?.bucketCount, 100)

        // Rewriting a part changes the fingerprint, so the stale cache is not reused.
        try Fixtures.writeRawWAV(at: session.parts[0].url, channels: 2, frames: 96_000)
        let changed = try SessionLoader.load(folder: session.folderURL)
        XCTAssertNil(cache.load(for: changed))
    }
}
