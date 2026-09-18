import Foundation

public enum SessionLoadError: LocalizedError {
    case noWAVFiles(URL)
    case unreadableFolder(URL)
    case noUsableFiles(URL)

    public var errorDescription: String? {
        switch self {
        case .noWAVFiles(let url):
            return "There are no WAV files in “\(url.lastPathComponent)”."
        case .unreadableFolder(let url):
            return "“\(url.lastPathComponent)” couldn’t be read."
        case .noUsableFiles(let url):
            return "None of the WAV files in “\(url.lastPathComponent)” could be opened."
        }
    }
}

/// Turns a folder into a session.
///
/// Whatever WAV files sit in the folder are taken as one recording, sorted by
/// filename and concatenated in that order — one file or twenty, with no naming
/// convention required. The single sanity check is that the parts match each
/// other; files that don't are flagged and left out rather than silently merged.
public enum SessionLoader {

    public static func load(folder: URL) throws -> Session {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            throw SessionLoadError.unreadableFolder(folder)
        }

        let wavURLs = contents
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { a, b in
                a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }

        guard !wavURLs.isEmpty else { throw SessionLoadError.noWAVFiles(folder) }

        var warnings: [SessionWarning] = []
        var opened: [(url: URL, wav: WAVFile)] = []

        for url in wavURLs {
            do {
                let wav = try WAVFile.open(url)
                if wav.frameCount == 0 {
                    warnings.append(SessionWarning(
                        severity: .warning,
                        message: "\(url.lastPathComponent) contains no audio and was left out."
                    ))
                    continue
                }
                opened.append((url, wav))
            } catch {
                warnings.append(SessionWarning(
                    severity: .warning,
                    message: error.localizedDescription
                ))
            }
        }

        guard let reference = opened.first else {
            throw SessionLoadError.noUsableFiles(folder)
        }

        let format = reference.wav.format
        var parts: [SessionFile] = []
        var offset: Int64 = 0

        for entry in opened {
            var part = SessionFile(wav: entry.wav, startOffsetInSession: offset)
            if !entry.wav.format.isCompatible(with: format) {
                part.isExcluded = true
                warnings.append(SessionWarning(
                    severity: .error,
                    message: "\(entry.url.lastPathComponent) is \(entry.wav.format.shortDescription), "
                        + "\(entry.wav.format.channelCount) ch — the rest of the session is "
                        + "\(format.shortDescription), \(format.channelCount) ch. It was left out."
                ))
            } else {
                offset += part.frameCount
            }
            parts.append(part)
        }

        var session = Session(
            folderURL: folder,
            parts: parts,
            format: format,
            name: defaultSessionName(for: folder),
            warnings: warnings
        )
        session.reindexParts()
        return session
    }

    /// The folder name is the best guess at what to call the session — it's what
    /// the recorder or the user already named the take.
    static func defaultSessionName(for folder: URL) -> String {
        let raw = folder.lastPathComponent
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Session" : cleaned
    }
}
