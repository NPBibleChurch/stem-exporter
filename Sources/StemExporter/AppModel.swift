import AppKit
import Observation
import SwiftUI
import StemExporterKit

/// What the export sheet is currently showing.
enum ExportPhase: Equatable {
    case idle
    case running
    case finished
}

/// A collision the user has to answer before the export can start.
struct CollisionPrompt: Identifiable {
    let id = UUID()
    var files: [URL]
    var plan: ExportPlan
}

@MainActor
@Observable
final class AppModel {

    // MARK: Stores

    let preferences = Preferences()
    let templateStore = TemplateStore()
    let peakCache = PeakCacheStore()
    let player = SessionPlayer()

    // MARK: Session

    var session: Session?
    var peaks: PeakData?
    var analysisFraction: Double?
    var isImporting = false
    var errorMessage: String?

    // MARK: Templates

    var templates: [Template] = []
    var selectedTemplateID: UUID?
    /// The template currently open in the editor window.
    var editingTemplate: Template?

    var selectedTemplate: Template? {
        guard let selectedTemplateID else { return nil }
        return templates.first { $0.id == selectedTemplateID }
    }

    // MARK: Export

    var destination: URL?
    var exportPhase: ExportPhase = .idle
    var exportProgress: ExportProgress?
    var exportResult: ExportResult?
    var exportPlanInFlight: ExportPlan?
    var collisionPrompt: CollisionPrompt?
    private var exportTask: Task<Void, Never>?
    private let cancelFlag = CancelFlag()

    // MARK: Appearance

