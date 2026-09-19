import AppKit
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
    @State private var dragging: Grab?
    @State private var hoverX: CGFloat?

    /// What a press in the scrubber took hold of.
    private enum Grab: Equatable { case trimIn, trimOut, playhead }

    private enum Metrics {
        /// How close a press has to land to count as grabbing a handle rather
        /// than dropping the playhead. Roughly a fingertip at trackpad speed.
        static let grabRadius: CGFloat = 9
        static let knobWidth: CGFloat = 11
        static let knobHeight: CGFloat = 9
    }

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
                model.player.togglePlay()
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
            .help("Play from the playhead (Space)")

            Text(Timecode.string(from: model.playheadSeconds))
                .font(.monoDigits(12.5, weight: .semibold))
                .foregroundStyle(model.session == nil ? palette.tertiaryLabel : palette.label)
                .help("Playhead — drag it in the bar below, or nudge it with ← and → (⇧ for 10s, ⌥ for 0.1s)")

            Text("Trim (all \(model.exportingStems.count) stems)")
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
            let playX = width * playheadFraction

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

                // A preview of where a click would drop the playhead, so the bar
                // reads as scrubbable before you press.
                if let hoverX, dragging == nil, model.session != nil,
                   target(at: hoverX, width: width) == nil {
                    Rectangle()
                        .fill(palette.playheadGuide)
                        .frame(width: 1, height: height)
                        .offset(x: hoverX)
                }

                handle(at: inX, height: height)
                handle(at: outX, height: height)

                if model.player.isAvailable {
                    playhead(at: playX, height: height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard model.session != nil, width > 0 else { return }
                        let grab = dragging ?? beginDrag(at: value.startLocation.x, width: width)
                        let fraction = min(max(0, value.location.x / width), 1)
                        switch grab {
                        case .trimIn: model.setTrimInFraction(fraction)
                        case .trimOut: model.setTrimOutFraction(fraction)
                        case .playhead: model.scrubPlayhead(toFraction: fraction)
                        }
                    }
                    .onEnded { _ in
                        if dragging == .playhead { model.endScrub() }
                        dragging = nil
                    }
            )
            .onContinuousHover { phase in
                guard model.session != nil, width > 0 else { return }
                switch phase {
                case .active(let point):
                    hoverX = min(max(0, point.x), width)
                    cursor(for: dragging ?? target(at: point.x, width: width)).set()
                case .ended:
                    hoverX = nil
                    NSCursor.arrow.set()
                }
            }
        }
    }

    /// Work out what a press took hold of and latch it for the rest of the drag.
    ///
    /// The handles own a narrow band on either side of themselves; everything
    /// else in the bar belongs to the playhead. That way clicking in the middle
    /// of the waveform auditions from there instead of yanking a trim handle
    /// across the whole session.
    private func beginDrag(at x: CGFloat, width: CGFloat) -> Grab {
        let grab = target(at: x, width: width) ?? .playhead
        if grab == .playhead { model.beginScrub() }
        dragging = grab
        return grab
    }

    /// The grabbable thing under `x`, or nil if the press landed in open bar.
    private func target(at x: CGFloat, width: CGFloat) -> Grab? {
        let candidates: [(Grab, CGFloat)] = [
            (.trimIn, abs(x - width * inFraction)),
            (.trimOut, abs(x - width * outFraction)),
            (.playhead, abs(x - width * playheadFraction)),
        ]
        // Ties go to the handles, which are listed first. They overlap the
        // playhead exactly on a freshly loaded session, and a handle can only be
        // caught inside this narrow band, whereas the playhead can also be
        // placed by clicking anywhere else in the bar.
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 <= Metrics.grabRadius else {
            return nil
        }
        return nearest.0
    }

    private func cursor(for grab: Grab?) -> NSCursor {
        switch grab {
        case .trimIn, .trimOut: return .resizeLeftRight
        case .playhead: return dragging == .playhead ? .closedHand : .openHand
        case nil: return .arrow
        }
    }

    private func handle(at x: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(palette.trimHandle)
            .frame(width: 3, height: height)
            .offset(x: max(0, x - 1.5))
            .shadow(color: palette.trimHandle.opacity(0.4), radius: 2)
    }

    /// The playhead is a line plus a knob at the top: the line reads the
    /// position off the waveform, the knob advertises that it can be dragged.
    private func playhead(at x: CGFloat, height: CGFloat) -> some View {
        let grabbed = dragging == .playhead
        return VStack(spacing: 0) {
            Capsule()
                .fill(palette.playhead)
                .frame(width: Metrics.knobWidth, height: Metrics.knobHeight)
                .scaleEffect(grabbed ? 1.15 : 1)
            Rectangle()
                .fill(palette.playhead)
                .frame(width: grabbed ? 2 : 1)
        }
        .frame(width: Metrics.knobWidth, height: height, alignment: .top)
        .shadow(color: .black.opacity(0.28), radius: 1.5, x: 0, y: 0)
        .offset(x: x - Metrics.knobWidth / 2)
        .animation(.easeOut(duration: 0.1), value: grabbed)
        .allowsHitTesting(false)
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
