import SwiftUI
import StemExporterKit

/// Draws a min/max peak envelope, with gain applied at draw time.
///
/// The peaks are cached at unity, so changing a track's gain redraws instantly —
/// including the clipped regions, which go red the moment the level would hit the
/// rails, rather than only showing up after an export.
struct WaveformView: View {
    var track: PeakData.Track?
    var gainDB: Double = 0
    var isMuted: Bool = false
    var lineWidth: CGFloat = 1.0
    /// Draw only this slice of the session, e.g. just the trimmed region.
    var bucketRange: Range<Int>?

    @Environment(\.palette) private var palette

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard let track, !track.min.isEmpty, size.width > 0 else {
                drawFlatline(in: &context, size: size)
                return
            }

            let range = clampedRange(count: track.min.count)
            guard !range.isEmpty else {
                drawFlatline(in: &context, size: size)
                return
            }

            let gain = Float(SampleCodec.linearGain(dB: gainDB))
            let mid = size.height / 2
            let columns = max(1, Int(size.width.rounded()))
            let bucketsPerColumn = Double(range.count) / Double(columns)

            var body = Path()
            var clipped = Path()

            for column in 0..<columns {
                let start = range.lowerBound + Int(Double(column) * bucketsPerColumn)
                let end = max(start + 1, range.lowerBound + Int(Double(column + 1) * bucketsPerColumn))
                guard start < range.upperBound else { break }

                var low: Float = 0
                var high: Float = 0
                for index in start..<min(end, range.upperBound) {
                    low = Swift.min(low, track.min[index])
                    high = Swift.max(high, track.max[index])
                }

                let scaledLow = low * gain
                let scaledHigh = high * gain
                let didClip = scaledLow <= -1 || scaledHigh >= 1

                let x = Double(column) + 0.5
                let topY = mid - Double(Swift.min(Swift.max(scaledHigh, -1), 1)) * mid
                let bottomY = mid - Double(Swift.min(Swift.max(scaledLow, -1), 1)) * mid

                // A silent column still gets a hairline so the track reads as present.
                let top = abs(topY - bottomY) < 0.7 ? mid - 0.35 : topY
                let bottom = abs(topY - bottomY) < 0.7 ? mid + 0.35 : bottomY

                // Appended in place: lifting the path into a local first would
                // leave both bindings referencing it, so every column would copy
                // the whole path built so far.
                if didClip {
                    clipped.move(to: CGPoint(x: x, y: top))
                    clipped.addLine(to: CGPoint(x: x, y: bottom))
                } else {
                    body.move(to: CGPoint(x: x, y: top))
                    body.addLine(to: CGPoint(x: x, y: bottom))
                }
            }

            context.stroke(
                body,
                with: .color(isMuted ? palette.waveformMuted : palette.waveform),
                lineWidth: lineWidth
            )
            context.stroke(clipped, with: .color(palette.clip), lineWidth: max(lineWidth, 1.2))
        }
        .drawingGroup(opaque: false)
    }

    private func clampedRange(count: Int) -> Range<Int> {
        guard let bucketRange else { return 0..<count }
        let lower = max(0, min(bucketRange.lowerBound, count))
        let upper = max(lower, min(bucketRange.upperBound, count))
        return lower..<upper
    }

    private func drawFlatline(in context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height / 2))
        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(path, with: .color(palette.waveformMuted), lineWidth: lineWidth)
    }
}

/// The waveform placeholder shown while the import pass is still analysing.
struct WaveformPlaceholder: View {
    var fraction: Double?
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(palette.hairline)
                    .frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .center)
                if let fraction {
                    Rectangle()
                        .fill(palette.accent.opacity(0.4))
                        .frame(width: geo.size.width * fraction, height: 2)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }
}
