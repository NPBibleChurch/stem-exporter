import SwiftUI
import StemExporterKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TemplateSettings()
                .tabItem { Label("Templates", systemImage: "rectangle.split.3x1") }
            ExportDefaultsSettings()
                .tabItem { Label("Export Defaults", systemImage: "square.and.arrow.down") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
        }
        .frame(width: 520, height: 400)
    }
}

// MARK: - Appearance

/// The explicit Light / Dark / System control, with both themes shown side by
/// side so the choice is visible before it's made.
struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            Text("Appearance")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.label)

            Picker("", selection: $model.appearance) {
                ForEach(AppearanceSetting.allCases) { setting in
                    Text(setting.title).tag(setting)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)

            Text("System follows macOS’s own Light/Dark setting. Light and Dark force the app’s appearance regardless of macOS.")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.tertiaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            HStack(spacing: 16) {
                ThemePreview(title: "Light", palette: .light, isActive: isActive(.light))
                ThemePreview(title: "Dark", palette: .dark, isActive: isActive(.dark))
            }
            .padding(.top, 22)

            Spacer()
        }
        .padding(22)
    }

    private func isActive(_ scheme: ColorScheme) -> Bool {
        switch model.appearance {
        case .light: return scheme == .light
        case .dark: return scheme == .dark
        case .system: return false
        }
    }
}

private struct ThemePreview: View {
    let title: String
    let palette: Palette
    let isActive: Bool
    @Environment(\.palette) private var current

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .kerning(0.4)
                .textCase(.uppercase)
                .foregroundStyle(current.tertiaryLabel)

            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: 0xFF5F57)).frame(width: 6, height: 6)
                    Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 6, height: 6)
                    Circle().fill(Color(hex: 0x28C840)).frame(width: 6, height: 6)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(palette.chromeBackground)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.separator).frame(height: 1)
                }

                VStack(spacing: 0) {
                    previewRow("Piano", "Trk 1")
                    Rectangle().fill(palette.hairline).frame(height: 1)
                    previewRow("Violin", "Trk 2")
                }
                .padding(10)
            }
            .background(palette.windowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? current.accent : palette.separator, lineWidth: isActive ? 2 : 1)
            )
        }
    }

    private func previewRow(_ name: String, _ source: String) -> some View {
        HStack {
            Text(name).foregroundStyle(palette.label)
            Spacer()
            Text(source).foregroundStyle(palette.secondaryLabel)
        }
        .font(.system(size: 11))
        .padding(.vertical, 4)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var silenceThreshold: Double = -50
    @State private var autoSkipEmpty = true
    @State private var emptyThreshold: Double = SilenceDetector.defaultEmptyTrackThresholdDB
    @State private var cacheSize: String = "—"

    var body: some View {
        Form {
            Section {
                LabeledContent("Session folder") {
                    Text(model.preferences.lastSessionFolder?.path ?? "None yet")
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $silenceThreshold, in: -80...(-20), step: 1) {
                        Text("Snap-to-silence threshold")
                    }
                    .onChange(of: silenceThreshold) { _, value in
                        model.preferences.silenceThresholdDB = value
                    }
                    Text("Audio below \(Int(silenceThreshold)) dBFS counts as dead air when snapping the trim handles.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryLabel)
                }
            }

            Section("Empty tracks") {
                Toggle("Skip tracks that look empty", isOn: $autoSkipEmpty)
                    .onChange(of: autoSkipEmpty) { _, value in
                        model.preferences.autoSkipEmptyTracks = value
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $emptyThreshold, in: -90...(-30), step: 1) {
                        Text("Empty threshold")
                    }
                    .disabled(!autoSkipEmpty)
                    .onChange(of: emptyThreshold) { _, value in
                        model.preferences.emptyTrackThresholdDB = value
                    }
                    Text("A track that never reaches \(Int(emptyThreshold)) dBFS is treated as an unused input "
                         + "and arrives with Skip already ticked. Untick it to export it anyway.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryLabel)
                }
            }

            Section("Waveform cache") {
                LabeledContent("On disk") { Text(cacheSize) }
                Button("Clear Cache") {
                    model.peakCache.clear()
                    refreshCacheSize()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            silenceThreshold = model.preferences.silenceThresholdDB
            autoSkipEmpty = model.preferences.autoSkipEmptyTracks
            emptyThreshold = model.preferences.emptyTrackThresholdDB
            refreshCacheSize()
        }
    }

    private func refreshCacheSize() {
        cacheSize = ByteSize.string(model.peakCache.cacheSizeBytes)
    }
}

// MARK: - Templates

struct TemplateSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            List(model.templates) { template in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name).font(.system(size: 13))
                        Text("\(template.trackCount) tracks · \(template.exportingSlotCount) stems")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.tertiaryLabel)
                    }
                    Spacer()
                    Button("Edit") {
                        model.editingTemplate = template
                        openWindow(id: WindowID.templateEditor)
                    }
                    Button("Duplicate") { _ = model.duplicateTemplate(template) }
                    Button {
                        model.deleteTemplate(template)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                .padding(.vertical, 3)
            }

            Divider()

            HStack {
                Button("New Template…") {
                    model.editingTemplate = Template.placeholder(
                        name: TemplateStore.uniqueName(base: "New Template", among: model.templates.map(\.name)),
                        trackCount: 32
                    )
                    openWindow(id: WindowID.templateEditor)
                }
                Button("Import…") { importTemplate() }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.open(model.templateStore.folderURL)
                }
            }
            .padding(12)
        }
    }

    private func importTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try model.templateStore.importTemplate(from: url)
            model.loadTemplates()
        } catch {
            model.errorMessage = "That file isn’t a template Stem Exporter can read."
        }
    }
}