    var appearance: AppearanceSetting {
        didSet {
            preferences.appearance = appearance
            applyAppearanceToWindowChrome()
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    // MARK: Init

    init() {
        appearance = preferences.appearance
        destination = preferences.lastDestination
        loadTemplates()
        applyAppearanceToWindowChrome()
    }

    private func applyAppearanceToWindowChrome() {
        // SwiftUI's preferredColorScheme covers our own views; the titlebar and any
        // AppKit panels follow NSApp's appearance, so both have to be set.
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Templates

    func loadTemplates() {
        var loaded = templateStore.loadAll()
        if loaded.isEmpty && !preferences.hasSeededTemplates {
            let starter = TemplateStore.starterTemplate()
            try? templateStore.save(starter)
            preferences.hasSeededTemplates = true
            loaded = [starter]
        }
        templates = loaded
        if let last = preferences.lastTemplateID, loaded.contains(where: { $0.id == last }) {
            selectedTemplateID = last
        } else if selectedTemplateID == nil {
            selectedTemplateID = loaded.first?.id
        }
    }

    func selectTemplate(_ id: UUID?) {
        selectedTemplateID = id
        preferences.lastTemplateID = id
        // Switching template re-reads names and gains from it; anything the user
        // typed for this session stays, since those are explicit overrides.
        objectDidChange()
    }

    func saveTemplate(_ template: Template) {
        try? templateStore.save(template)
        loadTemplates()
        selectedTemplateID = template.id
        preferences.lastTemplateID = template.id
    }

    func deleteTemplate(_ template: Template) {
        try? templateStore.delete(template)
        if selectedTemplateID == template.id { selectedTemplateID = nil }
        loadTemplates()
    }

    func duplicateTemplate(_ template: Template) -> Template {
        var copy = template
        copy.id = UUID()
        copy.name = TemplateStore.uniqueName(base: template.name, among: templates.map(\.name))
        copy.slots = template.slots.map { slot in
            var new = slot
            new.id = UUID()
            return new
        }
        saveTemplate(copy)
        return copy
    }

    /// Open the editor on the selected template, or on a fresh one sized to the
    /// loaded session when there's nothing selected yet.
    func openTemplateEditor() {
        if let selectedTemplate {
            editingTemplate = selectedTemplate
        } else {
            let trackCount = session?.trackCount ?? 32
            editingTemplate = Template.placeholder(
                name: TemplateStore.uniqueName(base: "New Template", among: templates.map(\.name)),
                trackCount: trackCount
            )
        }
    }

    // MARK: Stems

    var stems: [StemPlan] {
        guard let session else { return [] }
        return StemResolver.stems(for: session, template: selectedTemplate)
    }

    var exportingStems: [StemPlan] { stems.filter { !$0.skip } }

    var templateFit: TemplateFit? {
        guard let session else { return nil }
        return StemResolver.fit(of: selectedTemplate, to: session)
    }

    func setName(_ name: String, forTrack track: Int) {
        guard session != nil else { return }
        let templateName = selectedTemplate?.slot(containingTrack: track)?.outputName
        let fallback = templateName ?? "Track \(track)"
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == fallback {
            session?.nameOverrides.removeValue(forKey: track)
        } else {
            session?.nameOverrides[track] = trimmed
        }
    }

    func setGain(_ dB: Double, forTrack track: Int) {
        guard session != nil else { return }
        let clamped = min(max(dB, -60), 24)
        let templateGain = selectedTemplate?.slot(containingTrack: track)?.gainDB ?? 0
        if clamped == templateGain {
            session?.gainOverridesDB.removeValue(forKey: track)
        } else {
            session?.gainOverridesDB[track] = clamped
        }
    }

    func setSkip(_ skip: Bool, forTrack track: Int) {
        guard let session else { return }
        let templateSkip = selectedTemplate?.slot(containingTrack: track)?.skip ?? false
        // An auto-skipped track sits at "skipped" without an override, so unticking
        // one has to be recorded as an override or it would spring straight back.
        let base = session.autoSkippedTracks.contains(track) || templateSkip
        if skip == base {
            self.session?.skipOverrides.removeValue(forKey: track)
        } else {
            self.session?.skipOverrides[track] = skip
        }
    }

    // MARK: Empty tracks

    /// Stems currently excluded because the analysis found them empty, and the
    /// user hasn't put them back.
    var autoSkippedStems: [StemPlan] { stems.filter { $0.isAutoSkipped && $0.skip } }

    /// Pre-tick Skip on every track that never rises above the empty threshold.
    ///
    /// Runs once per session, off the back of the peak pass, so a 32-input desk
    /// with eight patched-but-idle channels doesn't hand the user eight silent
    /// files to delete. It's a starting point, not a verdict: the checkbox is
    /// still the user's, and unticking one sticks.
    private func autoSkipEmptyTracks() {
        guard preferences.autoSkipEmptyTracks else { return }
        guard let peaks, let session, !session.didAutoSkipEmptyTracks else { return }

        let threshold = preferences.emptyTrackThresholdDB
        let candidates = StemResolver.stems(for: session, template: selectedTemplate)
        // A stereo pair is judged as a pair: one live side keeps both.
        let empty = candidates.filter { stem in
            peaks.envelope(forTracks: stem.trackNumbers)?.isSilent(belowDB: threshold) ?? false
        }

        self.session?.didAutoSkipEmptyTracks = true
        // Everything reading as empty means the threshold (or the session) is
        // wrong, not that there's nothing to export — leave that one alone.
        guard !empty.isEmpty, empty.count < candidates.count else { return }
        // Stored per track rather than per stem, so the set still means something
        // if a template with different pairings is picked afterwards.
        self.session?.autoSkippedTracks = Set(empty.flatMap(\.trackNumbers))
    }

    /// Put the automatically excluded tracks back, leaving ticks the user made.
    func restoreAutoSkippedTracks() {
        session?.autoSkippedTracks = []
    }

    /// Fold this session's tweaks back into the template, for the times a "just
    /// this week" change turns out to be permanent.
    func saveOverridesToTemplate() {
        guard var template = selectedTemplate, let session else { return }
        for index in template.slots.indices {
            let track = template.slots[index].primaryTrack
            if let name = session.nameOverrides[track] { template.slots[index].outputName = name }
            if let gain = session.gainOverridesDB[track] { template.slots[index].gainDB = gain }
            if let skip = session.skipOverrides[track] { template.slots[index].skip = skip }
        }
        saveTemplate(template)
        self.session?.nameOverrides.removeAll()
        self.session?.gainOverridesDB.removeAll()
        self.session?.skipOverrides.removeAll()
    }

    var hasSessionOverrides: Bool {
        guard let session else { return false }
        return !session.nameOverrides.isEmpty
            || !session.gainOverridesDB.isEmpty
            || !session.skipOverrides.isEmpty
    }

    // MARK: Peaks

    func peakTrack(for stem: StemPlan) -> PeakData.Track? {
        peaks?.envelope(forTracks: stem.trackNumbers)
    }

    // MARK: Trim

    func setTrimIn(seconds: TimeInterval) {
        guard let session else { return }
        let frames = Timecode.frames(forSeconds: seconds, sampleRate: session.sampleRate)
        self.session?.trimInFrames = min(max(0, frames), session.trimOutFrames - 1)
    }

    func setTrimOut(seconds: TimeInterval) {
        guard let session else { return }
        let frames = Timecode.frames(forSeconds: seconds, sampleRate: session.sampleRate)
        self.session?.trimOutFrames = max(min(session.totalFrames, frames), session.trimInFrames + 1)
    }

    func setTrimInFraction(_ fraction: Double) {
        guard let session else { return }
        setTrimIn(seconds: fraction * session.totalDuration)
    }

    func setTrimOutFraction(_ fraction: Double) {
        guard let session else { return }
        setTrimOut(seconds: fraction * session.totalDuration)
    }

    func resetTrim() {
        guard let session else { return }
        self.session?.trimInFrames = 0
        self.session?.trimOutFrames = session.totalFrames
    }

    /// Nudge In forward and Out backward to the nearest point that isn't silence.
    func snapToSilence() {
        guard let peaks, session != nil else { return }
        guard let range = SilenceDetector.contentRange(
            in: peaks,
            thresholdDB: preferences.silenceThresholdDB
        ) else {
            errorMessage = "The whole session reads as silence at the current threshold, so nothing was trimmed."
            return
        }
        session?.trimInFrames = range.inFrame
        session?.trimOutFrames = range.outFrame
    }

    /// Mark In / Out at the playhead, QuickTime-style.
    func markInAtPlayhead() { setTrimIn(seconds: player.currentTime) }
    func markOutAtPlayhead() { setTrimOut(seconds: player.currentTime) }

    // MARK: Playhead

    var playheadSeconds: TimeInterval { player.currentTime }

    func movePlayhead(to seconds: TimeInterval) {
        guard session != nil else { return }
        player.seek(to: seconds)
    }

    func movePlayhead(toFraction fraction: Double) {
        guard let session else { return }
        movePlayhead(to: fraction * session.totalDuration)
    }

    /// Arrow-key nudges. The player clamps to the session bounds, so walking off
    /// either end just parks the playhead there.
    func nudgePlayhead(by seconds: TimeInterval) {
        guard session != nil else { return }
        player.seek(to: player.currentTime + seconds)
    }

    /// The two positions worth jumping back to while setting a trim.
    func movePlayheadToTrimIn() { movePlayhead(to: session?.trimInSeconds ?? 0) }
    func movePlayheadToTrimOut() { movePlayhead(to: session?.trimOutSeconds ?? 0) }

    func beginScrub() { player.beginScrub() }
    func endScrub() { player.endScrub() }

    func scrubPlayhead(toFraction fraction: Double) {
        guard let session else { return }
        player.scrub(to: fraction * session.totalDuration)
    }

    // MARK: Session import

    func chooseSessionFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Session"
        panel.message = "Choose the folder holding this session's WAV files."
        panel.directoryURL = preferences.lastSessionFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSession(from: url)
    }

    func importSession(from folder: URL) {
        isImporting = true
        errorMessage = nil
        player.stop()

        do {
            var loaded = try SessionLoader.load(folder: folder)
            loaded.templateID = selectedTemplateID
            session = loaded
            peaks = nil
            preferences.lastSessionFolder = folder
            // A template built for a different channel count still opens the session;
            // pick one that matches if we have it, rather than refusing.
            if let match = templates.first(where: { $0.trackCount == loaded.trackCount }),
               selectedTemplate?.trackCount != loaded.trackCount {
                selectTemplate(match.id)
            }
            analyzePeaks()
        } catch {
            errorMessage = error.localizedDescription
        }
        isImporting = false
    }

    func movePart(from source: IndexSet, to destination: Int) {
        session?.parts.move(fromOffsets: source, toOffset: destination)
        session?.reindexParts()
        peaks = nil
        analyzePeaks()
    }

    func setPartExcluded(_ excluded: Bool, at index: Int) {
        guard session?.parts.indices.contains(index) == true else { return }
        session?.parts[index].isExcluded = excluded
        session?.reindexParts()
        peaks = nil
        analyzePeaks()
    }

    private var analysisTask: Task<Void, Never>?

    func analyzePeaks() {
        guard let session else { return }
        analysisTask?.cancel()
        if let cached = peakCache.load(for: session) {
            peaks = cached
            autoSkipEmptyTracks()
            preparePlayer()
            return
        }

        analysisFraction = 0
        let snapshot = session
        let cache = peakCache
        analysisTask = Task { [weak self] in
            let target = self
            let analyzer = PeakAnalyzer()
            let result: PeakData? = await Task.detached(priority: .userInitiated) {
                try? analyzer.analyze(
                    session: snapshot,
                    progress: { progress in
                        let fraction = progress.fractionComplete
                        Task { @MainActor in target?.analysisFraction = fraction }
                    },
                    isCancelled: { Task.isCancelled }
                )
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.analysisFraction = nil
                guard let result else { return }
                self.peaks = result
                cache.store(result, for: snapshot)
                self.autoSkipEmptyTracks()
                self.preparePlayer()
            }
        }
    }

    private func preparePlayer() {
        guard let session else { return }
        player.prepare(session: session)
        // A fresh session starts cued at the In point rather than at zero, so the
        // playhead is somewhere useful before it has ever been dragged.
        player.seek(to: session.trimInSeconds)
    }

    // MARK: Destination

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should the stems be written?"
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        preferences.lastDestination = url
    }

    // MARK: Export

    var canExport: Bool {
        session != nil
            && !exportingStems.isEmpty
            && session?.hasValidTrim == true
            && exportPhase != .running
    }

    var exportBlockReason: String? {
        guard session != nil else { return "Add a session folder to get started." }
        if exportingStems.isEmpty { return "Every track is excluded — nothing to export." }
        if session?.hasValidTrim != true { return "The trim selection is empty." }
        return nil
    }

    func startExport() {
        guard let session else { return }
        guard let folder = destination ?? preferences.lastDestination else {
            chooseDestination()
            if destination != nil { startExport() }
            return
        }

        let job = ExportJob(
            outputFolder: folder,
            sessionName: session.name,
            namingPattern: preferences.namingPattern,
            collisionPolicy: preferences.collisionPolicy,
            createDatedSubfolder: preferences.createDatedSubfolder
        )
        let plan = ExportPlanner.plan(session: session, stems: exportingStems, job: job)

        // Ask once per export, not once per file.
        if plan.hasCollisions && preferences.collisionPolicy == .ask {
            collisionPrompt = CollisionPrompt(files: plan.collisions, plan: plan)
            return
        }
        run(plan: plan)
    }

    func resolveCollision(with policy: CollisionPolicy) {
        guard let prompt = collisionPrompt, let session else { return }
        collisionPrompt = nil
        let job = ExportJob(
            outputFolder: destination ?? prompt.plan.folder,
            sessionName: session.name,
            namingPattern: preferences.namingPattern,
            collisionPolicy: policy,
            createDatedSubfolder: preferences.createDatedSubfolder
        )
        run(plan: ExportPlanner.plan(session: session, stems: exportingStems, job: job, policy: policy))
    }

    private func run(plan: ExportPlan) {
        guard let session else { return }
        player.stop()
        exportPlanInFlight = plan
        exportPhase = .running
        exportProgress = ExportProgress(
            framesWritten: 0,
            totalFrames: session.trimmedFrames,
            stemFractions: [:],
            finishedStems: [],
            elapsed: 0
        )
        exportResult = nil
        cancelFlag.reset()

        let flag = cancelFlag
        exportTask = Task { [weak self] in
            let target = self
            let engine = ExportEngine(session: session, plan: plan)
            let outcome: Result<ExportResult, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let result = try engine.run(
                        progress: { progress in
                            Task { @MainActor in target?.exportProgress = progress }
                        },
                        isCancelled: { flag.isCancelled }
                    )
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }.value

            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let result):
                    self.exportResult = result
                    self.exportPhase = result.wasCancelled ? .idle : .finished
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    self.exportPhase = .idle
                }
                self.exportPlanInFlight = nil
            }
        }
    }

    func cancelExport() {
        cancelFlag.cancel()
    }

    func dismissExport() {
        exportPhase = .idle
        exportResult = nil
        exportProgress = nil
    }

    func revealInFinder() {
        guard let result = exportResult else { return }
        let urls = result.stems.map(\.fileURL)
        if urls.isEmpty {
            NSWorkspace.shared.open(result.folder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    // MARK: Plumbing

    /// Observation tracks stored properties; some edits only change derived values.
    private func objectDidChange() {
        session = session
    }
}

/// Cancellation shared with the export thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func reset() {
        lock.lock(); cancelled = false; lock.unlock()
    }
}

enum WindowID {
    static let main = "main"
    static let templateEditor = "template-editor"
}
