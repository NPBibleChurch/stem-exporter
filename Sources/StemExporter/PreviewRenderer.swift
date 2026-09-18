#if DEBUG
import AppKit
import SwiftUI
import StemExporterKit

/// Renders each screen to a PNG offscreen, for checking layout without driving the
/// UI by hand:
///
///     StemExporter --render-previews <output-dir> [--session <folder>]
///
/// DEBUG-only; it isn't compiled into a release build.
@MainActor
enum PreviewRenderer {

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-previews"), args.count > index + 1 else {
            return false
        }
        let outputDir = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let model = AppModel()
        if let sessionIndex = args.firstIndex(of: "--session"), args.count > sessionIndex + 1 {
            let folder = URL(fileURLWithPath: args[sessionIndex + 1])
            if var session = try? SessionLoader.load(folder: folder) {
                session.trimInFrames = Int64(2.1 * session.sampleRate)
                session.trimOutFrames = Int64(min(Double(session.totalFrames), 17.9 * session.sampleRate))
                model.session = session
                model.peaks = try? PeakAnalyzer(bucketCount: 1200).analyze(session: session)
                model.destination = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop/Stems")
            }
        }

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "-dark" : ""
            render(
                MainView(), model: model, scheme: scheme,
                size: CGSize(width: 1200, height: 740),
                to: outputDir.appendingPathComponent("Main\(suffix).png")
            )
            render(
                TemplateEditorView(), model: model, scheme: scheme,
                size: CGSize(width: 900, height: 700),
                to: outputDir.appendingPathComponent("TemplateEditor\(suffix).png")
            )
            render(
                SettingsView(), model: model, scheme: scheme,
                size: CGSize(width: 520, height: 400),
                to: outputDir.appendingPathComponent("Settings\(suffix).png")
            )
            render(
                ExportProgressView(), model: exportingModel(from: model), scheme: scheme,
                size: CGSize(width: 480, height: 420),
                to: outputDir.appendingPathComponent("ExportProgress\(suffix).png")
            )
            render(
                ExportSummaryView(), model: finishedModel(from: model), scheme: scheme,
                size: CGSize(width: 520, height: 520),
                to: outputDir.appendingPathComponent("ExportSummary\(suffix).png")
            )
        }

        print("Rendered previews to \(outputDir.path)")
        return true
    }

    /// Render through a real hosted window rather than `ImageRenderer`.
    ///
    /// `ImageRenderer` draws the SwiftUI tree in isolation, which leaves scroll
    /// views empty and AppKit-backed controls (text fields, buttons) as
    /// placeholders — so it can't tell you whether the table actually lays out.
    /// Hosting the view in an offscreen window and caching its display captures
    /// what the app really draws.
    private static func render<V: View>(_ view: V, model: AppModel, scheme: ColorScheme, size: CGSize, to url: URL) {
        let wrapped = view
            .environment(model)
            .environment(\.colorScheme, scheme)
            .environment(\.palette, Palette.forScheme(scheme))
            .background(Palette.forScheme(scheme).windowBackground)
            .frame(width: size.width, height: size.height)

        let hosting = NSHostingView(rootView: wrapped)
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setIsVisible(true)
        window.orderBack(nil)

        // Give SwiftUI a few turns of the run loop to build and lay out the tree.
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<6 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("!! could not render \(url.lastPathComponent)")
            window.close()
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("!! could not encode \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }

    /// A model posed mid-export, so the progress sheet has something to draw.
    private static func exportingModel(from base: AppModel) -> AppModel {
        guard let session = base.session else { return base }
        let job = ExportJob(
            outputFolder: URL(fileURLWithPath: "/tmp/Stems"),
            sessionName: session.name
        )
        let plan = ExportPlanner.plan(session: session, stems: base.exportingStems, job: job)
        base.exportPlanInFlight = plan
        base.exportPhase = .running
        var fractions: [UUID: Double] = [:]
        for item in plan.items { fractions[item.id] = 0.58 }
        base.exportProgress = ExportProgress(
            framesWritten: Int64(Double(session.trimmedFrames) * 0.58),
            totalFrames: session.trimmedFrames,
            stemFractions: fractions,
            finishedStems: Set(plan.items.prefix(3).map(\.id)),
            elapsed: 55
        )
        return base
    }

    private static func finishedModel(from base: AppModel) -> AppModel {
        guard let session = base.session else { return base }
        let job = ExportJob(outputFolder: URL(fileURLWithPath: "/tmp/Stems"), sessionName: session.name)
        let plan = ExportPlanner.plan(session: session, stems: base.exportingStems, job: job)
        let stems = plan.items.enumerated().map { index, item in
            ExportedStem(
                id: item.id,
                outputName: item.stem.outputName,
                fileURL: item.url,
                sourceTrackNumbers: item.stem.trackNumbers,
                durationSamples: session.trimmedFrames,
                byteCount: Int64(session.trimmedFrames) * Int64(item.stem.channelCount) * 3,
                isStereo: item.stem.isStereo,
                firstClipAtSeconds: index == 1 ? 724 : nil,
                clippedSampleCount: index == 1 ? 9_100 : 0
            )
        }
        base.exportPhase = .finished
        base.exportResult = ExportResult(
            folder: URL(fileURLWithPath: "/tmp/Stems/Sunday Service Sep 13 2026"),
            stems: stems,
            warnings: stems.count > 1
                ? ["\(stems[1].fileURL.lastPathComponent) clipped briefly at 00:12:04 — check gain on that channel"]
                : [],
            trimmedDuration: session.trimmedDuration,
            sourceDuration: session.totalDuration
        )
        return base
    }
}
#endif
