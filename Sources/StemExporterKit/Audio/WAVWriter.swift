import Foundation

/// Streaming writer for BWF (Broadcast Wave) files.
///
/// The header is laid down first with placeholder sizes, audio is appended in
/// blocks as the export engine produces it, and the sizes are patched in at the
/// end. A `JUNK` chunk sized exactly like `ds64` is reserved up front so a file
/// that turns out to be larger than 4 GB can be promoted to RF64 in place,
/// without rewriting the audio that is already on disk.
///
/// Not internally synchronised: each stem gets its own writer driven from its own
/// serial queue.
public final class WAVWriter {

    public let url: URL
    public let format: AudioFormat

    private let handle: FileHandle
    private var headerByteCount: Int64 = 0
    private var bytesWritten: Int64 = 0
    private var junkChunkOffset: Int64 = 0
    private var dataSizeFieldOffset: Int64 = 0
    private var finalized = false

    /// Size of the reserved ds64 payload: riffSize + dataSize + sampleCount + tableLength.
    private static let ds64PayloadSize = 28

    public init(url: URL, format: AudioFormat, broadcast: BroadcastMetadata? = nil) throws {
        self.url = url
        self.format = format

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw WAVError.readFailed(url)
        }
        self.handle = try FileHandle(forWritingTo: url)

        try writeHeader(broadcast: broadcast)
    }

    // MARK: Header

    private func writeHeader(broadcast: BroadcastMetadata?) throws {
        var header = Data()
        header.appendASCII("RIFF")
        header.appendUInt32(0)              // patched in finalize()
        header.appendASCII("WAVE")

        junkChunkOffset = Int64(header.count)
        header.appendASCII("JUNK")
        header.appendUInt32(UInt32(Self.ds64PayloadSize))
        header.append(Data(repeating: 0, count: Self.ds64PayloadSize))

        header.appendASCII("fmt ")
        header.appendUInt32(16)
        header.appendUInt16(format.isFloat ? 0x0003 : 0x0001)
        header.appendUInt16(UInt16(format.channelCount))
        header.appendUInt32(UInt32(format.sampleRate))
        header.appendUInt32(UInt32(format.sampleRate) * UInt32(format.bytesPerFrame))
        header.appendUInt16(UInt16(format.bytesPerFrame))
        header.appendUInt16(UInt16(format.bitDepth))

        if let broadcast {
            header.append(Self.bextChunk(broadcast))
        }

        header.appendASCII("data")
        dataSizeFieldOffset = Int64(header.count)
        header.appendUInt32(0)              // patched in finalize()

        headerByteCount = Int64(header.count)
        try handle.seek(toOffset: 0)
        handle.write(header)
    }

    /// Build a `bext` chunk. Fixed part is 602 bytes, coding history follows.
    static func bextChunk(_ meta: BroadcastMetadata) -> Data {
        var body = Data()
        body.appendFixedASCII(meta.description, length: 256)
        body.appendFixedASCII(meta.originator, length: 32)
        body.appendFixedASCII(meta.originatorReference, length: 32)
        body.appendFixedASCII(meta.originationDate, length: 10)
        body.appendFixedASCII(meta.originationTime, length: 8)
        body.appendUInt32(UInt32(truncatingIfNeeded: meta.timeReference))
        body.appendUInt32(UInt32(truncatingIfNeeded: meta.timeReference >> 32))
        body.appendUInt16(1)                                 // BWF version 1
        body.append(Data(repeating: 0, count: 64))           // UMID
        body.append(Data(repeating: 0, count: 190))          // reserved
        if !meta.codingHistory.isEmpty {
            body.append(Data(meta.codingHistory.utf8))
        }
        if body.count % 2 == 1 { body.append(0) }

        var chunk = Data()
        chunk.appendASCII("bext")
        chunk.appendUInt32(UInt32(body.count))
        chunk.append(body)
        return chunk
    }

    // MARK: Writing

    /// Append raw interleaved PCM bytes, already in this writer's format.
    public func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        bytesWritten += Int64(data.count)
    }

    public var frameCount: Int64 {
        format.bytesPerFrame > 0 ? bytesWritten / Int64(format.bytesPerFrame) : 0
    }

    public var byteCount: Int64 { bytesWritten }

    /// Patch the sizes in and close. Returns the number of frames written.
    @discardableResult
    public func finalize() throws -> Int64 {
        guard !finalized else { return frameCount }
        finalized = true

        // WAV pads the data chunk to an even byte count.
        if bytesWritten % 2 == 1 {
            handle.write(Data([0]))
        }

        let riffSize = headerByteCount + bytesWritten + (bytesWritten % 2) - 8
        if riffSize > 0xFFFF_FFFE {
            try promoteToRF64(riffSize: riffSize)
        } else {
            try patchUInt32(at: 4, UInt32(riffSize))
            try patchUInt32(at: dataSizeFieldOffset, UInt32(bytesWritten))
        }

        try handle.close()
        return frameCount
    }

    /// Rewrite the reserved JUNK chunk as ds64 and flip the header to RF64.
    private func promoteToRF64(riffSize: Int64) throws {
        try patchASCII(at: 0, "RF64")
        try patchUInt32(at: 4, 0xFFFF_FFFF)
        try patchASCII(at: junkChunkOffset, "ds64")

        var ds64 = Data()
        ds64.appendUInt64(UInt64(riffSize))
        ds64.appendUInt64(UInt64(bytesWritten))
        ds64.appendUInt64(UInt64(frameCount))
        ds64.appendUInt32(0)                      // no chunk-size table
        try handle.seek(toOffset: UInt64(junkChunkOffset + 8))
        handle.write(ds64)

        try patchUInt32(at: dataSizeFieldOffset, 0xFFFF_FFFF)
    }

    /// Abandon a partially written file, e.g. after a cancelled export.
    public func cancelAndRemove() {
        finalized = true
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    private func patchUInt32(at offset: Int64, _ value: UInt32) throws {
        var d = Data()
        d.appendUInt32(value)
        try handle.seek(toOffset: UInt64(offset))
        handle.write(d)
    }

    private func patchASCII(at offset: Int64, _ value: String) throws {
        var d = Data()
        d.appendASCII(value)
        try handle.seek(toOffset: UInt64(offset))
        handle.write(d)
    }
}

// MARK: - Little-endian append helpers

extension Data {
    mutating func appendASCII(_ s: String) {
        append(contentsOf: Array(s.utf8))
    }

    mutating func appendFixedASCII(_ s: String, length: Int) {
        var bytes = Array(s.utf8.prefix(length))
        bytes.append(contentsOf: Array(repeating: UInt8(0), count: length - bytes.count))
        append(contentsOf: bytes)
    }

    mutating func appendUInt16(_ v: UInt16) {
        append(contentsOf: [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)])
    }

    mutating func appendUInt32(_ v: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: v),
            UInt8(truncatingIfNeeded: v >> 8),
            UInt8(truncatingIfNeeded: v >> 16),
            UInt8(truncatingIfNeeded: v >> 24),
        ])
    }

    mutating func appendUInt64(_ v: UInt64) {
        appendUInt32(UInt32(truncatingIfNeeded: v))
        appendUInt32(UInt32(truncatingIfNeeded: v >> 32))
    }
}
