import Foundation

public enum WAVError: LocalizedError, Equatable {
    case notARIFFFile(URL)
    case notAWAVEFile(URL)
    case missingChunk(String, URL)
    case unsupportedFormat(String, URL)
    case truncated(URL)
    case readFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .notARIFFFile(let u):
            return "\(u.lastPathComponent) is not a RIFF/RF64 file."
        case .notAWAVEFile(let u):
            return "\(u.lastPathComponent) is a RIFF file but not WAVE audio."
        case .missingChunk(let c, let u):
            return "\(u.lastPathComponent) has no ‘\(c)’ chunk."
        case .unsupportedFormat(let why, let u):
            return "\(u.lastPathComponent): \(why)"
        case .truncated(let u):
            return "\(u.lastPathComponent) ends in the middle of its audio data."
        case .readFailed(let u):
            return "Could not read \(u.lastPathComponent)."
        }
    }
}

/// Broadcast-Wave metadata carried in the `bext` chunk, kept so exported stems can
/// point back at the session they came from.
public struct BroadcastMetadata: Equatable, Hashable, Sendable {
    public var description: String = ""
    public var originator: String = ""
    public var originatorReference: String = ""
    public var originationDate: String = ""   // YYYY-MM-DD
    public var originationTime: String = ""   // HH:MM:SS
    /// Sample count since midnight of the first sample in the file.
    public var timeReference: UInt64 = 0
    public var codingHistory: String = ""

    public init() {}
}

/// A WAV file opened by walking its RIFF structure by hand.
///
/// The walk is deliberately generic: every chunk is stepped over by its declared
/// size and only `fmt `, `data`, `bext` and (for RF64) `ds64` are looked at. JUNK,
/// iXML, cue, LIST and anything else a recorder decides to write are skipped
/// without being parsed, which is what keeps this working across firmware versions.
///
/// Working from byte offsets rather than `AVAudioFile` is also what makes
/// multi-gigabyte sources practical: nothing is decoded to open a file, and the
/// export engine reads exact byte ranges out of the `data` chunk.
public struct WAVFile: Equatable, Hashable, Sendable {
    public let url: URL
    public let format: AudioFormat
    /// Byte offset of the first byte of audio (the `data` chunk payload).
    public let dataOffset: Int64
    public let dataByteCount: Int64
    public let broadcast: BroadcastMetadata?
    public let isRF64: Bool

    public var frameCount: Int64 {
        Int64(format.bytesPerFrame) > 0 ? dataByteCount / Int64(format.bytesPerFrame) : 0
    }

    public var duration: TimeInterval {
        format.sampleRate > 0 ? Double(frameCount) / format.sampleRate : 0
    }

    public var fileSize: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Opening

