import Foundation

/// What the export engine needs from whatever is writing one stem: bytes in,
/// blocks at a time, and a frame count out at the end.
///
/// Writers are driven from one serial queue each, so nothing here has to be
/// internally synchronised.
public protocol StemWriter: AnyObject {
    var url: URL { get }
    /// Bytes the file holds. Only meaningful once `finalize()` has returned.
    var byteCount: Int64 { get }

    /// Append a block of interleaved PCM in the stem's source format.
    func write(_ data: Data) throws
    /// Close the file out and return the number of frames written.
    @discardableResult
    func finalize() throws -> Int64
    /// Abandon a partially written file, e.g. after a cancelled export.
    func cancelAndRemove()
}

extension WAVWriter: StemWriter {}

/// Builds the writer for one stem from the chosen encoding.
public enum StemWriterFactory {

    /// - Parameters:
    ///   - format: the stem's own PCM format — source depth and rate, stem channel count.
    ///   - broadcast: BWF metadata, used only by the pass-through WAV path.
    public static func make(
        url: URL,
        format: AudioFormat,
        encoding: ExportEncoding,
        broadcast: BroadcastMetadata? = nil
    ) throws -> StemWriter {
        if encoding.format.isPassthrough {
            return try WAVWriter(url: url, format: format, broadcast: broadcast)
        }
        #if canImport(AVFoundation)
        return try EncodedStemWriter(url: url, format: format, encoding: encoding)
        #else
        throw ExportError.encoderUnavailable(encoding.format.title)
        #endif
    }
}
