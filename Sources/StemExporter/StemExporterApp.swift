import SwiftUI
import StemExporterKit

@main
struct StemExporterApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Stem Exporter", id: WindowID.main) {
            MainView()
                .environment(model)
                .preferredColorScheme(model.preferredColorScheme)
                .withPalette()
                .onAppear { AppDelegate.model = model }
        }
        .defaultSize(width: 1200, height: 760)
        .windowToolbarStyle(.unified)
        .commands { commands }

        Window("Edit Template", id: WindowID.templateEditor) {
            TemplateEditorView()
                .environment(model)
                .preferredColorScheme(model.preferredColorScheme)
                .withPalette()
        }
        .defaultSize(width: 900, height: 700)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.preferredColorScheme)
                .withPalette()
        }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Session Folder…") { model.chooseSessionFolder() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button("Choose Destination…") { model.chooseDestination() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Export All") { model.startExport() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!model.canExport)
        }

        CommandMenu("Playback") {
            // Home and End live here rather than in the window's hidden
            // shortcuts because, unlike Space or the arrows, they can't be typed
            // into a name or timecode field.
            Button("Playhead to In Point") { model.movePlayheadToTrimIn() }
                .keyboardShortcut(.home, modifiers: [])
            Button("Playhead to Out Point") { model.movePlayheadToTrimOut() }
                .keyboardShortcut(.end, modifiers: [])
        }

        CommandMenu("Trim") {
            Button("Mark In at Playhead") { model.markInAtPlayhead() }
                .keyboardShortcut("i", modifiers: [])
            Button("Mark Out at Playhead") { model.markOutAtPlayhead() }
                .keyboardShortcut("o", modifiers: [])
            Divider()
            Button("Snap to Silence") { model.snapToSilence() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Reset Trim") { model.resetTrim() }
        }
    }
}

/// A document-less utility app: closing the main window should quit, and a folder
/// dropped on the icon (or opened with the app) should load as a session.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app scene once the model exists.
    static weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Running straight from Xcode or `swift run` launches the bare SwiftPM
    /// executable — there's no `.app` around it, so LaunchServices files the
    /// process as "BackgroundOnly": no Dock icon, and no ownership of the menu
    /// bar. Claiming the regular activation policy (and loading the icon out of
    /// the module bundle) gets a dev run behaving like the shipped app.
    ///
    /// When launched from the real bundle this is already true, so it's a no-op.
    private func adoptAppIdentityIfUnbundled() {
        guard Bundle.main.bundleIdentifier == nil else { return }

        NSApp.setActivationPolicy(.regular)

        if let iconURL = Self.embeddedIconURL, let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // The menu bar is built as the app activates, so ask for the foreground
        // once the current launch pass has finished.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// SwiftPM synthesises `Bundle.module` for targets that carry resources; an
    /// Xcode target has no such thing, and puts the icon in the main bundle.
    private static var embeddedIconURL: URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "AppIcon", withExtension: "icns")
        #else
        return Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let folder = urls.first(where: { $0.hasDirectoryPath }) else { return }
        Task { @MainActor in Self.model?.importSession(from: folder) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        adoptAppIdentityIfUnbundled()

        #if DEBUG
        if PreviewRenderer.runIfRequested() {
            NSApp.terminate(nil)
            return
        }
        #endif
        // `--session <path>` opens a folder straight away, which makes it possible
        // to launch into a known state when checking the UI.
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--session"), args.count > index + 1 else { return }
        let folder = URL(fileURLWithPath: args[index + 1])
        Task { @MainActor in Self.model?.importSession(from: folder) }
    }
}
