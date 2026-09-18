#!/usr/bin/env swift
// Generates a synthetic multi-part, 32-channel BWF session to try the app with,
// shaped like a real one: silence at the head and tail, a stereo pair, an unused
// channel, and one input running hot enough to clip if you push its gain.
//
//   swift Scripts/make-demo-session.swift ~/Desktop/DemoSession

import Foundation

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "./DemoSession")
let channels = 32
let sampleRate = 48_000
let bitDepth = 24
let partSeconds = 10.0
let partCount = 2

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func appendASCII(_ d: inout Data, _ s: String) { d.append(contentsOf: Array(s.utf8)) }
func appendU16(_ d: inout Data, _ v: UInt16) {
    d.append(contentsOf: [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)])
}
func appendU32(_ d: inout Data, _ v: UInt32) {
    d.append(contentsOf: [
        UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
        UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24),
    ])
}
func appendFixed(_ d: inout Data, _ s: String, _ length: Int) {
    var bytes = Array(s.utf8.prefix(length))
    bytes.append(contentsOf: Array(repeating: UInt8(0), count: length - bytes.count))
    d.append(contentsOf: bytes)
}

/// Amplitude envelope: the "service" runs from 2s in to 2s before the end.
func envelope(globalTime t: Double, total: Double) -> Double {
    let fade = 1.5
    if t < 2 || t > total - 2 { return 0 }
    let up = min(1, (t - 2) / fade)
    let down = min(1, (total - 2 - t) / fade)
    return up * down
}

func sample(channel: Int, time t: Double, total: Double) -> Double {
    let env = envelope(globalTime: t, total: total)
    guard env > 0 else { return 0 }

    switch channel {
    case 0:  // Piano — decaying chord hits
        let beat = t.truncatingRemainder(dividingBy: 1.2)
        let decay = exp(-beat * 3)
        return env * decay * 0.35 * (sin(2 * .pi * 261.6 * t) + sin(2 * .pi * 329.6 * t) + sin(2 * .pi * 392 * t)) / 3
    case 1:  // Violin — deliberately hot, so +3 dB clips
        return env * 0.94 * sin(2 * .pi * 440 * t + 3 * sin(2 * .pi * 5 * t))
    case 2:  // Lead vocal — quieter, vibrato
        return env * 0.28 * sin(2 * .pi * 220 * t + 0.8 * sin(2 * .pi * 6.2 * t))
    case 3:  // Backing vox
        return env * 0.18 * (sin(2 * .pi * 330 * t) + sin(2 * .pi * 277 * t)) / 2
    case 4, 5:  // Overheads L/R — same source, slightly decorrelated
        let offset = channel == 4 ? 0.0 : 0.0007
        let room = sin(2 * .pi * 880 * (t + offset)) * 0.12
        let hits = exp(-(t.truncatingRemainder(dividingBy: 0.6)) * 8) * 0.3
        return env * (room + hits * sin(2 * .pi * 1500 * (t + offset)))
    case 6:  // Unused input — dead
        return 0
    case 7:  // Acoustic guitar
        let pluck = exp(-(t.truncatingRemainder(dividingBy: 0.4)) * 6)
        return env * 0.3 * pluck * sin(2 * .pi * 196 * t)
    default:
        // The rest: quiet, distinct tones so every stem is identifiable by ear.
        let freq = 110.0 * Double(channel - 6)
        return env * 0.06 * sin(2 * .pi * freq * t)
    }
}

let bytesPerSample = bitDepth / 8
let bytesPerFrame = bytesPerSample * channels
let framesPerPart = Int(partSeconds * Double(sampleRate))
let totalSeconds = partSeconds * Double(partCount)
let fullScale = Double(1 << (bitDepth - 1))

for part in 0..<partCount {
    let url = outDir.appendingPathComponent(String(format: "%08d.WAV", part + 1))
    var audio = Data(count: framesPerPart * bytesPerFrame)
    let startFrame = part * framesPerPart

    audio.withUnsafeMutableBytes { raw in
        let base = raw.baseAddress!
        for frame in 0..<framesPerPart {
            let t = Double(startFrame + frame) / Double(sampleRate)
            for channel in 0..<channels {
                let value = sample(channel: channel, time: t, total: totalSeconds)
                let scaled = max(-fullScale, min(fullScale - 1, (value * fullScale).rounded()))
                let v = UInt32(bitPattern: Int32(scaled))
                let p = base.advanced(by: frame * bytesPerFrame + channel * bytesPerSample)
                    .assumingMemoryBound(to: UInt8.self)
                p[0] = UInt8(truncatingIfNeeded: v)
                p[1] = UInt8(truncatingIfNeeded: v >> 8)
                p[2] = UInt8(truncatingIfNeeded: v >> 16)
            }
        }
    }

    var file = Data()
    appendASCII(&file, "RIFF"); appendU32(&file, 0); appendASCII(&file, "WAVE")

    appendASCII(&file, "fmt "); appendU32(&file, 16)
    appendU16(&file, 1)
    appendU16(&file, UInt16(channels))
    appendU32(&file, UInt32(sampleRate))
    appendU32(&file, UInt32(sampleRate * bytesPerFrame))
    appendU16(&file, UInt16(bytesPerFrame))
    appendU16(&file, UInt16(bitDepth))

    // A bext chunk, as a Sound Devices recorder would write.
    var bext = Data()
    appendFixed(&bext, "Demo session for Stem Exporter", 256)
    appendFixed(&bext, "Demo Recorder", 32)
    appendFixed(&bext, "DEMO-\(part + 1)", 32)
    appendFixed(&bext, "2026-09-13", 10)
    appendFixed(&bext, "09:30:00", 8)
    let timeRef = UInt64(9 * 3600 + 30 * 60) * UInt64(sampleRate) + UInt64(startFrame)
    appendU32(&bext, UInt32(truncatingIfNeeded: timeRef))
    appendU32(&bext, UInt32(truncatingIfNeeded: timeRef >> 32))
    appendU16(&bext, 1)
    bext.append(Data(repeating: 0, count: 64 + 190))
    appendASCII(&file, "bext"); appendU32(&file, UInt32(bext.count)); file.append(bext)

    appendASCII(&file, "data"); appendU32(&file, UInt32(audio.count)); file.append(audio)

    var sizeField = Data(); appendU32(&sizeField, UInt32(file.count - 8))
    file.replaceSubrange(4..<8, with: sizeField)

    try file.write(to: url)
    print("wrote \(url.lastPathComponent) — \(channels) ch, \(Int(partSeconds))s, \(file.count / 1_000_000) MB")
}

// Recorders drop a log file alongside; the importer should ignore it.
try? Data("demo log\n".utf8).write(to: outDir.appendingPathComponent("SE_LOG.BIN"))
print("\nSession folder: \(outDir.path)")
