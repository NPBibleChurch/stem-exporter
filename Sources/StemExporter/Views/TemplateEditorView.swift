import SwiftUI
import StemExporterKit

/// The full track table for building a template: one row per physical input,
/// with stereo pairs shown as a linked primary row plus a follower row.
struct TemplateEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Template = Template(name: "New Template", trackCount: 32, slots: [])
    @State private var selection = Set<Int>()
    @State private var issues: [String] = []
    @State private var loaded = false


    var body: some View {
        VStack(spacing: 0) {
            toolbar
            linkBar
            Divider().overlay(palette.separator)
            table
            if !issues.isEmpty { issueBar }
        }
        .frame(minWidth: 820, minHeight: 620)
        .background(palette.windowBackground)
        .onAppear(perform: loadDraft)
        .onChange(of: model.editingTemplate?.id) { _, _ in
            loaded = false
            loadDraft()
        }
    }

    private func loadDraft() {
        guard !loaded else { return }
        loaded = true
        if let editing = model.editingTemplate {
            draft = normalized(editing)
        } else if let selected = model.selectedTemplate {
            draft = normalized(selected)
        } else {
            draft = Template.placeholder(name: "New Template", trackCount: model.session?.trackCount ?? 32)
        }
    }

    /// Make sure every track in range has a row, so the editor is a complete
    /// picture of the recorder's inputs rather than only the named ones.
    private func normalized(_ template: Template) -> Template {
        var copy = template
        let covered = copy.coveredTracks
        for track in 1...max(copy.trackCount, 1) where !covered.contains(track) {
            copy.slots.append(TemplateSlot(outputName: "Track \(track)", trackNumbers: [track]))
        }
        copy.slots.sort { $0.primaryTrack < $1.primaryTrack }
        return copy
    }

    // MARK: Chrome

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("Template name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 240)

            Stepper(
                "\(draft.trackCount) tracks",
                value: Binding(
                    get: { draft.trackCount },
                    set: { setTrackCount($0) }
                ),
                in: 1...128
            )
            .font(.system(size: 12))
            .foregroundStyle(palette.secondaryLabel)
            .fixedSize()

            Spacer()

            Button("Import…") { importTemplate() }
            Button("Export…") { exportTemplate() }
            Button("Duplicate") { duplicate() }
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var linkBar: some View {
        HStack(spacing: 10) {
            Button {
                linkSelectedAsPair()
            } label: {
                Label("Link Selected as Stereo Pair", systemImage: "link")
            }
            .disabled(!canLinkSelection)

            Button("Unlink") { unlinkSelection() }
                .disabled(!canUnlinkSelection)

            Text(selection.count == 2
                 ? "Tracks \(selection.sorted().map(String.init).joined(separator: " and ")) will become one stereo stem"
                 : "Select two rows, then click to merge them into one linked stem")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.tertiaryLabel)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var issueBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(issues, id: \.self) { issue in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text(issue).font(.system(size: 11.5))
                }
                .foregroundStyle(palette.warningLabel)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.warningBackground)
        .overlay(alignment: .top) { Rectangle().fill(palette.warningBorder).frame(height: 1) }
    }

    // MARK: Table

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Trk").frame(width: EditorColumn.track, alignment: .leading)
                Color.clear.frame(width: EditorColumn.select, height: 1)
                Text("Output name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Stereo link").frame(width: EditorColumn.link, alignment: .leading)
                Text("Gain").frame(width: EditorColumn.gain, alignment: .leading)
                Text("Skip").frame(width: EditorColumn.skip, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .bold))
            .kerning(0.4)
            .textCase(.uppercase)
            .foregroundStyle(palette.tertiaryLabel)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            Divider().overlay(palette.separator)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.track) { row in
                        editorRow(row)
                    }
                }
            }
        }
    }

    /// One visual row per physical track: the slot's primary row carries the
    /// fields, the second half of a pair shows as a follower.
    private struct Row {
        var track: Int
        var slotIndex: Int
        var isFollower: Bool
    }

    private var rows: [Row] {
        var result: [Row] = []
        for track in 1...max(draft.trackCount, 1) {
            guard let index = draft.slots.firstIndex(where: { $0.trackNumbers.contains(track) }) else { continue }
            result.append(Row(
                track: track,
                slotIndex: index,
                isFollower: draft.slots[index].trackNumbers.first != track
            ))
        }
        return result
    }

    @ViewBuilder
    private func editorRow(_ row: Row) -> some View {
        let slot = draft.slots[row.slotIndex]
        let isSelected = selection.contains(row.track)
        let isLinked = slot.isStereo

        HStack(spacing: 0) {
            Text("\(row.track)")
                .font(.system(size: 13, weight: isLinked ? .semibold : .regular))
                .foregroundStyle(isLinked ? palette.accent : palette.tertiaryLabel)
                .frame(width: EditorColumn.track, alignment: .leading)

            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { on in
                    if on { selection.insert(row.track) } else { selection.remove(row.track) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: EditorColumn.select, alignment: .leading)

            Group {
                if row.isFollower {
                    Text("↳ linked to \(slot.outputName) (R)")
                        .font(.system(size: 12.5).italic())
                        .foregroundStyle(palette.tertiaryLabel)
                } else {
                    TextField("Track \(row.track)", text: binding(forSlot: row.slotIndex).outputName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .frame(maxWidth: 280)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if isLinked {
                    Text(row.isFollower ? "R: Trk \(row.track)" : "L: Trk \(row.track)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.accent)
                } else {
                    Text("—").foregroundStyle(palette.quaternaryLabel)
                }
            }
            .frame(width: EditorColumn.link, alignment: .leading)

            Group {
                if row.isFollower {
                    Text("shared")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.tertiaryLabel)
                } else if slot.skip {
                    Text("—")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.quaternaryLabel)
                } else {
                    GainField(gainDB: binding(forSlot: row.slotIndex).gainDB)
                }
            }
            .frame(width: EditorColumn.gain, alignment: .leading)

            Toggle("", isOn: binding(forSlot: row.slotIndex).skip)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(row.isFollower)
                .frame(width: EditorColumn.skip, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: 36)
        .opacity(slot.skip ? 0.45 : 1)
        .background(isLinked || isSelected ? palette.rowSelected : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }

    private func binding(forSlot index: Int) -> Binding<TemplateSlot> {
        Binding(
            get: { draft.slots.indices.contains(index) ? draft.slots[index] : TemplateSlot(outputName: "", trackNumbers: []) },
            set: { if draft.slots.indices.contains(index) { draft.slots[index] = $0 } }
        )
    }

    // MARK: Actions

    private var canLinkSelection: Bool {
        guard selection.count == 2 else { return false }
        return selection.allSatisfy { track in
            draft.slots.first { $0.trackNumbers.contains(track) }?.isStereo == false
        }
    }

    private var canUnlinkSelection: Bool {
        selection.contains { track in
            draft.slots.first { $0.trackNumbers.contains(track) }?.isStereo == true
        }
    }

    /// Two mono rows become one linked row. The pair doesn't have to be adjacent.
    private func linkSelectedAsPair() {
        let tracks = selection.sorted()
        guard tracks.count == 2,
              let leftIndex = draft.slots.firstIndex(where: { $0.trackNumbers == [tracks[0]] }),
              let rightIndex = draft.slots.firstIndex(where: { $0.trackNumbers == [tracks[1]] })
        else { return }

        var merged = draft.slots[leftIndex]
        merged.trackNumbers = tracks
        if merged.outputName == "Track \(tracks[0])" {
            merged.outputName = "Tracks \(tracks[0])+\(tracks[1])"
        }
        draft.slots.remove(at: max(leftIndex, rightIndex))
        draft.slots.remove(at: min(leftIndex, rightIndex))
        draft.slots.append(merged)
        draft.slots.sort { $0.primaryTrack < $1.primaryTrack }
        selection.removeAll()
    }

    private func unlinkSelection() {
        for track in selection {
            guard let index = draft.slots.firstIndex(where: { $0.trackNumbers.contains(track) }),
                  draft.slots[index].isStereo else { continue }
            let slot = draft.slots[index]
            draft.slots.remove(at: index)
            for (offset, number) in slot.trackNumbers.enumerated() {
                draft.slots.append(TemplateSlot(
                    outputName: offset == 0 ? slot.outputName : "Track \(number)",
                    trackNumbers: [number],
                    skip: slot.skip,
                    gainDB: slot.gainDB
                ))
            }
        }
        draft.slots.sort { $0.primaryTrack < $1.primaryTrack }
        selection.removeAll()
    }

    private func setTrackCount(_ count: Int) {
        draft.trackCount = count
        draft.slots.removeAll { $0.trackNumbers.contains { $0 > count } }
        draft = normalized(draft)
    }

    private func save() {
        issues = draft.validationIssues()
        guard issues.isEmpty else { return }
        model.saveTemplate(draft)
        model.editingTemplate = draft
        dismiss()
    }

    private func duplicate() {
        var copy = draft
        copy.id = UUID()
        copy.name = TemplateStore.uniqueName(base: draft.name, among: model.templates.map(\.name))
        copy.slots = draft.slots.map { slot in
            var new = slot
            new.id = UUID()
            return new
        }
        draft = copy
    }

    private func exportTemplate() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(draft.name).json"
        panel.allowedContentTypes = [.json]
        panel.message = "Save this template as a JSON file you can back up or move to another Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.templateStore.exportTemplate(draft, to: url)
    }

    private func importTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try model.templateStore.importTemplate(from: url)
            model.loadTemplates()
            draft = normalized(imported)
        } catch {
            model.errorMessage = "That file isn’t a template Stem Exporter can read."
        }
    }
}

enum EditorColumn {
    static let track: CGFloat = 40
    static let select: CGFloat = 28
    static let link: CGFloat = 100
    static let gain: CGFloat = 90
    static let skip: CGFloat = 60
}

struct GainField: View {
    @Binding var gainDB: Double
    @State private var text: String = "0.0"
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 3) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.monoDigits(12.5))
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
                .onSubmit(commit)
            Text("dB")
                .font(.system(size: 10.5))
                .foregroundStyle(palette.tertiaryLabel)
        }
        .onAppear { text = String(format: "%.1f", gainDB) }
        .onChange(of: gainDB) { _, new in text = String(format: "%.1f", new) }
    }

    private func commit() {
        if let value = Double(text.replacingOccurrences(of: "+", with: "")) {
            gainDB = min(max(value, -60), 24)
        }
        text = String(format: "%.1f", gainDB)
    }
}
