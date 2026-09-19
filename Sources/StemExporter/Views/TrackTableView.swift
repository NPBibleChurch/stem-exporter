import SwiftUI
import StemExporterKit

/// The review table: every output stem after stereo pairs are merged, with its
/// name, source track(s), waveform, gain and skip state — all editable inline.
struct TrackTableView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette


    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.separator)

            if model.session == nil {
                EmptySessionView()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.stems) { stem in
                            TrackRow(stem: stem)
                        }
                    }
                }
                footer
            }
        }
        .background(palette.windowBackground)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("#").frame(width: TrackColumn.number, alignment: .leading)
            Text("Output name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Source").frame(width: TrackColumn.source, alignment: .leading)
            Text("Waveform").frame(width: TrackColumn.waveform, alignment: .leading)
            Text("Gain").frame(width: TrackColumn.gain, alignment: .leading)
            Text("Skip").frame(width: TrackColumn.skip, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .bold))
        .kerning(0.4)
        .textCase(.uppercase)
        .foregroundStyle(palette.tertiaryLabel)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var footer: some View {
        let stems = model.stems
        let skipped = stems.filter(\.skip)
        let auto = model.autoSkippedStems
        let total = model.session?.trackCount ?? 0

        HStack(spacing: 6) {
            if let fit = model.templateFit, let message = fit.message {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(palette.warningLabel)
                Text(message)
            } else if let first = skipped.first {
                Text(skipped.count == 1
                     ? "\(first.outputName) unused — excluded from export"
                     : "\(skipped.count) tracks excluded from export")
                Text("·")
                Text("\(stems.count - skipped.count) of \(total) tracks will export")
            } else {
                Text("\(stems.count - skipped.count) of \(total) tracks will export")
            }
            Spacer()
            if !auto.isEmpty {
                Text(auto.count == 1
                     ? "1 empty track excluded automatically"
                     : "\(auto.count) empty tracks excluded automatically")
                Button("Include Them") { model.restoreAutoSkippedTracks() }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
            if model.hasSessionOverrides, model.selectedTemplate != nil {
                Button("Save Changes to Template") { model.saveOverridesToTemplate() }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(palette.tertiaryLabel)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.chromeBackground)
        .overlay(alignment: .top) { Divider().overlay(palette.separator) }
    }
}

// MARK: - One row

private struct TrackRow: View {
    let stem: StemPlan

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var nameDraft: String = ""
    @State private var gainDraft: String = ""
    @State private var isHovering = false
    @FocusState private var nameFocused: Bool
    @FocusState private var gainFocused: Bool
    @State private var isDraggingGain = false

    private var track: Int { stem.primaryTrack }
    private var peakTrack: PeakData.Track? { model.peakTrack(for: stem) }
    private var willClip: Bool { peakTrack?.clips(atGainDB: stem.gainDB) ?? false }

    var body: some View {
        HStack(spacing: 0) {
            trackNumber.frame(width: TrackColumn.number, alignment: .leading)
            nameCell.frame(maxWidth: .infinity, alignment: .leading)
            Text(stem.sourceLabel)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryLabel)
                .frame(width: TrackColumn.source, alignment: .leading)
            waveformCell.frame(width: TrackColumn.waveform, alignment: .leading)
            gainCell.frame(width: TrackColumn.gain, alignment: .leading)
            skipCell.frame(width: TrackColumn.skip, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
        .opacity(stem.skip ? 0.4 : 1)
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.hairline).frame(height: 1)
        }
        .onHover { isHovering = $0 }
        .onAppear(perform: syncDrafts)
        .onChange(of: stem.outputName) { _, _ in syncNameDraft() }
        .onChange(of: stem.gainDB) { _, _ in syncGainDraft() }
    }

    private var rowBackground: some View {
        Group {
            if isHovering {
                palette.rowHighlight
            } else if stem.hasNameOverride || stem.hasGainOverride {
                palette.rowSelected
            } else {
                Color.clear
            }
        }
    }

    // MARK: Cells

    private var trackNumber: some View {
        HStack(spacing: 3) {
            Text("\(track)")
                .font(.system(size: 13))
                .foregroundStyle(palette.tertiaryLabel)
            if stem.isStereo {
                Text("L")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 3)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.accent, lineWidth: 1))
            }
        }
    }

    private var nameCell: some View {
        HStack(spacing: 6) {
            TextField("", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(stem.isFromTemplate ? palette.label : palette.secondaryLabel)
                .focused($nameFocused)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(nameFocused ? palette.controlBackground : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(nameFocused ? palette.accent : .clear, lineWidth: 1)
                        )
                )
                .frame(maxWidth: 150)
                .onSubmit(commitName)
                .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                .disabled(stem.skip)

            if stem.isStereo {
                Image(systemName: "music.note.list")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.accent)
                    .help("Tracks \(stem.trackNumbers.map(String.init).joined(separator: " and ")) export as one stereo file")
            }
            if stem.gainDB != 0 {
                GainBadge(gainDB: stem.gainDB)
            }
            if stem.isAutoSkipped && stem.skip {
                EmptyTrackBadge()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, -6)
    }

    private var waveformCell: some View {
        Group {
            if let peakTrack {
                WaveformView(
                    track: peakTrack,
                    gainDB: stem.gainDB,
                    isMuted: stem.skip,
                    lineWidth: 1.2
                )
            } else {
                WaveformPlaceholder(fraction: model.analysisFraction)
            }
        }
        .frame(width: 200, height: 22)
    }

    private var gainCell: some View {
        HStack(spacing: 4) {
            if stem.skip {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.quaternaryLabel)
            } else {
                TextField("", text: $gainDraft)
                    .textFieldStyle(.plain)
                    .font(.monoDigits(12, weight: willClip ? .semibold : .regular))
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(willClip ? palette.clipLabel : palette.label)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(width: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(palette.controlBackground.opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(willClip ? palette.clip : palette.controlBorder,
                                            lineWidth: willClip ? 1.5 : 1)
                            )
                    )
                    .focused($gainFocused)
                    // Clicking away — into another row, or straight at Export —
                    // never sends a Return, so every keystroke that parses goes
                    // to the model and leaving the field only tidies the text.
                    .onChange(of: gainDraft) { _, _ in commitGain(normalizingText: false) }
                    .onSubmit { commitGain(normalizingText: true) }
                    .onChange(of: gainFocused) { _, focused in
                        if !focused { commitGain(normalizingText: true) }
                    }
                    // Dragging the field nudges the level, and the waveform above
                    // redraws as it moves — that's the point of doing it here.
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                isDraggingGain = true
                                let delta = -value.translation.height / 6
                                let base = Double(gainDraft) ?? stem.gainDB
                                let next = (base + delta / 10).rounded(toPlaces: 1)
                                gainDraft = String(format: "%.1f", next)
                            }
                            .onEnded { _ in
                                isDraggingGain = false
                                commitGain(normalizingText: true)
                            }
                    )

                Text(willClip ? "clip" : "dB")
                    .font(.system(size: 10.5))
                    .foregroundStyle(willClip ? palette.clip : palette.tertiaryLabel)
                    .help(willClip ? clipHelp : "Level trim applied on export")
            }
        }
    }

    private var clipHelp: String {
        guard let peakTrack else { return "This level would clip." }
        let headroom = peakTrack.headroomDB(atGainDB: 0)
        return String(format: "This level clips. Unity leaves %.1f dB of headroom.", headroom)
    }

    private var skipCell: some View {
        Toggle("", isOn: Binding(
            get: { stem.skip },
            set: { model.setSkip($0, forTrack: track) }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .help(skipHelp)
    }

    private var skipHelp: String {
        if stem.isAutoSkipped && stem.skip {
            return "This track reads as empty, so it was excluded automatically. Untick to export it anyway."
        }
        return stem.skip ? "Excluded from export" : "Exclude this track from export"
    }

    // MARK: Editing

    private func syncDrafts() {
        nameDraft = stem.outputName
        gainDraft = Self.formatGain(stem.gainDB)
    }

    /// Each field re-reads the model only when it isn't mid-edit: rewriting the
    /// text under the cursor would fight whoever is typing or dragging in it.
    private func syncNameDraft() {
        guard !nameFocused else { return }
        nameDraft = stem.outputName
    }

    private func syncGainDraft() {
        guard !gainFocused, !isDraggingGain else { return }
        gainDraft = Self.formatGain(stem.gainDB)
    }

    private func commitName() {
        model.setName(nameDraft, forTrack: track)
    }

    private func commitGain(normalizingText: Bool) {
        let typed = gainDraft
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(typed) else {
            // Half-typed text ("-", "") isn't a level yet; only a field being
            // left behind gets snapped back to what the model actually holds.
            if normalizingText { gainDraft = Self.formatGain(stem.gainDB) }
            return
        }
        let clamped = TemplateSlot.clampGain(value)
        model.setGain(clamped, forTrack: track)
        if normalizingText { gainDraft = Self.formatGain(clamped) }
    }

    private static func formatGain(_ dB: Double) -> String {
        String(format: "%.1f", dB)
    }
}

// MARK: - Bits

/// Shared column widths so the header and the rows stay in step.
enum TrackColumn {
    static let number: CGFloat = 56
    static let source: CGFloat = 100
    static let waveform: CGFloat = 220
    static let gain: CGFloat = 90
    static let skip: CGFloat = 70
}

/// Marks a row the analysis excluded on its own, so a pre-ticked box doesn't
/// read as something the user did and forgot.
struct EmptyTrackBadge: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Text("empty")
            .font(.system(size: 9))
            .foregroundStyle(palette.tertiaryLabel)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(palette.controlBorder, lineWidth: 1)
            )
    }
}

struct GainBadge: View {
    let gainDB: Double
    @Environment(\.palette) private var palette

    var body: some View {
        Text(String(format: "%@%.1f dB", gainDB > 0 ? "+" : "", gainDB))
            .font(.system(size: 9))
            .foregroundStyle(gainDB > 0 ? palette.accent : palette.warningLabel)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(gainDB > 0 ? palette.accent.opacity(0.12) : palette.warningBackground)
            )
    }
}

struct EmptySessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(palette.quaternaryLabel)
            Text("No session loaded")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.label)
            Text("Point the app at the folder holding the session's WAV files")
                .font(.system(size: 12.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.secondaryLabel)
            Button("Add Session Folder…") { model.chooseSessionFolder() }
                .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