    public static func open(_ url: URL) throws -> WAVFile {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw WAVError.readFailed(url)
        }
        defer { try? handle.close() }
        return try parse(handle: handle, url: url)
    }

    static func parse(handle: FileHandle, url: URL) throws -> WAVFile {
        let physicalSize = Int64((try? handle.seekToEnd()) ?? 0)
        try handle.seek(toOffset: 0)

        guard let header = try handle.read(upToCount: 12), header.count == 12 else {
            throw WAVError.notARIFFFile(url)
        }
        let riffID = fourCC(header, 0)
        guard riffID == "RIFF" || riffID == "RF64" else { throw WAVError.notARIFFFile(url) }
        guard fourCC(header, 8) == "WAVE" else { throw WAVError.notAWAVEFile(url) }
        let isRF64 = riffID == "RF64"

        var format: AudioFormat?
        var dataOffset: Int64 = -1
        var declaredDataSize: Int64 = -1
        var rf64DataSize: Int64 = -1
        var broadcast: BroadcastMetadata?

        var cursor: Int64 = 12
        while cursor + 8 <= physicalSize {
            try handle.seek(toOffset: UInt64(cursor))
            guard let head = try handle.read(upToCount: 8), head.count == 8 else { break }
            let id = fourCC(head, 0)
            let rawSize = readUInt32(head, 4)
            let payload = cursor + 8

            // RF64 signals "look in ds64" with an all-ones 32-bit size.
            var size = Int64(rawSize)
            if isRF64 && rawSize == 0xFFFF_FFFF {
                size = (id == "data" && rf64DataSize >= 0) ? rf64DataSize : (physicalSize - payload)
            }

            switch id {
            case "ds64":
                if let body = try readPayload(handle, at: payload, count: min(size, 64)), body.count >= 28 {
                    rf64DataSize = Int64(bitPattern: readUInt64(body, 8))
                }
            case "fmt ":
                guard let body = try readPayload(handle, at: payload, count: min(size, 64)), body.count >= 16 else {
                    throw WAVError.missingChunk("fmt ", url)
                }
                format = try parseFormat(body, url: url)
            case "bext":
                if let body = try readPayload(handle, at: payload, count: min(size, 1024)) {
                    broadcast = parseBext(body)
                }
            case "data":
                dataOffset = payload
                declaredDataSize = size
            default:
                break
            }

            // Chunks are word-aligned: an odd-sized chunk is followed by one pad byte.
            let advance = size + (size % 2)
            guard advance >= 0 else { break }
            cursor = payload + advance
            // A bogus size shouldn't spin us forever.
            if cursor <= payload && size != 0 { break }
        }

        guard let format else { throw WAVError.missingChunk("fmt ", url) }
        guard dataOffset >= 0 else { throw WAVError.missingChunk("data", url) }
        guard format.bytesPerFrame > 0 else {
            throw WAVError.unsupportedFormat("zero-width audio frames", url)
        }

        // Recorders that are interrupted mid-write can leave a data size that
        // overshoots the bytes actually on disk. Trust the file, not the header.
        let available = physicalSize - dataOffset
        var dataSize = declaredDataSize
        if dataSize <= 0 || dataSize > available { dataSize = max(0, available) }
        // Never hand back a partial final frame.
        dataSize -= dataSize % Int64(format.bytesPerFrame)

        return WAVFile(
            url: url,
            format: format,
            dataOffset: dataOffset,
            dataByteCount: dataSize,
            broadcast: broadcast,
            isRF64: isRF64
        )
    }

    // MARK: Chunk parsing

    private static func parseFormat(_ body: Data, url: URL) throws -> AudioFormat {
        let tag = readUInt16(body, 0)
        let channels = Int(readUInt16(body, 2))
        let sampleRate = Double(readUInt32(body, 4))
        var bits = Int(readUInt16(body, 14))

        var isFloat = false
        switch tag {
        case 0x0001:
            isFloat = false
        case 0x0003:
            isFloat = true
        case 0xFFFE:
            // WAVE_FORMAT_EXTENSIBLE: the real format lives in the sub-format GUID,
            // whose first two bytes mirror the plain format tags above.
            if body.count >= 26 {
                let valid = Int(readUInt16(body, 18))
                if valid > 0 { bits = valid }
                let sub = readUInt16(body, 24)
                isFloat = (sub == 0x0003)
                if sub != 0x0001 && sub != 0x0003 {
                    throw WAVError.unsupportedFormat("compressed audio is not supported", url)
                }
            }
        default:
            throw WAVError.unsupportedFormat("compressed audio (format 0x\(String(tag, radix: 16))) is not supported", url)
        }

        guard channels > 0, sampleRate > 0, bits > 0 else {
            throw WAVError.unsupportedFormat("its ‘fmt ’ chunk is malformed", url)
        }
        guard [8, 16, 24, 32, 64].contains(bits) else {
            throw WAVError.unsupportedFormat("\(bits)-bit audio is not supported", url)
        }

        return AudioFormat(channelCount: channels, sampleRate: sampleRate, bitDepth: bits, isFloat: isFloat)
    }

    private static func parseBext(_ body: Data) -> BroadcastMetadata {
        var meta = BroadcastMetadata()
        func string(_ offset: Int, _ length: Int) -> String {
            guard body.count >= offset + length else { return "" }
            let slice = body.subdata(in: offset..<(offset + length))
            let trimmed = slice.prefix(while: { $0 != 0 })
            return String(data: Data(trimmed), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        meta.description = string(0, 256)
        meta.originator = string(256, 32)
        meta.originatorReference = string(288, 32)
        meta.originationDate = string(320, 10)
        meta.originationTime = string(330, 8)
        if body.count >= 346 {
            let low = UInt64(readUInt32(body, 338))
            let high = UInt64(readUInt32(body, 342))
            meta.timeReference = (high << 32) | low
        }
        if body.count > 602 {
            meta.codingHistory = string(602, body.count - 602)
        }
        return meta
    }

    // MARK: Byte helpers

    private static func readPayload(_ handle: FileHandle, at offset: Int64, count: Int64) throws -> Data? {
        guard count > 0 else { return nil }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: Int(count))
    }

    static func fourCC(_ d: Data, _ i: Int) -> String {
        guard d.count >= i + 4 else { return "" }
        let base = d.startIndex + i
        return String(bytes: d[base..<(base + 4)], encoding: .ascii) ?? ""
    }

    static func readUInt16(_ d: Data, _ i: Int) -> UInt16 {
        guard d.count >= i + 2 else { return 0 }
        let b = d.startIndex + i
        return UInt16(d[b]) | (UInt16(d[b + 1]) << 8)
    }

    static func readUInt32(_ d: Data, _ i: Int) -> UInt32 {
        guard d.count >= i + 4 else { return 0 }
        let b = d.startIndex + i
        return UInt32(d[b]) | (UInt32(d[b + 1]) << 8) | (UInt32(d[b + 2]) << 16) | (UInt32(d[b + 3]) << 24)
    }

    static func readUInt64(_ d: Data, _ i: Int) -> UInt64 {
        UInt64(readUInt32(d, i)) | (UInt64(readUInt32(d, i + 4)) << 32)
    }
}
