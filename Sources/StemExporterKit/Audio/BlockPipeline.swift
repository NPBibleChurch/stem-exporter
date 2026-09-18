import Foundation

/// One block of source audio the export still has to read.
struct ReadJob {
    var fd: ReadFD
    var byteOffset: Int64
    var byteCount: Int
}

/// Streams source blocks off disk one step ahead of whoever is consuming them.
///
/// Reading and de-interleaving used to take turns: read eight megabytes, split
/// them into stems, go back to the disk. A background reader keeps the next block
/// coming while the current one is still being split, so the read hides behind the
/// work instead of adding to it — which matters most on the external drives these
/// recordings usually arrive on.
///
/// Buffers are allocated once and recycled, so a multi-hour export doesn't churn
/// gigabytes of short-lived allocations.
final class BlockPipeline: @unchecked Sendable {

    final class Block {
        let storage: UnsafeMutableRawPointer
        var byteCount: Int = 0
        init(capacity: Int) {
            storage = .allocate(byteCount: max(capacity, 1), alignment: 64)
        }
        deinit { storage.deallocate() }
    }

    private let condition = NSCondition()
    private var free: [Block]
    private var ready: [Block] = []
    private var producerDone = false
    private var cancelled = false

    /// Jobs arrive grouped by source part. A part that runs out of bytes early is
    /// abandoned and the next one is read anyway, which is what the engine did when
    /// it opened each part in turn.
    init(parts: [[ReadJob]], blockBytes: Int, depth: Int = 3) {
        free = (0..<max(2, depth)).map { _ in Block(capacity: blockBytes) }
        DispatchQueue(label: "stem-reader", qos: .userInitiated).async { [self] in
            outer: for part in parts {
                for job in part {
                    guard let block = takeFree() else { break outer }
                    block.byteCount = job.fd.readFully(
                        into: block.storage, count: job.byteCount, at: job.byteOffset
                    )
                    let short = block.byteCount < job.byteCount
                    postReady(block)
                    if short { continue outer }
                }
            }
            condition.lock()
            producerDone = true
            condition.broadcast()
            condition.unlock()
        }
    }

    /// The next block of source, or nil once the source is exhausted or cancelled.
    /// Hand it back with `recycle` when its contents are no longer needed.
    func next() -> Block? {
        condition.lock()
        defer { condition.unlock() }
        while ready.isEmpty && !producerDone && !cancelled {
            condition.wait()
        }
        guard !cancelled, !ready.isEmpty else { return nil }
        return ready.removeFirst()
    }

    func recycle(_ block: Block) {
        condition.lock()
        free.append(block)
        condition.broadcast()
        condition.unlock()
    }

    /// Stop the reader and wake anyone waiting on it.
    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    private func takeFree() -> Block? {
        condition.lock()
        defer { condition.unlock() }
        while free.isEmpty && !cancelled {
            condition.wait()
        }
        guard !cancelled else { return nil }
        return free.removeLast()
    }

    private func postReady(_ block: Block) {
        condition.lock()
        ready.append(block)
        condition.broadcast()
        condition.unlock()
    }
}
