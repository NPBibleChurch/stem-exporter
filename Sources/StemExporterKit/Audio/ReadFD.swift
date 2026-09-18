import Foundation

/// A read-only file descriptor that only ever does positional reads.
///
/// `pread` doesn't touch the descriptor's shared offset, so one of these can be
/// read from several threads at once — which is what lets peak analysis fan its
/// buckets out across cores, and lets the export read the next block while the
/// current one is still being de-interleaved.
final class ReadFD: @unchecked Sendable {
    let fd: Int32

    init?(url: URL) {
        let opened = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard opened >= 0 else { return nil }
        fd = opened
    }

    deinit { close(fd) }

    /// Ask the kernel to read ahead: the export walks each part front to back.
    func adviseSequential() {
        _ = fcntl(fd, F_RDAHEAD, 1)
    }

    /// Fill `count` bytes at `offset`, looping over short reads. Returns the number
    /// of bytes actually read, which is less than `count` only at end of file.
    func readFully(into buffer: UnsafeMutableRawPointer, count: Int, at offset: Int64) -> Int {
        var done = 0
        while done < count {
            let got = pread(fd, buffer.advanced(by: done), count - done, off_t(offset) + off_t(done))
            if got > 0 {
                done += got
            } else if got == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return done
    }
}
