import Foundation

public enum ExportError: LocalizedError {
    case emptySelection
    case invalidTrim
    case couldNotCreateFolder(URL)
    case couldNotOpenSource(URL)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Every track is excluded — there’s nothing to export."
        case .invalidTrim:
            return "The trim selection is empty. Move the In or Out handle and try again."
        case .couldNotCreateFolder(let url):
            return "Couldn’t create “\(url.lastPathComponent)” in the destination folder."
        case .couldNotOpenSource(let url):
            return "Couldn’t read \(url.lastPathComponent)."
        }
    }
}

/// Live state of a running export.
public struct ExportProgress: Sendable {
    public var framesWritten: Int64
    public var totalFrames: Int64
    public var stemFractions: [UUID: Double]
    public var finishedStems: Set<UUID>
    public var elapsed: TimeInterval

    public init(
        framesWritten: Int64,
        totalFrames: Int64,
        stemFractions: [UUID: Double],
        finishedStems: Set<UUID>,
        elapsed: TimeInterval
    ) {
        self.framesWritten = framesWritten
        self.totalFrames = totalFrames
        self.stemFractions = stemFractions
        self.finishedStems = finishedStems
        self.elapsed = elapsed
    }

    public var fractionComplete: Double {
        totalFrames > 0 ? min(1, Double(framesWritten) / Double(totalFrames)) : 0
    }

    public var estimatedSecondsRemaining: TimeInterval? {
        let fraction = fractionComplete
        guard fraction > 0.01, elapsed > 0.3 else { return nil }
        return elapsed / fraction - elapsed
    }
}

/// Renders every selected stem, trimmed and gain-adjusted, in a single pass over
/// the source.
///
/// The 32 channels live interleaved in one file, so reading the source once per
/// stem would mean reading the same multi-gigabyte recording thirty-odd times.
/// Instead there is exactly one sequential read, running a block ahead of the work
/// so the disk and the cores are busy at the same time. Each block is split into
/// every output channel at once — divided across cores by frame range, so a source
/// frame is pulled from memory once rather than once per stem — with gain applied
/// in that same pass, and the results are handed to per-stem writers that only ever
/// write. Trim is byte-offset arithmetic against the source, so nothing is decoded
/// or re-encoded, and a stem that spans two parts is one continuous write with no
/// seam.
public final class ExportEngine {

    /// Source bytes per read. Big enough to keep the disk streaming, small enough
    /// that 30-odd output buffers per block stay comfortably in memory.
    public var blockByteTarget: Int = 8 * 1024 * 1024

    private let session: Session
    private let plan: ExportPlan

    public init(session: Session, plan: ExportPlan) {
        self.session = session
        self.plan = plan
    }

