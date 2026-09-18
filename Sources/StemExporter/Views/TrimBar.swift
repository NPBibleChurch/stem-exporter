import SwiftUI
import StemExporterKit

/// One In point and one Out point for the whole session.
///
/// All tracks are sample-synced on the same clock, so there's one selection, not
/// one per track — and it's shown against a single mono summary of the session
/// rather than 32 rendered waveforms.
struct TrimBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    @State private var inDraft = ""
    @State private var outDraft = ""
    @State private var dragging: Handle?

    private enum Handle { case start, end }

    var body: some View {
        VStack(spacing: 8) {
            controls
            scrubber
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(height: 130)
        .background(palette.sidebarBackground)
        .overlay(alignment: .top) { Rectangle().fill(palette.separator).frame(height: 1) }
        .onAppear(perform: syncDrafts)
        .onChange(of: model.session?.trimInFrames) { _, _ in syncDrafts() }
        .onChange(of: model.session?.trimOutFrames) { _, _ in syncDrafts() }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                model.player.togglePlay(from: playheadSeconds)
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(palette.controlBackground)
                            .overlay(Circle().stroke(palette.controlBorder, lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(model.session == nil)
            .help("Play from the In point (Space)")

            Text("Trim (applies to all \(model.exportingStems.count) stems)")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryLabel)

            Button("Snap to Silence") { model.snapToSilence() }
                .font(.system(size: 11.5))
                .disabled(model.peaks == nil)
                .help("Nudge In forward and Out backward to the nearest sound")

            Button("Reset") { model.resetTrim() }
                .font(.system(size: 11.5))
                .disabled(model.session == nil)

            Spacer()

            TimecodeField(label: "In", text: $inDraft) { commitIn() }
            TimecodeField(label: "Out", text: $outDraft) { commitOut() }

            HStack(spacing: 5) {
                Text("Length")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.tertiaryLabel)
                Text(Timecode.compactDuration(model.session?.trimmedDuration ?? 0))
                    .font(.monoDigits(12.5, weight: .semibold))
                    .foregroundStyle(model.session?.hasValidTrim == false ? palette.clip : palette.accent)
            }
        }
    }

    // MARK: Scrubber

    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let inX = width * inFraction
            let outX = width * outFraction

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(palette.controlBackground)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.controlBorder, lineWidth: 1))

                WaveformView(track: model.peaks?.mix, gainDB: 0, lineWidth: 1)
                    .foregroundStyle(palette.mixWaveform)
                    .environment(\.palette, mixPalette)
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)

                // Everything outside the selection is dimmed, so what will be
                // exported is the part that reads as "on".
                palette.trimShade.frame(width: max(0, inX))
                palette.trimShade
                    .frame(width: max(0, width - outX))
                    .offset(x: outX)
                palette.trimRegion
                    .frame(width: max(0, outX - inX))
                    .offset(x: inX)

                if model.player.isAvailable, model.player.currentTime > 0 || model.player.isPlaying {
                    Rectangle()
                        .fill(palette.label)
                        .frame(width: 1)
                        .offset(x: width * playheadFraction)
                }

                handle(at: inX, height: height, edge: .start)
                handle(at: outX, height: height, edge: .end)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard model.session != nil else { return }
                        let fraction = min(max(0, value.location.x / width), 1)
                        let handle = dragging ?? nearestHandle(to: value.startLocation.x / width)
                        dragging = handle
                        switch handle {
                        case .start: model.setTrimInFraction(fraction)
                        case .end: model.setTrimOutFraction(fraction)
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
    }

    private func handle(at x: CGFloat, height: CGFloat, edge: Handle) -> some View {
        Rectangle()
            .fill(palette.trimHandle)
            .frame(width: 3, height: height)
            .offset(x: max(0, x - 1.5))
            .shadow(color: palette.trimHandle.opacity(0.4), radius: 2)
    }

    /// The mix waveform is drawn in a muted colour, so give it a palette whose
    /// waveform colour is the muted one rather than special-casing the view.
    private var mixPalette: Palette {
        var copy = palette
        copy.waveform = palette.mixWaveform
        return copy
    }

    // MARK: Geometry

    private var inFraction: Double {
        guard let session = model.session, session.totalFrames > 0 else { return 0 }
        return Double(session.trimInFrames) / Double(session.totalFrames)
    }

    private var outFraction: Double {
        guard let session = model.session, session.totalFrames > 0 else { return 1 }
        return Double(session.trimOutFrames) / Double(session.totalFrames)
    }

    private var playheadFraction: Double {
        guard let session = model.session, session.totalDuration > 0 else { return 0 }
        return min(max(0, model.player.currentTime / session.totalDuration), 1)
    }

    private var playheadSeconds: TimeInterval {
        model.player.currentTime > 0 ? model.player.currentTime : (model.session?.trimInSeconds ?? 0)
    }

    private func nearestHandle(to fraction: Double) -> Handle {
        abs(fraction - inFraction) <= abs(fraction - outFraction) ? .start : .end
    }

    // MARK: Timecode fields

    private func syncDrafts() {
        guard let session = model.session else {
            inDraft = "00:00:00.000"
            outDraft = "00:00:00.000"
            return
        }
        inDraft = Timecode.string(from: session.trimInSeconds)
        outDraft = Timecode.string(from: session.trimOutSeconds)
    }

    private func commitIn() {
        guard let seconds = Timecode.seconds(from: inDraft) else { syncDrafts(); return }
        model.setTrimIn(seconds: seconds)
        syncDrafts()
    }

    private func commitOut() {
        guard let seconds = Timecode.seconds(from: outDraft) else { syncDrafts(); return }
        model.setTrimOut(seconds: seconds)
        syncDrafts()
    }
}

struct TimecodeField: View {
    let label: String
    @Binding var text: String
    let onCommit: () -> Void

    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.tertiaryLabel)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.monoDigits(12.5, weight: .semibold))
                .foregroundStyle(palette.label)
                .multilineTextAlignment(.trailing)
                .frame(width: 92)
                .focused($focused)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(focused ? palette.controlBackground : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(focused ? palette.accent : .clear, lineWidth: 1)
                        )
                )
                .onSubmit(onCommit)
                .onChange(of: focused) { _, isFocused in if !isFocused { onCommit() } }
        }
    }
}
