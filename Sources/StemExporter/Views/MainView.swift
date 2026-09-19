import SwiftUI
import StemExporterKit

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SessionSidebar()
                TrackTableView()
            }
            TrimBar()
        }
        .background(palette.windowBackground)
        .frame(minWidth: 1000, minHeight: 640)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .toolbar { toolbarContent }
        .navigationTitle(model.session?.name ?? "Stem Exporter")
        .navigationSubtitle(subtitle)
        .background(keyboardShortcuts)
        .sheet(isPresented: .constant(model.exportPhase == .running)) {
            ExportProgressView()
        }
        .sheet(isPresented: .constant(model.exportPhase == .finished)) {
            ExportSummaryView()
        }
        .alert(
            "Some files already exist",
            isPresented: Binding(
                get: { model.collisionPrompt != nil },
                set: { if !$0 { model.collisionPrompt = nil } }
            ),
            presenting: model.collisionPrompt
        ) { prompt in
            Button("Replace") { model.resolveCollision(with: .overwrite) }
            Button("Keep Both") { model.resolveCollision(with: .appendSuffix) }
            Button("Cancel", role: .cancel) { model.collisionPrompt = nil }
        } message: { prompt in
            Text(collisionMessage(prompt))
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Dropping the recorder's folder straight onto the window is the shortest
    /// path from "card is mounted" to "stems are exporting".
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.hasDirectoryPath else { return }
            Task { @MainActor in model.importSession(from: url) }
        }
        return true
    }

    private var subtitle: String {
        guard let session = model.session else { return "No session loaded" }
        if let fraction = model.analysisFraction {
            return "Analysing waveforms… \(Int(fraction * 100))%"
        }
        return "Exporting \(Timecode.compactDuration(session.trimmedDuration)) of \(Timecode.compactDuration(session.totalDuration))"
    }

    private func collisionMessage(_ prompt: CollisionPrompt) -> String {
        let names = prompt.files.prefix(3).map(\.lastPathComponent).joined(separator: "\n")
        let more = prompt.files.count > 3 ? "\n…and \(prompt.files.count - 3) more" : ""
        return "\(prompt.files.count) file\(prompt.files.count == 1 ? "" : "s") in the destination folder would be replaced:\n\n\(names)\(more)"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.chooseSessionFolder()
            } label: {
                Label("Add Session Folder", systemImage: "plus")
            }
            .help("Choose the folder holding this session’s WAV files")
        }

        ToolbarItem {
            Menu {
                Button("No template") { model.selectTemplate(nil) }
                Divider()
                ForEach(model.templates) { template in
                    Button {
                        model.selectTemplate(template.id)
                    } label: {
                        if template.id == model.selectedTemplateID {
                            Label(template.name, systemImage: "checkmark")
                        } else {
                            Text(template.name)
                        }
                    }
                }
                Divider()
                Button("Edit Template…") {
                    model.openTemplateEditor()
                    openWindow(id: WindowID.templateEditor)
                }
                .disabled(model.selectedTemplate == nil)
                Button("New Template…") {
                    model.editingTemplate = Template.placeholder(
                        name: TemplateStore.uniqueName(base: "New Template", among: model.templates.map(\.name)),
                        trackCount: model.session?.trackCount ?? 32
                    )
                    openWindow(id: WindowID.templateEditor)
                }
            } label: {
                Label(
                    "Template: \(model.selectedTemplate?.name ?? "None")",
                    systemImage: "list.bullet"
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }

        ToolbarItem {
            Button {
                model.chooseDestination()
            } label: {
                Label(
                    model.destination.map { "To: \($0.lastPathComponent)" } ?? "Choose Destination…",
                    systemImage: "folder"
                )
            }
            .help(model.destination?.path ?? "Pick where the stems should be written")
        }

        ToolbarItem {
            Button {
                model.startExport()
            } label: {
                Text("Export All (\(model.exportingStems.count))")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canExport)
            .help(model.exportBlockReason ?? "Render every included stem into the destination folder")
        }
    }

    // MARK: Keyboard

    /// QuickTime-style marking: I and O set the handles at the playhead, Space
    /// starts and stops playback, and the arrows walk the playhead — coarse on
    /// their own, 10 seconds with Shift, a tenth of a second with Option, so the
    /// same keys cover both "find the song" and "find the downbeat".
    private var keyboardShortcuts: some View {
        Group {
            Button("") { model.markInAtPlayhead() }
                .keyboardShortcut("i", modifiers: [])
            Button("") { model.markOutAtPlayhead() }
                .keyboardShortcut("o", modifiers: [])
            Button("") { model.player.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])

            Button("") { model.nudgePlayhead(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.nudgePlayhead(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { model.nudgePlayhead(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { model.nudgePlayhead(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("") { model.nudgePlayhead(by: -0.1) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("") { model.nudgePlayhead(by: 0.1) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(model.session == nil)
    }
}