// MARK: - Export defaults

struct ExportDefaultsSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    @State private var pattern = NamingPattern.default.pattern
    @State private var policy = CollisionPolicy.ask
    @State private var datedSubfolder = false

    var body: some View {
        Form {
            Section("File naming") {
                TextField("Pattern", text: $pattern)
                    .onChange(of: pattern) { _, value in
                        model.preferences.namingPattern = NamingPattern(pattern: value)
                    }
                Text("Tokens: \(NamingPattern.sessionToken), \(NamingPattern.trackToken), \(NamingPattern.nameToken). "
                     + "Track numbers are zero-padded so Finder sorts the stems in input order.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiaryLabel)
                LabeledContent("Example") {
                    Text(exampleName).font(.monoDigits(11.5)).foregroundStyle(palette.secondaryLabel)
                }
            }

            Section("Destination") {
                LabeledContent("Last used") {
                    Text(model.destination?.path ?? "None yet")
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Toggle("Create a dated subfolder for each export", isOn: $datedSubfolder)
                    .onChange(of: datedSubfolder) { _, value in
                        model.preferences.createDatedSubfolder = value
                    }
                Picker("If a file already exists", selection: $policy) {
                    ForEach(CollisionPolicy.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: policy) { _, value in
                    model.preferences.collisionPolicy = value
                }
            }

            Section("Format") {
                LabeledContent("Output") {
                    Text("WAV (BWF), same bit depth and sample rate as the source")
                        .foregroundStyle(palette.secondaryLabel)
                }
                Text("No resampling or conversion — stems are written in the source’s own format, with BWF metadata pointing back at the session.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiaryLabel)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            pattern = model.preferences.namingPattern.pattern
            policy = model.preferences.collisionPolicy
            datedSubfolder = model.preferences.createDatedSubfolder
        }
    }

    private var exampleName: String {
        NamingPattern(pattern: pattern).fileName(
            session: "2026-09-13 Service",
            trackNumbers: [3],
            stemName: "Piano"
        ) + ".wav"
    }
}
