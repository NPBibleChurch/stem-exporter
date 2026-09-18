import SwiftUI
import StemExporterKit

/// Progress while the export runs.
///
/// Every stem advances together, because the source is read exactly once and all
/// the output channels are pulled out of the same block — so the checklist shows
/// each file filling up in step rather than a queue working down one at a time.
struct ExportProgressView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Exporting \(model.session?.name ?? "session")…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.label)

            Text(statusLine)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryLabel)
                .padding(.top, 4)

            ProgressBar(fraction: model.exportProgress?.fractionComplete ?? 0, height: 8)
                .padding(.top, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.exportPlanInFlight?.items ?? []) { item in
                        StemProgressRow(
                            name: item.fileName,
                            fraction: model.exportProgress?.stemFractions[item.id] ?? 0,
                            isDone: model.exportProgress?.finishedStems.contains(item.id) ?? false
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 170)
            .padding(.top, 20)

            HStack {
                Spacer()
                Button("Cancel") { model.cancelExport() }
            }
            .padding(.top, 20)
        }
        .padding(28)
        .frame(width: 480)
        .background(palette.windowBackground)
    }

    private var statusLine: String {
        guard let progress = model.exportProgress, let session = model.session else {
            return "Preparing…"
        }
        let written = Timecode.compactDuration(
            Timecode.seconds(forFrames: progress.framesWritten, sampleRate: session.sampleRate)
        )
        let total = Timecode.compactDuration(session.trimmedDuration)
        let stems = model.exportPlanInFlight?.items.count ?? 0
        let remaining = progress.estimatedSecondsRemaining.map { " · \(Timecode.remaining($0))" } ?? ""
        return "\(stems) stems · \(written) of \(total)\(remaining)"
    }
}

private struct StemProgressRow: View {
    let name: String
    let fraction: Double
    let isDone: Bool

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isDone {
                    Image(systemName: "checkmark")
                        .foregroundStyle(palette.success)
                        .font(.system(size: 11, weight: .bold))
                } else if fraction > 0 {
                    WritingIndicator()
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(palette.quaternaryLabel)
                        .font(.system(size: 11))
                }
            }
            .frame(width: 14)

            Text(name)
                .font(.system(size: 12.5, weight: isDone ? .regular : .semibold))
                .foregroundStyle(isDone ? palette.label : (fraction > 0 ? palette.accent : palette.quaternaryLabel))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if !isDone && fraction > 0 {
                ProgressBar(fraction: fraction, height: 4)
                    .frame(width: 60)
            }
        }
    }
}

/// Drawn rather than an NSProgressIndicator, so it picks up the app's palette in
/// both appearances and matches the rest of the custom chrome.
struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 8

    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.separator)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

/// A quarter-ring that spins while a stem is being written.
struct WritingIndicator: View {
    @Environment(\.palette) private var palette
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

// MARK: - Summary

struct ExportSummaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let result = model.exportResult {
                Text(subtitle(result))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.leading, 38)
                    .padding(.top, 6)

                fileList(result)
                    .padding(.top, 16)
                    .padding(.bottom, 4)

                ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                        Text(warning)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(palette.warningLabel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(palette.warningBackground)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.warningBorder, lineWidth: 1))
                    )
                    .padding(.top, 8)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Reveal in Finder") { model.revealInFinder() }
                Button("Done") { model.dismissExport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(28)
        .frame(width: 520)
        .background(palette.windowBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(palette.success)
                    .frame(width: 28, height: 28)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text("Export complete")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.label)
        }
    }

    private func subtitle(_ result: ExportResult) -> String {
        let count = result.stems.count
        return "\(count) stem\(count == 1 ? "" : "s") written to \(result.folder.lastPathComponent) · "
            + "\(Timecode.compactDuration(result.trimmedDuration)) trimmed from \(Timecode.compactDuration(result.sourceDuration)) · "
            + ByteSize.string(result.totalBytes)
    }

    private func fileList(_ result: ExportResult) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(result.stems) { stem in
                    HStack {
                        if stem.didClip {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(palette.warningLabel)
                        }
                        Text(stem.displayName)
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(ByteSize.string(stem.byteCount))
                            .font(.monoDigits(12))
                            .foregroundStyle(palette.tertiaryLabel)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(palette.hairline).frame(height: 1)
                    }
                }
            }
        }
        .frame(maxHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.controlBackground.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.separator, lineWidth: 1))
        )
    }
}
