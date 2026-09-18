import XCTest
@testable import StemExporterKit

final class WAVFileTests: XCTestCase {

    func testReadsFormatPastUnknownChunks() throws {
        let dir = Fixtures.makeTempDirectory()
        let url = dir.appendingPathComponent("00000001.WAV")
        try Fixtures.writeRawWAV(at: url, channels: 32, frames: 500)

        let wav = try WAVFile.open(url)
        XCTAssertEqual(wav.format.channelCount, 32)
        XCTAssertEqual(wav.format.sampleRate, 48_000)
        XCTAssertEqual(wav.format.bitDepth, 24)
        XCTAssertFalse(wav.format.isFloat)
        XCTAssertEqual(wav.frameCount, 500)
        XCTAssertEqual(wav.format.bytesPerFrame, 96)
    }

    func testReadsBroadcastMetadata() throws {
        let dir = Fixtures.makeTempDirectory()
        let url = dir.appendingPathComponent("a.wav")
        try Fixtures.writeRawWAV(at: url, channels: 2, frames: 100, firstFrameIndex: 0)

        let wav = try WAVFile.open(url)
        XCTAssertEqual(wav.broadcast?.originator, "Fixture Recorder")
        XCTAssertEqual(wav.broadcast?.originationDate, "2026-09-13")
        XCTAssertEqual(wav.broadcast?.timeReference, 1_000_000)
    }

    func testDataOffsetPointsAtRealAudio() throws {
        let dir = Fixtures.makeTempDirectory()
        let url = dir.appendingPathComponent("b.wav")
        try Fixtures.writeRawWAV(at: url, channels: 4, frames: 10)

        let samples = try Fixtures.readAllSamples(url)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0][0], Fixtures.sampleValue(channel: 0, frame: 0))
        XCTAssertEqual(samples[3][9], Fixtures.sampleValue(channel: 3, frame: 9))
    }

    func testRejectsNonRIFF() throws {
        let dir = Fixtures.makeTempDirectory()
        let url = dir.appendingPathComponent("not-audio.wav")
        try Data("this is not a wave file at all".utf8).write(to: url)
        XCTAssertThrowsError(try WAVFile.open(url))
    }

    func testTruncatedDataChunkFallsBackToBytesOnDisk() throws {
        let dir = Fixtures.makeTempDirectory()
        let url = dir.appendingPathComponent("truncated.wav")
        try Fixtures.writeRawWAV(at: url, channels: 2, frames: 1000)

        // Chop the file in half, as an interrupted recorder would leave it.
        let handle = try FileHandle(forWritingTo: url)
        let full = try FileHandle(forReadingFrom: url).seekToEnd()
        try handle.truncate(atOffset: full / 2)
        try handle.close()

        let wav = try WAVFile.open(url)
        XCTAssertLessThan(wav.frameCount, 1000)
        XCTAssertGreaterThan(wav.frameCount, 0)
        // Never reports a partial frame.
        XCTAssertEqual(wav.dataByteCount % Int64(wav.format.bytesPerFrame), 0)
    }

    func testWriterRoundTrip() throws {
        let dir = Fixtures.makeTempDirectory()
        let url = dir.appendingPathComponent("written.wav")
        let format = AudioFormat(channelCount: 2, sampleRate: 48_000, bitDepth: 24)

        var meta = BroadcastMetadata()
        meta.originator = "Stem Exporter"
        meta.timeReference = 42

        let writer = try WAVWriter(url: url, format: format, broadcast: meta)
        var payload = Data(count: 100 * format.bytesPerFrame)
        payload.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            for frame in 0..<100 {
                for channel in 0..<2 {
                    SampleCodec.writeInt(
                        Int32(channel * 1000 + frame),
                        to: base.advanced(by: frame * format.bytesPerFrame + channel * 3),
                        bytes: 3
                    )
                }
            }
        }
        try writer.write(payload)
        let frames = try writer.finalize()
        XCTAssertEqual(frames, 100)

        let read = try WAVFile.open(url)
        XCTAssertEqual(read.format, format)
        XCTAssertEqual(read.frameCount, 100)
        XCTAssertEqual(read.broadcast?.timeReference, 42)
        XCTAssertEqual(read.broadcast?.originator, "Stem Exporter")

        let samples = try Fixtures.readAllSamples(url)
        XCTAssertEqual(samples[1][99], 1099)
    }

    func testSampleCodecRoundTripsEveryDepth() {
        for (bytes, value) in [(1, Int32(-100)), (2, Int32(-30000)), (3, Int32(-8_000_000)), (4, Int32(-2_000_000_000))] {
            var buffer = [UInt8](repeating: 0, count: bytes)
            buffer.withUnsafeMutableBytes { raw in
                SampleCodec.writeInt(value, to: raw.baseAddress!, bytes: bytes)
                let read = SampleCodec.readInt(raw.baseAddress!, bytes: bytes)
                XCTAssertEqual(read, value, "round trip failed at \(bytes) bytes")
            }
        }
    }

    func testGainClampsInsteadOfWrapping() {
        let fullScale = Double(1 << 23)
        let hot = Int32(8_000_000)
        let result = SampleCodec.scaleAndClamp(hot, gain: SampleCodec.linearGain(dB: 12), maxMagnitude: fullScale)
        XCTAssertTrue(result.clipped)
        XCTAssertEqual(result.value, Int32(fullScale - 1))

        let quiet = SampleCodec.scaleAndClamp(1000, gain: SampleCodec.linearGain(dB: -6), maxMagnitude: fullScale)
        XCTAssertFalse(quiet.clipped)
        XCTAssertEqual(quiet.value, 501)  // -6 dB ≈ x0.5012
    }
}