    public func run(
        progress: (@Sendable (ExportProgress) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> ExportResult {

        let items = plan.items
        guard !items.isEmpty else { throw ExportError.emptySelection }
        guard session.hasValidTrim else { throw ExportError.invalidTrim }

        let format = session.format
        let bytesPerFrame = format.bytesPerFrame
        let bytesPerSample = format.bytesPerSample
        let startFrame = session.trimInFrames
        let endFrame = session.trimOutFrames
        let totalFrames = endFrame - startFrame

        let fm = FileManager.default
        if !fm.fileExists(atPath: plan.folder.path) {
            do {
                try fm.createDirectory(at: plan.folder, withIntermediateDirectories: true)
            } catch {
                throw ExportError.couldNotCreateFolder(plan.folder)
            }
        }

        // MARK: Writers

        let stemCount = items.count
        var writers: [WAVWriter] = []
        writers.reserveCapacity(stemCount)
        var queues: [DispatchQueue] = []
        queues.reserveCapacity(stemCount)

        func tearDown() {
            queues.forEach { $0.sync {} }
            writers.forEach { $0.cancelAndRemove() }
        }

        for item in items {
            let stemFormat = AudioFormat(
                channelCount: item.stem.channelCount,
                sampleRate: format.sampleRate,
                bitDepth: format.bitDepth,
                isFloat: format.isFloat
            )
            do {
                let writer = try WAVWriter(
                    url: item.url,
                    format: stemFormat,
                    broadcast: broadcastMetadata(for: item.stem, startFrame: startFrame)
                )
                writers.append(writer)
                queues.append(DispatchQueue(label: "stem-writer.\(item.id.uuidString)", qos: .userInitiated))
            } catch {
                tearDown()
                throw error
            }
        }

        // MARK: Shared, per-stem state touched only at distinct indices

        let layout = StemLayout(stems: items.map(\.stem))
        var clipCounts = [Int64](repeating: 0, count: stemCount)
        var firstClipFrame = [Int64](repeating: -1, count: stemCount)

        let errorBox = ErrorBox()
        // At most a couple of blocks of output buffers are alive at once, which is
        // what keeps peak memory flat regardless of how long the session is.
        let inflight = DispatchSemaphore(value: 2)
        let started = Date()
        var framesDone: Int64 = 0
        var cancelled = false

        let blockFrames = max(1, Int64(blockByteTarget / max(bytesPerFrame, 1)))
        let blockBytes = Int(blockFrames) * bytesPerFrame
        let parts = session.includedParts

        // MARK: The single read pass
        //
        // Every block the export will need is worked out up front, so a source
        // that can't be opened fails before a single stem file is created, and so
        // the reader can run ahead of the de-interleave without coordinating with it.

        // Grouped by part, and each job holds its descriptor, so the files stay open
        // for the whole pass.
        var jobs: [[ReadJob]] = []
        for part in parts {
            let partStart = part.startOffsetInSession
            let partEnd = part.endOffsetInSession
            guard partEnd > startFrame, partStart < endFrame else { continue }

            let fromFrameInPart = max(0, startFrame - partStart)
            let toFrameInPart = min(part.frameCount, endFrame - partStart)
            guard toFrameInPart > fromFrameInPart else { continue }

            guard let fd = ReadFD(url: part.url) else {
                tearDown()
                throw ExportError.couldNotOpenSource(part.url)
            }
            fd.adviseSequential()

            var partJobs: [ReadJob] = []
            var cursor = fromFrameInPart
            while cursor < toFrameInPart {
                let frames = min(blockFrames, toFrameInPart - cursor)
                partJobs.append(ReadJob(
                    fd: fd,
                    byteOffset: part.dataOffset + cursor * Int64(bytesPerFrame),
                    byteCount: Int(frames) * bytesPerFrame
                ))
                cursor += frames
            }
            jobs.append(partJobs)
        }

        let pipeline = BlockPipeline(parts: jobs, blockBytes: blockBytes)

        // De-interleaving is split across cores by frame range rather than by stem.
        // Splitting by stem meant every worker walked the whole block to pick out
        // one or two channels of each frame, so the source crossed the memory bus
        // once per stem; this way each worker reads its own slice once and fills
        // every stem out of it.
        let workerCount = min(
            max(1, ProcessInfo.processInfo.activeProcessorCount),
            max(1, Int(blockFrames) / Deinterleaver.tileFrames(bytesPerFrame: bytesPerFrame))
        )
        var tallies = (0..<workerCount).map { _ in ClipTally(stemCount: stemCount) }
        let stemFrameBytes = layout.widths.map { $0 * bytesPerSample }

        while let block = pipeline.next() {
            if isCancelled?() == true { cancelled = true; pipeline.recycle(block); break }
            if let error = errorBox.value { pipeline.cancel(); tearDown(); throw error }

            let framesRead = block.byteCount / bytesPerFrame
            guard framesRead > 0 else { pipeline.recycle(block); break }
            let blockStartFrame = framesDone

            // Raw storage per stem, wrapped in Data only once it's filled: the
            // buffers are handed straight to the writers, and zeroing them first
            // would mean touching every output byte twice.
            var storage: [UnsafeMutableRawPointer] = []
            storage.reserveCapacity(stemCount)
            for index in 0..<stemCount {
                storage.append(.allocate(byteCount: max(framesRead * stemFrameBytes[index], 1), alignment: 64))
            }

            let chunks = min(workerCount, max(1, framesRead / Deinterleaver.tileFrames(bytesPerFrame: bytesPerFrame)))
            let chunkFrames = (framesRead + chunks - 1) / chunks
            for index in tallies.indices { tallies[index].reset() }

            storage.withUnsafeBufferPointer { destinations in
                let destinationBase = destinations.baseAddress!
                tallies.withUnsafeMutableBufferPointer { tallyBuffer in
                    let tallyBase = tallyBuffer.baseAddress!
                    let source = UnsafeRawPointer(block.storage)
                    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                        let lower = chunk * chunkFrames
                        let upper = min(lower + chunkFrames, framesRead)
                        guard lower < upper else { return }
                        Deinterleaver.run(
                            source: source,
                            frames: lower..<upper,
                            format: format,
                            layout: layout,
                            destinations: destinationBase,
                            tally: &tallyBase[chunk]
                        )
                    }
                }
            }

            pipeline.recycle(block)

            // Workers each scan their own frame range in order, so the earliest clip
            // in the block is the earliest across their first hits.
            for index in 0..<stemCount {
                var earliest: Int64 = -1
                for tally in tallies {
                    clipCounts[index] += tally.counts[index]
                    let candidate = tally.firstFrames[index]
                    if candidate >= 0, earliest < 0 || candidate < earliest { earliest = candidate }
                }
                if earliest >= 0, firstClipFrame[index] < 0 {
                    firstClipFrame[index] = blockStartFrame + earliest
                }
            }

            // Hand the block's buffers to the per-stem writers. They only ever
            // write; the next source block is already being read while these land.
            inflight.wait()
            let group = DispatchGroup()
            for index in 0..<stemCount {
                // Freed the way it was allocated — `.free` would not match
                // `UnsafeMutableRawPointer.allocate`'s aligned allocation.
                let payload = Data(
                    bytesNoCopy: storage[index],
                    count: framesRead * stemFrameBytes[index],
                    deallocator: .custom { pointer, _ in pointer.deallocate() }
                )
                let writer = writers[index]
                queues[index].async(group: group) {
                    guard errorBox.value == nil else { return }
                    do { try writer.write(payload) } catch { errorBox.set(error) }
                }
            }
            group.notify(queue: .global(qos: .utility)) { inflight.signal() }

            framesDone += Int64(framesRead)

            if let progress {
                let fraction = totalFrames > 0 ? Double(framesDone) / Double(totalFrames) : 0
                progress(ExportProgress(
                    framesWritten: framesDone,
                    totalFrames: totalFrames,
                    stemFractions: Dictionary(uniqueKeysWithValues: items.map { ($0.id, fraction) }),
                    finishedStems: [],
                    elapsed: Date().timeIntervalSince(started)
                ))
            }
        }

        pipeline.cancel()

        // Let every queued write land before any header is patched.
        queues.forEach { $0.sync {} }

        if let error = errorBox.value {
            writers.forEach { $0.cancelAndRemove() }
            throw error
        }

        if cancelled {
            writers.forEach { $0.cancelAndRemove() }
            return ExportResult(
                folder: plan.folder,
                stems: [],
                warnings: ["Export cancelled — no files were left behind."],
                trimmedDuration: session.trimmedDuration,
                sourceDuration: session.totalDuration,
                wasCancelled: true
            )
        }

        // MARK: Finalise

        var exported: [ExportedStem] = []
        var warnings: [String] = []
        for (index, item) in items.enumerated() {
            let writer = writers[index]
            let frames = try writer.finalize()
            let clipFrame = firstClipFrame[index]
            let stem = ExportedStem(
                id: item.id,
                outputName: item.stem.outputName,
                fileURL: item.url,
                sourceTrackNumbers: item.stem.trackNumbers,
                durationSamples: frames,
                byteCount: writer.byteCount,
                isStereo: item.stem.isStereo,
                firstClipAtSeconds: clipFrame >= 0
                    ? Timecode.seconds(forFrames: clipFrame, sampleRate: format.sampleRate)
                    : nil,
                clippedSampleCount: clipCounts[index]
            )
            exported.append(stem)

            if stem.didClip, let at = stem.firstClipAtSeconds {
                let offset = Timecode.string(from: at + session.trimInSeconds)
                warnings.append("\(item.fileName) clipped briefly at \(offset) — check gain on that channel")
            }
        }

        if let expected = exported.first?.durationSamples,
           exported.contains(where: { $0.durationSamples != expected }) {
            warnings.append("Some stems came out at different lengths — the source parts may not line up.")
        }

        progress?(ExportProgress(
            framesWritten: totalFrames,
            totalFrames: totalFrames,
            stemFractions: Dictionary(uniqueKeysWithValues: items.map { ($0.id, 1.0) }),
            finishedStems: Set(items.map(\.id)),
            elapsed: Date().timeIntervalSince(started)
        ))

        return ExportResult(
            folder: plan.folder,
            stems: exported,
            warnings: warnings,
            trimmedDuration: session.trimmedDuration,
            sourceDuration: session.totalDuration
        )
    }

    // MARK: BWF metadata

    /// Each stem carries enough of the source's identity to be traced back to the
    /// session it was cut from.
    private func broadcastMetadata(for stem: StemPlan, startFrame: Int64) -> BroadcastMetadata {
        var meta = BroadcastMetadata()
        let sources = session.includedParts.map { $0.url.lastPathComponent }.joined(separator: ", ")
        meta.description = "\(stem.outputName) — \(stem.sourceLabel) of \(session.name)"
        meta.originator = "Stem Exporter"
        meta.originatorReference = String(sources.prefix(32))

        let sourceMeta = session.includedParts.first?.broadcast
        if let sourceMeta, !sourceMeta.originationDate.isEmpty {
            meta.originationDate = sourceMeta.originationDate
            meta.originationTime = sourceMeta.originationTime
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let modified = session.includedParts.first
                .flatMap { try? $0.url.resourceValues(forKeys: [.contentModificationDateKey]) }?
                .contentModificationDate
            let date = modified ?? Date()
            formatter.dateFormat = "yyyy-MM-dd"
            meta.originationDate = formatter.string(from: date)
            formatter.dateFormat = "HH:mm:ss"
            meta.originationTime = formatter.string(from: date)
        }

        // Push the source's timestamp forward by the trim, so the stem still lines
        // up on a timeline that respects the original clock.
        meta.timeReference = (sourceMeta?.timeReference ?? 0) &+ UInt64(max(0, startFrame))
        meta.codingHistory = "A=PCM,F=\(Int(session.sampleRate)),W=\(session.bitDepth),M=\(stem.isStereo ? "stereo" : "mono"),T=Stem Exporter\r\n"
        return meta
    }
}

/// First error wins; read from the reader thread between blocks.
final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var value: Error? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if stored == nil { stored = error }
    }
}
