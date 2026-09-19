# Stem Exporter — macOS App Spec

2026-09-18 · @Someone

## Overview

A native macOS app that automates a weekly manual task: turning a 32-track polyphonic WAV recording (from a Sound Devices field recorder) into a folder of individually named, trimmed stem files, ready for mixing or archiving.

**Goals**

- Import a session's WAV files, from a folder, whatever their channel count (not hardcoded to 32 — detected from the file itself, so other gear or configurations still work).
- Automatically recombine split files back into continuous per-track audio.
- Apply a saved track name template (Track 1 -> "Piano", Track 2 -> "Violin", etc.) so tracks come out named consistently every week.
- Support stereo-linked pairs in a template (e.g. Tracks 7+8 -> "Overheads L/R"), exported as a single interleaved stereo file.
- Trim the whole session to a single start/end point before export (e.g. cut dead air before/after the service).
- Export all resulting stems in one batch, quickly and reliably, to a chosen folder.
- Explicit Light / Dark / System appearance setting — not just following macOS automatically.

**Non-goals (v1)**

- No mixing or EQ. Per-track gain (a simple level trim, see Track name templates) is the one exception, applied on export; no other audio processing.
- No timeline editing or per-track independent trimming.
- No cloud sync or multi-user collaboration - this is a single-user local tool.

**Primary user:** Noah, doing this once a week after recording a church service / event with a 32-track Sound Devices recorder. The tool should turn a 10-15 minute manual chore (in something like a DAW) into a couple of clicks.

## Workflow

1. **Add** a session folder. Point the app at one folder; it takes every WAV file in it (one file or many — no minimum, no pattern required), sorts them by filename, and treats them as one session (see Combining multi-part sessions below).
2. **Pick a template.** Choose a saved track name template from a dropdown, or start from "No template" and name tracks manually this once.
3. **Review tracks.** A table lists every resulting output stem (after stereo pairs are merged) with its assigned name, source track number(s), and a small waveform. Any track without a template match shows as "Track N" and can be renamed or excluded inline. Gain is also editable right here per track — a session-level override on top of the template's default — and the waveform updates live as it's adjusted.
4. **Set the trim.** Scrub a combined waveform (a rough mono summary of all tracks) to set one In point and one Out point for the whole session.
5. **Choose destination.** Pick (or reuse the last) output folder.
6. **Export.** One click renders every stem, trimmed, into that folder. A progress view shows per-track progress and total time remaining; the app can continue exporting while the user works in other apps.
7. **Done.** A summary shows the files written, with a "Reveal in Finder" button and any warnings (e.g. a track that clipped, a name collision).

## Track name templates

A template maps physical input track numbers to an output stem name, and optionally links two tracks as a stereo pair. Track count isn't hardcoded to 32 — it's read from the session's WAV file, so a template built for a 32-track session and a session that happens to have a different channel count are just compared: if a session's track count doesn't match the selected template's, the app says so and falls back to "Track N" placeholders for anything beyond what the template covers, rather than guessing or refusing to open the session.

**Per-slot fields**

- Track number(s): a single track (mono) or two adjacent/non-adjacent tracks marked as a stereo pair (L/R).
- Output name: e.g. "Piano", "Lead Vocal", "Overheads".
- Optional: skip/exclude this track entirely from export (for unused inputs).
- Gain: a per-track level trim in dB (e.g. -6.0 to +12.0) that lives in the template as a default, for channels that are reliably too hot or too quiet week to week (a mic that runs hot, a distant overhead) — set once so most sessions need no adjustment. It's also editable per-session right in the main track table (a session-level override on top of the template default, not a change to the template unless explicitly saved back to it), since actual levels still vary week to week.

**Managing templates**

