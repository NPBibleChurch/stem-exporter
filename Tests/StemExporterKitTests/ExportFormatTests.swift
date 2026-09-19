import XCTest
@testable import StemExporterKit

#if canImport(AVFoundation)
import AVFoundation
#endif

final class ExportFormatTests: XCTestCase {

    private func makeSession(channels: Int = 4, frames: Int = 4_000) throws -> Session {
        let dir = Fixtures.makeTempDirectory("format-session")
        try Fixtures.writeRawWAV(
            at: dir.appendingPathComponent("00000001.WAV"),
            channels: channels,
            frames: frames
        )
        return try SessionLoader.load(folder: dir)
    }

    // MARK: Model

    func testExtensionsAndBitrateApplicability() {
        XCTAssertEqual(ExportFormat.wav.fileExtension, "wav")
        XCTAssertEqual(ExportFormat.aiff.fileExtension, "aiff")
        XCTAssertEqual(ExportFormat.flac.fileExtension, "flac")
        XCTAssertEqual(ExportFormat.alac.fileExtension, "m4a")
        XCTAssertEqual(ExportFormat.aac.fileExtension, "m4a")

        XCTAssertTrue(ExportFormat.wav.isPassthrough)
        XCTAssertFalse(ExportFormat.aiff.isPassthrough)
        XCTAssertTrue(ExportFormat.aac.usesBitrate)
        XCTAssertFalse(ExportFormat.aac.isLossless)
        XCTAssertTrue(ExportFormat.allCases.allSatisfy { $0 == .aac || $0.isLossless })
    }

    func testBitrateIsSnappedToAnOfferedChoice() {
        XCTAssertEqual(ExportEncoding(format: .aac, lossyBitrateKbps: 200).lossyBitrateKbps, 192)
        XCTAssertEqual(ExportEncoding(format: .aac, lossyBitrateKbps: 9_999).lossyBitrateKbps, 320)
        XCTAssertEqual(ExportEncoding(format: .aac, lossyBitrateKbps: 0).lossyBitrateKbps, 128)
        XCTAssertEqual(ExportEncoding(format: .wav).summary, "WAV (BWF)")
        XCTAssertTrue(ExportEncoding(format: .aac, lossyBitrateKbps: 256).summary.contains("256 kbps"))
    }

    func testPlannerUsesTheChosenExtension() throws {
        let session = try makeSession()
        let out = Fixtures.makeTempDirectory("format-out")
        let stems = [StemPlan(outputName: "Piano", trackNumbers: [3])]

        for format in ExportFormat.allCases {
            let job = ExportJob(
                outputFolder: out,
                sessionName: "S",
                encoding: ExportEncoding(format: format)
            )
            let plan = ExportPlanner.plan(session: session, stems: stems, job: job)
            XCTAssertEqual(plan.encoding.format, format)
            XCTAssertEqual(plan.items[0].fileName, "S - 03 - Piano.\(format.fileExtension)")
        }
    }

    func testPreferencesRoundTripTheEncoding() {
        let defaults = UserDefaults(suiteName: "encoding-prefs-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.exportEncoding.format, .wav)

        preferences.exportEncoding = ExportEncoding(format: .aac, lossyBitrateKbps: 192)
        XCTAssertEqual(preferences.exportEncoding.format, .aac)
        XCTAssertEqual(preferences.exportEncoding.lossyBitrateKbps, 192)
    }

    // MARK: Encoding

    #if canImport(AVFoundation)

    func testLosslessExportRoundTripsTheSamples() throws {
        var session = try makeSession(channels: 4, frames: 4_000)
        session.trimInFrames = 0
        session.trimOutFrames = 4_000

        let out = Fixtures.makeTempDirectory("flac-out")
        let job = ExportJob(
            outputFolder: out,
            sessionName: "S",
            encoding: ExportEncoding(format: .flac)
        )
        let plan = ExportPlanner.plan(
            session: session,
            stems: [StemPlan(outputName: "Piano", trackNumbers: [3])],
            job: job
        )
        let result = try ExportEngine(session: session, plan: plan).run()

        let file = result.stems[0].fileURL
        XCTAssertEqual(file.pathExtension, "flac")
        XCTAssertGreaterThan(result.stems[0].byteCount, 0)
        XCTAssertEqual(result.stems[0].durationSamples, 4_000)

        let decoded = try AVAudioFile(forReading: file)
        XCTAssertEqual(decoded.fileFormat.channelCount, 1)
        XCTAssertEqual(decoded.fileFormat.sampleRate, session.sampleRate)
        XCTAssertEqual(decoded.length, 4_000)

        let buffer = AVAudioPCMBuffer(
            pcmFormat: decoded.processingFormat,
            frameCapacity: AVAudioFrameCount(decoded.length)
        )!
        try decoded.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        // Channel 3 is index 2, normalised against 24-bit full scale.
        let expected = Float(Double(Fixtures.sampleValue(channel: 2, frame: 0)) / Double(1 << 23))
        XCTAssertEqual(samples[0], expected, accuracy: 1e-5)
    }

    func testLossyExportWritesAPlayableFileSmallerThanTheSource() throws {
        var session = try makeSession(channels: 4, frames: 48_000)
        session.trimInFrames = 0
        session.trimOutFrames = 48_000

        let out = Fixtures.makeTempDirectory("aac-out")
        let job = ExportJob(
            outputFolder: out,
            sessionName: "S",
            encoding: ExportEncoding(format: .aac, lossyBitrateKbps: 128)
        )
        let plan = ExportPlanner.plan(
            session: session,
            stems: [StemPlan(outputName: "Overheads", trackNumbers: [1, 2])],
            job: job
        )
        let result = try ExportEngine(session: session, plan: plan).run()

        let file = result.stems[0].fileURL
        XCTAssertEqual(file.pathExtension, "m4a")
        XCTAssertGreaterThan(result.stems[0].byteCount, 0)
        // 1 second of 24-bit stereo is 288 kB; 128 kbps AAC has to be far smaller.
        XCTAssertLessThan(result.stems[0].byteCount, 100_000)

        let decoded = try AVAudioFile(forReading: file)
        XCTAssertEqual(decoded.fileFormat.channelCount, 2)
        XCTAssertGreaterThan(decoded.length, 0)
    }

    func testEncoderSettingsStayInsideWhatTheCodecsAccept() {
        let float = AudioFormat(channelCount: 1, sampleRate: 48_000, bitDepth: 32, isFloat: true)
        XCTAssertEqual(EncodedStemWriter.losslessBitDepth(for: float), 24)
        XCTAssertEqual(
            EncodedStemWriter.losslessBitDepth(
                for: AudioFormat(channelCount: 1, sampleRate: 48_000, bitDepth: 16)
            ),
            16
        )

        // A mono stem can't take the top stereo bitrate.
        XCTAssertEqual(EncodedStemWriter.aacBitsPerSecond(kbps: 320, channelCount: 1), 256_000)
        XCTAssertEqual(EncodedStemWriter.aacBitsPerSecond(kbps: 320, channelCount: 2), 320_000)
    }

    #endif
}
