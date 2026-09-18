import Foundation
import XCTest
@testable import StemExporterKit

/// Builds real WAV files on disk to test against, so the reader and the export
/// engine are exercised over actual bytes rather than mocks.
enum Fixtures {

    /// Always unique: a fixed name would let one run's files leak into the next.
    static func makeTempDirectory(_ name: String = "fixture") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stem-exporter-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A sample value that identifies its channel and frame unambiguously, so a
    /// de-interleaving mistake shows up as a wrong number rather than as noise.
    static func sampleValue(channel: Int, frame: Int) -> Int32 {
        Int32((channel + 1) * 10_000 + frame)
    }

    /// Write a raw 24-bit PCM WAV by hand — including a JUNK chunk and a bext
    /// chunk ahead of the audio — so the reader is tested against a file it
    /// didn't produce itself.
    @discardableResult
    static func writeRawWAV(
        at url: URL,
        channels: Int,
        frames: Int,
        sampleRate: Int = 48_000,
        bitDepth: Int = 24,
        firstFrameIndex: Int = 0,
        valueMaker: ((Int, Int) -> Int32)? = nil
    ) throws -> URL {
        let bytesPerSample = bitDepth / 8
        let bytesPerFrame = bytesPerSample * channels

        var audio = Data(count: frames * bytesPerFrame)
        audio.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let value = valueMaker?(channel, firstFrameIndex + frame)
                        ?? sampleValue(channel: channel, frame: firstFrameIndex + frame)
                    SampleCodec.writeInt(
                        value,
                        to: base.advanced(by: frame * bytesPerFrame + channel * bytesPerSample),
                        bytes: bytesPerSample
                    )
                }
            }
        }

        var file = Data()
        file.appendASCII("RIFF")
        file.appendUInt32(0)                    // patched below
        file.appendASCII("WAVE")

        // A chunk the reader must step over without looking inside.
        file.appendASCII("JUNK")
        file.appendUInt32(40)
        file.append(Data(repeating: 0xAB, count: 40))

        file.appendASCII("fmt ")
        file.appendUInt32(16)
        file.appendUInt16(1)
        file.appendUInt16(UInt16(channels))
        file.appendUInt32(UInt32(sampleRate))
        file.appendUInt32(UInt32(sampleRate * bytesPerFrame))
        file.appendUInt16(UInt16(bytesPerFrame))
        file.appendUInt16(UInt16(bitDepth))

        var bext = BroadcastMetadata()
        bext.originator = "Fixture Recorder"
        bext.originationDate = "2026-09-13"
        bext.originationTime = "09:30:00"
        bext.timeReference = UInt64(firstFrameIndex) + 1_000_000
        file.append(WAVWriter.bextChunk(bext))

        file.appendASCII("data")
        file.appendUInt32(UInt32(audio.count))
        file.append(audio)

        let riffSize = UInt32(file.count - 8)
        file.replaceSubrange(4..<8, with: {
            var d = Data(); d.appendUInt32(riffSize); return d
        }())

        try file.write(to: url)
        return url
    }

    /// Read every sample of a mono or stereo WAV back as integers, per channel.
    static func readAllSamples(_ url: URL) throws -> [[Int32]] {
        let wav = try WAVFile.open(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(wav.dataOffset))
        let data = try handle.read(upToCount: Int(wav.dataByteCount)) ?? Data()

        let channels = wav.format.channelCount
        let bytesPerSample = wav.format.bytesPerSample
        let bytesPerFrame = wav.format.bytesPerFrame
        let frames = data.count / bytesPerFrame

        var result = [[Int32]](repeating: [], count: channels)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for channel in 0..<channels {
                var column = [Int32]()
                column.reserveCapacity(frames)
                for frame in 0..<frames {
                    column.append(SampleCodec.readInt(
                        base.advanced(by: frame * bytesPerFrame + channel * bytesPerSample),
                        bytes: bytesPerSample
                    ))
                }
                result[channel] = column
            }
        }
        return result
    }
}