- Templates are named and saved (e.g. "Sunday Service", "Youth Band", "Christmas Program") and appear in a picker in the main window and in Settings.
- A dedicated Template Editor window: a 32-row table (Track # / Name / Stereo link / Skip), with a "Link as stereo pair" action that merges two selected rows into one linked row.
- Duplicate an existing template to start a new one; the currently-loaded template can be edited and re-saved without leaving the export screen (an "Edit Template" affordance opens the same editor).
- Templates are stored locally (see Data model) and can be exported/imported as a small JSON file to back up or move to another Mac.

## Combining multi-part sessions

Sound Devices recorders name split files sequentially in one folder (e.g. `00000001.WAV`, `00000002.WAV`, ...), continuing sample-accurately where the previous file stopped, each carrying the same 32-channel layout and an `SE_LOG.BIN` alongside them.

- On import, the app takes the whole folder you point it at as one session — whether it holds one WAV file or several — sorted by filename and concatenated in that order. No numbering pattern or naming convention is required to trigger combining; a single-file session is just a session with one part.
- Each imported track is the sample-accurate concatenation of that track's audio across every part, in filename order, before any trim or export happens.
- The app shows what it found ("Session: 2 parts, 00000001.WAV -> 00000002.WAV, 18m 42s total" — or "Session: 1 file, 12m 10s" for a single-file folder), and the part order can be corrected manually (reordered or a file excluded) if the filenames don't sort the way you'd expect.
- If the files in the folder don't actually match each other (different track counts, sample rates, or bit depths), the app flags that rather than silently merging — that's the one sanity check it does; otherwise the whole folder goes in as one session, however many WAVs it holds.

## Trim

One global In point and one Out point apply to every output stem, since all 32 tracks are sample-synced on the same clock.

- A single combined waveform (a fast mono downmix/peak summary, not all 32 tracks rendered individually) is shown for scrubbing, with a timecode readout (HH:MM:SS.mmm) for both handles.
- In/Out can be set by dragging handles on the waveform, typing exact timecodes, or playing back and marking with keyboard shortcuts (I / O), similar to QuickTime Player trim.
- Optional snap-to-silence: a button that nudges In forward / Out backward to the nearest low-level (silent) point, to quickly trim off dead air at head and tail.
- The trimmed region length is shown live (e.g. "Exporting 42m 10s of 46m 03s"); zero-length or reversed selections are blocked.

## Export settings

- **Format:** WAV (BWF) by default, same bit depth and sample rate as the source — no resampling or conversion on that path (source is typically 24-bit/48kHz). AIFF, FLAC, Apple Lossless and AAC (128/192/256/320 kbps) are selectable in Settings › Export Defaults and are encoded by the system codecs; sample rate and channel count are still passed through untouched. MP3 is deliberately absent: macOS ships an MP3 decoder but no encoder, so AAC is the lossy option.
- **File naming:** `<Session Name> - <Track#> - <Track Name>.wav by default (e.g. "2026-09-13 Service - 03 - Piano.wav"), track number zero-padded to two digits so Finder sorts stems in input order; session name editable per export, pattern itself configurable later`.
- **Stereo pairs:** exported as one interleaved stereo WAV, not two mono files.
- **Destination:** a chosen folder; the app remembers and defaults to the last-used folder, with an option to create a dated subfolder per session automatically.
- **Collisions:** if a file of the same name exists, the app asks once (per export) whether to overwrite, or auto-append " (2)".
- **Metadata:** each exported stem carries basic BWF metadata (original timestamp, source file reference) for traceability back to the session.

## Data model

```
Template
  id: UUID
  name: String                 // "Sunday Service"
  trackCount: Int               // channel count this template expects, e.g. 32
  slots: [TemplateSlot]

TemplateSlot
  id: UUID
  outputName: String           // "Piano"
  trackNumbers: [Int]          // [3] for mono, [7, 8] for a stereo pair
  isStereo: Bool
  skip: Bool                   // excluded from export
  gainDB: Double                // per-track level trim, e.g. -6.0...+12.0, default 0.0

Session                        // one import batch, built at runtime (not persisted long-term)
  parts: [SessionFile]         // ordered, concatenated
  trackCount: Int              // read from the file, whatever it is
  sampleRate: Double
  bitDepth: Int
  totalDuration: TimeInterval
  trimIn: TimeInterval
  trimOut: TimeInterval
  templateID: UUID?
  gainOverridesDB: [Int: Double]    // per-track-number session overrides on top of the template's gainDB
  nameOverrides: [Int: String]      // per-track-number session overrides on top of the template's outputName

SessionFile
  url: URL
  sampleCount: Int64
  startOffsetInSession: Int64      // running sample offset once ordered

ExportJob
  outputFolder: URL
  namingPattern: String
  results: [ExportedStem]          // for the summary screen

ExportedStem
  outputName: String
  fileURL: URL
  sourceTrackNumbers: [Int]
  durationSamples: Int64
```

Templates persist as small JSON files (or a lightweight store like `UserDefaults`/a SQLite file via `GRDB`) under Application Support, and are exportable/importable as standalone `.json` for backup.

## Technical architecture

**Platform:** Native Swift, SwiftUI for the interface, confirmed minimum macOS 14 (Sonoma), so it can use current SwiftUI table/file-importer APIs; AppKit interop where SwiftUI falls short (e.g. custom waveform view, a proper NSOpenPanel-backed multi-file importer). Appearance is an explicit Light / Dark / System setting stored in preferences and applied via .preferredColorScheme (System = no override, following macOS as usual); every custom-drawn view (waveform, trim scrubber, clip markers) reads its colors from a small semantic palette that swaps per scheme, rather than hardcoding light-mode hex values.

**Audio I/O — read/write BWF WAV directly, not through AVAudioFile:** AVFoundation's `AVAudioFile` is fine for playback/preview but is awkward for surgical, multi-hundred-GB multichannel work (it wants to decode through `AVAudioPCMBuffer`). The core export engine instead:

- Parses the RIFF/BWF structure by hand (a small internal WAV chunk reader`  that walks fmt /JUNK/bext/iXML/etc. generically to locate data, without reading or using any chunk's content beyond fmt and ` `data`) to get exact byte offsets and the PCM layout — this also sidesteps any AVFoundation size ceiling on very large multi-GB files.
- Streams the `data` chunk in fixed-size blocks (e.g. 4–16 MB), de-interleaving every requested output channel from each block in the same single pass (see Concurrency, below), and writes each output stem incrementally with a raw `FileHandle`/`DispatchIO` writer — so 32 tracks are never all held in memory at once, and a 4+ GB source file is never loaded whole.
- For playback/scrubbing (the combined preview waveform, audition), a lightweight downmix pass builds a cached peak file (min/max per N samples) once on import, rendered as vector shapes — not `AVAudioEngine` played live from all 32 channels.

**Gain:** applied per output stem as a simple linear multiply (10^(dB/20)) on each sample during the same streaming write pass used for trim/export — no separate processing pass, no plugin chain. The cached peak file used for waveform previews is rebuilt (or scaled) per track when its template gain changes, so the preview reflects it immediately. Samples are clamped (hard-limited) at full scale rather than wrapping/overflowing. Clipping is surfaced at every stage, not just after export: the peak cache tracks which samples would hit full scale at the current gain, so a track's waveform (in both the main table and the template editor) redraws its clipped regions in red the moment gain is changed — live, before export runs — and any stem that actually clipped is also flagged in the Export Summary (see Export summary) as a final check. A stereo-linked pair shares one gain value, applied identically to both channels, to preserve the stereo balance.

**Trim:** applied as a sample-offset window (`trimIn`/`trimOut` converted to frame indices) directly against the byte-offset math above — no decode/re-encode, just reading a different byte range per file.

**Multi-file concatenation:** each `SessionFile`'s frame range is resolved into one virtual sample timeline per track; the export writer walks that timeline part-by-part, so a stem spanning file 1 -> file 2 is one continuous write with no audible seam (sample-accurate since Sound Devices continuation files don't overlap or drop samples).

