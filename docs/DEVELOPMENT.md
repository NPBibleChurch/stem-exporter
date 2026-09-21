# Development Guide

Everything needed to build, test, understand and ship Stem Exporter. For using
the app, see the [user guide](USER-GUIDE.md); for what it was built to do, see
[SPEC.md](../SPEC.md).

**Contents**

1. [Getting set up](#1-getting-set-up)
2. [Building from Xcode](#2-building-from-xcode)
3. [Tests](#3-tests)
4. [A session to develop against](#4-a-session-to-develop-against)
5. [Source layout](#5-source-layout)
6. [The parts worth knowing about](#6-the-parts-worth-knowing-about)
7. [Regenerating the screenshots](#7-regenerating-the-screenshots)
8. [Releasing](#8-releasing)

---

## 1. Getting set up

Requires macOS 14 (Sonoma) or later and Xcode 15+ (Swift 5.9+).

```bash
./Scripts/build-app.sh release
open build/StemExporter.app
```

`build-app.sh` takes `debug` or `release` (default `release`). SwiftPM only
produces a bare executable; the script wraps it in the `.app` bundle that gives
the app a menu bar, a Dock icon and a TCC identity. Debug builds stay thin for
quick iteration; release builds go universal (arm64 + x86_64).

Environment variables it honours:

| Variable | Default | Purpose |
|---|---|---|
| `BUNDLE_ID` | `com.npbiblechurch.StemExporter` | Bundle identifier — also the TCC identity and preferences domain |
| `MARKETING_VERSION` | `1.0` | `CFBundleShortVersionString` |
| `BUILD_VERSION` | `1` | `CFBundleVersion` |

---

## 2. Building from Xcode

Open `StemExporter.xcodeproj` and pick the **Stem Exporter** scheme — the one
with a space in the name. It builds a real `.app` (icon, menu bar, bundle
identifier, TCC identity), so a Run from Xcode behaves exactly like the shipped
build. `Sources/StemExporter` is a synchronized group, so adding a file needs no
project edit, and `StemExporterKit` comes from the local package and links
statically.

Xcode also auto-generates schemes for the package itself — `StemExporter`,
`StemExporter-Package`, `StemExporterKit`. Those build the bare SwiftPM
executable, not a bundle. Use `StemExporterKit` to run tests; otherwise prefer
the app scheme.

**Why the bare executable misbehaves.** Run it via `swift run` or a package
scheme and macOS files a loose binary as a *BackgroundOnly* process — no Dock
icon, no menu bar. `AppDelegate.adoptAppIdentityIfUnbundled()` detects the
missing bundle and claims regular app status at launch so it still works, but
there's no bundle identifier, so TCC prompts and saved folder bookmarks aren't
shared with the bundled build. Expect to re-grant folder access.

---

## 3. Tests

```bash
swift test          # 59 tests over the audio engine, models and stores
```

The tests cover `StemExporterKit` — the engine has no UI dependencies, which is
the point of the split. There are no UI tests; the screenshot renderer in
[section 7](#7-regenerating-the-screenshots) is the closest thing to a layout
check.

---

## 4. A session to develop against

You don't need a recorder. The generator writes a synthetic session shaped like a
real one:

```bash
swift Scripts/make-demo-session.swift ~/Desktop/DemoSession
open build/StemExporter.app --args --session ~/Desktop/DemoSession
```

Two parts, 32 channels, 24-bit/48 kHz BWF, with silence at the head and tail, a
stereo pair on 5+6, an unused input on 7, and a violin on track 2 hot enough that
the template's +3 dB default clips it — so the live clip warning and the export
summary both have something to say.

`--session <folder>` opens a folder straight away, which makes it possible to
launch into a known state when checking the UI.

---

## 5. Source layout

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
    PreviewRenderer      DEBUG-only offscreen screenshot renderer
    Views/               Main, TrackTable, TrimBar, TemplateEditor, Export*, Settings
    Theme/Palette        semantic colours, resolved per appearance
```

`AppModel` is the single place the UI mutates a session — views bind to it, never
to each other. Keep it that way.

---

## 6. The parts worth knowing about

**One read pass, not one per stem.** Rendering each stem with its own read would
pull a multi-gigabyte recording off disk thirty-odd times. `ExportEngine` reads
the source once in 8 MB blocks, de-interleaving each block into every requested
output channel at once and applying gain in the same pass. Peak memory stays flat
however long the session is — and in the progress window every stem advances
together rather than a queue working down one file at a time. That's the
architecture being honest about what it's doing.

**No `AVAudioFile`.** The WAV structure is parsed by hand, so the engine works
from exact byte offsets: trim becomes a different byte range, and multi-GB files
are never a problem. Chunks other than `fmt `, `data`, `bext` and `ds64` are
stepped over unread, which keeps it working across recorder firmware versions.
Track count comes from the file and is never assumed — a template built for a
different count still opens the session, dropping slots that point past the last
channel.

**Clipping is surfaced before you export.** Peaks are cached at unity gain, so
changing a track's dB rescales the cached envelope instantly — the waveform
redraws its clipped regions in red as you drag, with no re-analysis. The export
summary is the final check, counting real clipped samples from the render.

**Waveform analysis is a preview pass, not a full decode.** `PeakAnalyzer` reads
a window out of each bucket and seeks over the rest, keeping a 12 GB import to a
few seconds. Results are cached under `~/Library/Caches`, keyed on the parts'
paths, sizes and modification dates, so re-opening a folder is instant and a
changed folder is re-analysed.

**Templates are plain JSON**, one file each under
`~/Library/Application Support/Stem Exporter/Templates` — the same format the
editor's Import/Export reads and writes, so moving one to another Mac is a copy.
Handy when debugging: edit the file, reopen the app.

**The app is unsandboxed by design** — it needs to reach NAS mounts and arbitrary
folders. macOS still gates Desktop/Documents/Downloads and some network volumes
behind TCC, so the app keeps security-scoped bookmarks for the session and
destination folders rather than re-prompting each launch.

---

## 7. Regenerating the screenshots

The screenshots in the user guide are rendered by the app itself, from real
hosted views rather than mockups. `PreviewRenderer` is DEBUG-only and isn't
compiled into a release build.

```bash
swift build -c debug
swift Scripts/make-demo-session.swift /tmp/DemoSession
./.build/debug/StemExporter --render-previews docs/screenshots --session /tmp/DemoSession
```

That writes light and dark variants of the main window, template editor,
settings, export progress and export summary into `docs/screenshots/`.

Two things to know:

- It renders through a real hosted `NSWindow` rather than `ImageRenderer`, which
  draws the SwiftUI tree in isolation and leaves scroll views empty and
  AppKit-backed controls as placeholders. Hosting offscreen captures what the app
  actually draws.
- It captures the window's **content view**, so the toolbar isn't included. If a
  screenshot needs the toolbar, take it by hand.

The export progress and summary shots are rendered from posed models
(`exportingModel` / `finishedModel` in `PreviewRenderer.swift`) — no export
actually runs. Adjust those if the sheets gain new states worth showing.

---

## 8. Releasing

Pushing a `v*` tag builds an ad-hoc-signed, universal app and publishes it as a
zip to [Releases](https://github.com/NPBibleChurch/stem-exporter/releases) — see
[`.github/workflows/release.yml`](../.github/workflows/release.yml). No
repository secrets are needed.

The app isn't signed with a Developer ID or notarised, so Gatekeeper blocks the
first launch. Downloaders need to right-click the app and choose **Open** (or
System Settings → Privacy & Security → **Open Anyway**) once.

To do it by hand:

```bash
MARKETING_VERSION=1.2.3 BUILD_VERSION=42 ./Scripts/build-app.sh release
ditto -c -k --sequesterRsrc --keepParent build/StemExporter.app build/StemExporter.zip
```
