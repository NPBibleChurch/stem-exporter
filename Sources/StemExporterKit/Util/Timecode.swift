import Foundation

/// Timecode formatting and parsing for the trim handles.
public enum Timecode {

    /// "HH:MM:SS.mmm"
    public static func string(from seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalMilliseconds = Int64((clamped * 1000).rounded())
        let ms = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    /// Accepts "HH:MM:SS.mmm", "MM:SS.mmm", "SS.mmm" and anything in between.
    /// Returns nil for input that isn't a timecode at all.
    public static func seconds(from string: String) -> TimeInterval? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }

        var total: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard let value = Double(part), value >= 0 else { return nil }
            // Only the seconds field may carry a fraction.
            if !isLast && value != value.rounded(.towardZero) { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// "46m 03s", "1h 12m 04s", "58s" — the compact form used in summaries.
    public static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    /// "about 40s remaining", "about 3m remaining", "less than a second remaining".
    public static func remaining(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "finishing up" }
        if seconds < 1 { return "less than a second remaining" }
        if seconds < 60 { return "about \(Int(seconds.rounded()))s remaining" }
        let minutes = Int((seconds / 60).rounded())
        return "about \(minutes)m remaining"
    }

    public static func frames(forSeconds seconds: TimeInterval, sampleRate: Double) -> Int64 {
        Int64((max(0, seconds) * sampleRate).rounded())
    }

    public static func seconds(forFrames frames: Int64, sampleRate: Double) -> TimeInterval {
        sampleRate > 0 ? Double(frames) / sampleRate : 0
    }
}

/// Byte-count formatting for the export summary.
public enum ByteSize {
    public static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