**Concurrency:** `NOT one Task per output stem — the 32 channels are interleaved in one file, so reading it once per stem would mean reading the same multi-GB source up to 31 times over. Instead, ONE sequential read pass streams the source block-by-block; each block is de-interleaved in memory into all requested output channels at once, gain applied, and handed to per-stem writer tasks (bounded by core count / disk throughput) that only write, never re-read. Progress reports back to the UI from that single pass`; the app stays responsive and export can run while the window is in the background.

**Distribution:** Developer ID, direct-download, signed and notarized — not sandboxed to the App Store, since it needs unrestricted access to arbitrary folders like NAS mounts. Even without a sandbox, macOS's TCC still prompts for Desktop/Documents/Downloads and some network volumes on first access, so the app still saves security-scoped bookmarks for the destination folder and any session folders it's opened, to avoid re-prompting on every launch.

## Mockups

Four screens, styled as native macOS windows (traffic lights, system font, light chrome, SF-style controls):

1. **Main window** — session info, template picker, the 32-track review table (with a linked stereo pair and an excluded track shown), and the trim scrubber with In/Out handles.
2. **Template editor** — the 32-row Track # / Name / Stereo link / Skip table used to build and edit a template, including the "Link as stereo pair" action.
3. **Export progress** — a lightweight window with an overall progress bar and a per-file checklist.
4. **Export summary** — completion state, file list, and a surfaced warning (e.g. a clipped channel) with Reveal in Finder / Done.
5. Settings — Appearance — the explicit Light / Dark / System control, with a side-by-side preview of both themes.

See the linked mockup artifact for the full-resolution screens.

## Assumptions & open questions

- **File naming pattern** is a first guess (`<Session Name> - <Track Name>.wav`); confirm the exact pattern you want, including whether track numbers should prefix the name for sorting (e.g. `03 - Piano.wav`).
- **Source format** confirmed: always 24-bit/48kHz BWF WAV, so export passes bit depth and sample rate through unchanged. The format picker added after v1 only changes the container and codec written out; BWF metadata rides along on the WAV path only.
- **Session grouping** superseded by folder-based import (see Combining multi-part sessions): the app now processes whatever WAV files sit in the folder you point it at, in filename order, no minimum or numbering pattern required — confirmed this covers the real-world case, per the `5D319CBD` example.
- **Distribution** confirmed: Developer ID, direct-download; minimum macOS 14 Sonoma; folder access persisted via security-scoped bookmarks so it doesn't re-prompt each launch; single session at a time, no session-history/reopen feature in v1.
- **Snap-to-silence** and **dated subfolder on export** are included as small quality-of-life defaults; say if either should be cut for v1 simplicity.
