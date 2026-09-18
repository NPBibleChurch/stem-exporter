import AVFoundation
import Observation
import StemExporterKit

/// Auditions the session so the trim can be set by ear.
///
/// Playback is a mono downmix streamed from the source in small buffers — not all
/// 32 channels pushed live through an engine. That keeps auditioning a 12 GB
/// session as cheap as scrubbing the waveform, and it's the same summary the
/// waveform is drawn from, so what you hear matches what you see.
@MainActor
@Observable
final class SessionPlayer {

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var isAvailable = false

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var reader: SessionReader?
    private var outputFormat: AVAudioFormat?
    private var sampleRate: Double = 48_000
    private var totalFrames: Int64 = 0

    /// Frames already handed to the engine, used to work out where the playhead is.
    private var scheduledFrame: Int64 = 0
    private var startFrame: Int64 = 0
    private var pendingBuffers = 0
    private var displayTimer: Timer?
    private var generation = 0

    private let bufferFrames = 16_384
    private let maxPendingBuffers = 4
    private let producerQueue = DispatchQueue(label: "session-player.producer", qos: .userInitiated)

    // MARK: Setup

    func prepare(session: Session) {
        stop()
        guard session.totalFrames > 0 else {
            isAvailable = false
            return
        }

        reader = SessionReader(session: session)
        sampleRate = session.sampleRate
        totalFrames = session.totalFrames

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: session.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            isAvailable = false
            return
        }
        outputFormat = format

        if engine.attachedNodes.contains(node) == false {
            engine.attach(node)
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        isAvailable = true
    }

    // MARK: Transport

    func togglePlay(from seconds: TimeInterval) {
        if isPlaying {
            pause()
        } else {
            play(from: seconds)
        }
    }

    func play(from seconds: TimeInterval) {
        guard isAvailable, reader != nil else { return }
        stopPlayback(resetTime: false)

        generation += 1
        startFrame = max(0, min(totalFrames - 1, Timecode.frames(forSeconds: seconds, sampleRate: sampleRate)))
        scheduledFrame = startFrame
        currentTime = seconds
        pendingBuffers = 0

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            isAvailable = false
            return
        }

        node.play()
        isPlaying = true
        for _ in 0..<maxPendingBuffers { scheduleNextBuffer() }
        startDisplayTimer()
    }

    func pause() {
        guard isPlaying else { return }
        node.pause()
        isPlaying = false
        displayTimer?.invalidate()
        displayTimer = nil
    }

    func stop() {
        stopPlayback(resetTime: true)
    }

    private func stopPlayback(resetTime: Bool) {
        generation += 1
        displayTimer?.invalidate()
        displayTimer = nil
        if node.isPlaying { node.stop() }
        if engine.isRunning { engine.pause() }
        isPlaying = false
        pendingBuffers = 0
        if resetTime { currentTime = 0 }
    }

    func seek(to seconds: TimeInterval) {
        if isPlaying {
            play(from: seconds)
        } else {
            currentTime = max(0, min(seconds, Double(totalFrames) / sampleRate))
        }
    }

    // MARK: Streaming

    private func scheduleNextBuffer() {
        guard isPlaying, let reader, let format = outputFormat else { return }
        guard scheduledFrame < totalFrames else { return }
        guard pendingBuffers < maxPendingBuffers + 1 else { return }

        let from = scheduledFrame
        let frames = min(bufferFrames, Int(totalFrames - from))
        scheduledFrame += Int64(frames)
        pendingBuffers += 1
        let token = generation

        producerQueue.async { [weak self] in
            let samples = (try? reader.readMonoDownmix(fromFrame: from, frames: frames)) ?? []
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else {
                Task { @MainActor [weak self] in self?.bufferFinished(token: token) }
                return
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }

            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isPlaying else {
                    self?.bufferFinished(token: token)
                    return
                }
                let sink = self
                self.node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { _ in
                    Task { @MainActor in sink.bufferFinished(token: token) }
                }
            }
        }
    }

    private func bufferFinished(token: Int) {
        guard generation == token else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        if scheduledFrame >= totalFrames {
            if pendingBuffers == 0 { stopPlayback(resetTime: false) }
            return
        }
        scheduleNextBuffer()
    }

    // MARK: Playhead

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateCurrentTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func updateCurrentTime() {
        guard isPlaying else { return }
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        currentTime = Double(startFrame) / sampleRate + max(0, elapsed)
    }
}
