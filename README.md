# Stem Exporter

A native macOS app that turns a folder of multichannel field-recorder WAVs into a
folder of named, trimmed, per-track stems — the weekly 10–15 minute DAW chore,
reduced to a couple of clicks.

> ⚠️ **Warning:** This project is vibe coded (built largely with AI assistance)
> and may be buggy. Use at your own risk, and back up your source recordings
> before exporting.

Built to [SPEC.md](SPEC.md)

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later (Swift 5.9+) to build

## Build and run

```bash
./Scripts/build-app.sh release
open build/StemExporter.app
```

### Running from Xcode

Open **`StemExporter.xcodeproj`** and run the **Stem Exporter** scheme. That
target builds a real `.app` — proper icon, menu bar, bundle identifier and TCC
identity — so a Run from Xcode behaves exactly like the shipped build. Source
files are picked up from `Sources/StemExporter` automatically (a synchronized
group), so adding a file needs no project edit, and `StemExporterKit` comes from
the local package and links statically.

Xcode also auto-generates schemes for the package itself — `StemExporter`,
`StemExporter-Package`, `StemExporterKit`. Those build the bare SwiftPM
executable, not a bundle. **Pick "Stem Exporter"** (with the space) for the app;
use `StemExporterKit` to run the tests in Xcode.

If you do run the bare executable (`swift run`, or one of the package schemes),
macOS files a loose binary as a *BackgroundOnly* process — no Dock icon, no menu
bar. The app detects it has no bundle and claims regular app status at launch so
it still works, but it has no bundle identifier, so TCC prompts and saved folder
permissions aren't shared with the bundled build.

```bash
swift test          # 59 tests over the audio engine, models and stores
```

### Try it without a recorder

```bash
swift Scripts/make-demo-session.swift ~/Desktop/DemoSession
open build/StemExporter.app --args --session ~/Desktop/DemoSession
```

The generator writes a two-part, 32-channel, 24-bit/48 kHz BWF session shaped like
a real one: silence at the head and tail, a stereo pair on 5+6, an unused input on
7, and a violin on track 2 hot enough that the template's +3 dB default clips it —
so the live clip warning and the export summary both have something to say.

You can also drag a session folder straight onto the window, or onto the app icon.

## How it fits together

```
Sources/
  StemExporterKit/          the engine — no UI, fully tested
    Audio/
      WAVFile            RIFF/RF64 chunk walker → byte offsets + PCM layout
      WAVWriter          streaming BWF writer, promotes itself to RF64 past 4 GB
      SampleCodec        raw little-endian PCM packing, gain, hard limiting
      SessionLoader      folder → ordered, validated, concatenated session
      SessionReader      random access over the session's virtual timeline
      PeakAnalyzer       the waveform cache, snap-to-silence, empty-track detection
      ExportPlanner      stems → filenames, collisions resolved
      ExportEngine       the single-pass streaming renderer
    Models/              Template, Session, StemPlan, ExportJob
    Store/               templates on disk, preferences, bookmarks, peak cache
  StemExporter/           the SwiftUI app
    AppModel             all app state; the only place the UI mutates a session
    SessionPlayer        mono-downmix audition for setting the trim by ear
    Views/               Main, TrackTable, TrimBar, TemplateEditor, Export*, Settings
    Theme/Palette        semantic colours, resolved per appearance
```

### The parts worth knowing about

**One read pass, not one per stem.** The 32 channels are interleaved in a single
file, so rendering each stem with its own read would mean pulling a multi-gigabyte
recording off disk thirty-odd times. `ExportEngine` reads the source once, in
8 MB blocks; every block is de-interleaved into all the requested output channels
at once (in parallel across stems), gain is applied in that same pass, and the
buffers go to per-stem writers that only ever write. Peak memory stays flat no
matter how long the session is.

The visible consequence: in the progress window every stem advances together
rather than a queue working down one file at a time. That's the architecture being
honest about what it's doing.

**No `AVAudioFile`.** The WAV structure is parsed by hand so the engine works from
exact byte offsets: trim is then just reading a different byte range, and multi-GB
files are never a problem. Chunks other than `fmt `, `data`, `bext` and `ds64` are
stepped over without being read, which is what keeps it working across recorder
firmware versions.

**Clipping is surfaced before you export.** Peaks are cached at unity gain, so
changing a track's dB rescales the cached envelope instantly and the waveform
redraws its clipped regions in red as you drag — no re-analysis. The export
summary is the final check, counting real clipped samples from the render itself.

**Waveform analysis is a preview pass, not a full decode.** `PeakAnalyzer` reads a
window out of each bucket and seeks over the rest, which keeps importing a 12 GB
session to a few seconds. The result is cached under `~/Library/Caches`, keyed on
the parts' paths, sizes and modification dates, so re-opening a folder is instant
and a changed folder is re-analysed.

**Templates are plain JSON**, one file per template under
`~/Library/Application Support/Stem Exporter/Templates`. The same format is what
Import/Export in the template editor reads and writes, so backing one up or moving
it to another Mac is a file copy.

## Keyboard

| | |
|---|---|
| `⌘O` | Add session folder |
| `⌘E` | Export all (asks where to write) |
| `Space` | Play / pause |
| `I` / `O` | Mark In / Out at the playhead |
| `⇧⌘S` | Snap to silence |

## Distribution

The app is unsandboxed by design — it needs to reach NAS mounts and arbitrary
folders. `Scripts/build-app.sh` signs ad hoc, which is fine locally. For a
direct-download build:

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <your identity>" build/StemExporter.app
ditto -c -k --keepParent build/StemExporter.app build/StemExporter.zip
xcrun notarytool submit build/StemExporter.zip --keychain-profile <profile> --wait
xcrun stapler staple build/StemExporter.app
```

Even unsandboxed, macOS gates Desktop/Documents/Downloads and some network volumes
behind TCC, so the app keeps security-scoped bookmarks for the destination and
session folders rather than re-prompting each launch.

## Notes against the spec

- **Snap-to-silence** and the **dated export subfolder** are both in, as the spec
  suggested; the silence threshold is adjustable in Settings › General, and the
  dated subfolder is off by default in Settings › Export Defaults.
- **Empty inputs arrive already skipped.** The import pass flags any track whose
  loudest sample never reaches -60 dBFS — a patched but unused channel — and ticks
  its Skip box, marking the row "empty". The tick is a starting point: untick a row
  and it stays unticked, "Include Them" in the footer puts them all back, and the
  whole behaviour (and its threshold) is in Settings › General. A stereo pair needs
  both sides empty before it counts.
- **File naming** defaults to `<Session> - <NN> - <Name>.wav`, zero-padded so
  Finder sorts stems in input order. The pattern is editable in Settings with
  `{session}`, `{track}` and `{name}` tokens.
- **Track count is never assumed.** It comes from the file. A template built for a
  different count still opens the session: slots pointing past the last channel are
  dropped with a message, and anything uncovered falls back to "Track N".
- **Playback** for setting the trim by ear is a mono downmix streamed from the
  source, not 32 live channels through an engine.
