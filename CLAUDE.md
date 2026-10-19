# Cutie — Claude Project Notes

A menu bar file converter for the Mac: drag any file, tap a modifier key, and
drop it on a wheel of choices. ⇧ opens **Convert** (format changes), ⌘ **Tools**
(compress, trim, split, merge…), ⌃ **Actions** (AirDrop, Float, Copy, Move,
Copy Path, Terminal). Everything runs on the Mac; nothing is uploaded.
**Not on the App Store, not sandboxed.** Open source (MIT); `README.md` is the
user-facing overview.

**If `private/README.md` exists, read it first:** the maintainer's own notes
(their install, to-dos, history). `private/` is gitignored and never published.

macOS 26.0+, Swift 6, default-MainActor isolation, file-system-synchronized
groups, no packages. An agent app (`LSUIElement`: menu bar icon, no Dock icon).
The team and bundle id come from `Config/Cutie.xcconfig` (neutral defaults,
`com.example.cutie`) plus the gitignored `Config/Local.xcconfig`; the Dev
configuration adds `.dev` ("Cutie Dev", grey-orange icon).

**Read first:** `PHILOSOPHY.md` (what it's for, what it won't become) ·
`TODO.md` (manual checks, what's next) · `PATTERNS.md` (how the drag
detection works, and every gotcha so far).

## Architecture
- **Engine/** (pure, `nonisolated`, tested): `FileKind` (what a file is, by
  extension), `Format` / `Tool` / `FileAction` (the slices), `Catalog` (which
  slices each wheel shows for these files and this Mac's helpers), `Executor`
  (runs a Convert or Tools slice, `@concurrent`), `Output` + `Scratch` (where
  results go; `Scratch(near:)` sits on the result's disk, `Output.place` stages
  cross-disk copies under a hidden name), `Shell` (runs ffmpeg / bsdtar / zip /
  osascript; `Failure.explain` turns stderr into plain words), `Toolbox`
  (which helpers are installed), `FileIntegrity` (spots cut-off files by their
  container structure), `Preferences` (every UserDefaults key).
- **Converters/**: `ImageConverter` (ImageIO; keeps colour space, depth,
  HDR gain maps, metadata, animation; lossless JPEG edits), `MediaConverter` (AVFoundation
  first, `FFmpeg` otherwise: ffprobe first, then a per-stream plan that copies
  what fits), `MediaChecks` (cut-off inputs, too-short results), `Office`
  (routes office files to LibreOffice / pandoc / Pages / Numbers, best first),
  `DocumentReader` / `DocumentWriter` (Cocoa text
  system; main actor because HTML import uses WebKit), `Markdown` (Foundation's
  CommonMark parser → HTML; attributed string → Markdown), `HTML`, `EPUB`,
  `PDFRenderer` (off the main thread, region paper), `PDFConverter` (crop-box renders,
  Ghostscript/Quartz compression, bookmark-keeping merge, Make Searchable),
  `PDFContent` + `PDFPageLayout` + `PDFToWord` + `WordDocument` (PDF → Word/Excel:
  the content stream for fonts/images/lines, PDFKit for characters, Vision for
  tables and scans, hand-written WordprocessingML), `PowerPoint` (PDF → PPTX by
  hand), `Spreadsheet` + `Workbook` (typed cells: shown text, value, kind, format
  code; merges) + `CSV` / `XLSX` / `ODS` (written and read directly, streamed) +
  `NumberFormat` (Excel format codes, `SpreadsheetDate`), `TextDecoding` (any
  text encoding), `Subtitles` (SRT/VTT/ASS through one neutral form),
  `ArchiveConverter` (bsdtar, `ditto` for ZIP extraction, 7-Zip for split
  archives) + `ZipDirectory` (encryption/spanning/sizes from the central
  directory), `IWork` (Pages/Keynote/Numbers via AppleScript).
- **Tools/**: `ImageTools` (format-preserving pixel tools, Vision background
  removal, Live Text via `RecognizeDocumentsRequest` for reading order),
  `MediaTools` (metadata-keeping AVFoundation paths, two-pass loudnorm, Get
  Subtitles).
- **Wheel/**: `DragMonitor` (notices file drags + key taps), `WheelController`
  (opens/switches/closes), `WheelPanel` + `WheelDropView` (the see-through,
  non-activating drop target; all events stop there), `WheelView` & parts
  (SwiftUI, draw only), `WheelGeometry` (pure ring math, tested), `WheelModel`.
- **Panels/**: `JobCenter` + `JobPillView` (a pill per job at the drop point;
  drag the result out, click to reveal), `FileDragView` (AppKit drag source
  hosting SwiftUI), `FloatController` (Float shelves), `TrimController`
  (QuickTime's trim bar in a window).
- **Actions/** `ActionRunner` · **App/** `CutieApp` (MenuBarExtra, Settings,
  Welcome window), `CutieCore` (the running app), `FinderHotKey` (⌃⌥C),
  `AppIdentity` · **Settings/** `SettingsView`, `WelcomeView`.

## Guardrails
- **Never touch an original.** Every job writes into its `Scratch` folder and
  only moves finished files out through `Output.place` (Finder-style
  "name 2.ext"). Results go beside the original, or to Downloads when that
  folder is read-only or the setting says so.
- **No Accessibility / Input Monitoring permission.** Drag detection is a
  global mouse-down monitor + polling the drag pasteboard and
  `NSEvent.modifierFlags` (PATTERNS.md). Don't add a keyboard event tap.
- **The wheel never answers `.move` to a drop** (the source must keep its files).
- **Helpers are detected, never bundled** (ffmpeg, cwebp from Homebrew; Pages,
  Keynote, Numbers). A slice that needs a missing helper isn't shown.
- **Don't use relative XPath (`.//x`) on an `XMLElement`**: Foundation's engine
  leaks into following siblings. Walk children by hand (PATTERNS.md).
- **A `where` on a multi-pattern `case` guards only the last pattern** — use an
  if chain (bit `MediaConverter` once).
- Don't write copy in the maintainer's voice (taglines, About text): leave a
  placeholder.
- **Never let a helper prompt on a terminal.** bsdtar waits forever for a ZIP
  password unless given `--passphrase`; 7-Zip needs a dummy `-p`; soffice runs
  `--headless` with a throwaway profile. Helpers must never show UI either.
- **Fidelity is tested, not assumed.** A change to a converter needs a test
  that checks the *content* of the result (colour, depth, streams, cell types,
  structure), not just that a file appeared.
- **This repo is public.** Nothing personal in tracked files: no names, emails,
  team IDs, real bundle ids or home-folder paths. Those go in
  `Config/Local.xcconfig` or `private/`.
- The Dev and real builds both watch drags; don't run both at once.

### Persisted surfaces
UserDefaults only (`Preferences.Key`): `convertKey`, `toolsKey`, `actionsKey`
(TriggerKey raw values), `saveLocation`, `imageQuality`, `paused`,
`hasSeenWelcome`, `lastMoveFolder`, `finderShortcut`. Settings binds the same
keys with `@AppStorage`. Never rename a key (it silently resets the setting).

### Manual testing required (unit tests don't cover these)
- The drag itself: from Finder and the Desktop, tap ⇧/⌘/⌃, switch wheels
  mid-drag, tap the same key to close, drop on a slice / the center / elsewhere,
  in a full-screen app, on a second display.
- Dragging a result pill and a Float out to Finder (same disk moves, other disk
  copies), click-to-reveal, pills fading only when the pointer leaves.
- ⌃⌥C with a Finder selection (first use asks to control Finder) and Menu ▸
  Convert Files…; arrows/Return/Escape/clicks in keyboard mode; focus going
  back to Finder afterwards.
- Pages/Keynote/Numbers conversions (first use asks to control each app;
  Keynote's JPG/PNG export makes a folder).
- Trim (AVPlayerView's trim bar), AirDrop, Move's folder picker, Terminal.
- Open at login (SMAppService) and the glass look in light and dark.

## Decision log
- **2026-10-19** Pro-grade pass (TODO.md), the maintainer: "it needs to be THAT good
  and THAT solid". Nothing about a file changes unless the tool is about that
  thing, and a damaged input is refused, never "converted". Fidelity suites
  (`Image`, `PDF`, `Media`, `Document`, `Spreadsheet`, `SubtitleAndText`,
  `PDFToWord`, `Robustness`) hold the line.
- **2026-10-19** LibreOffice and pandoc are optional, detected helpers
  (the maintainer approved), with the best tool first: LibreOffice for layout, then
  Pages/Numbers, then built-in; pandoc for structure.
- **2026-10-19** Media: copy whatever fits the target, re-encode only the
  rest. Lossless audio in MP4 becomes ALAC; "M4A" means AAC (Apple's `aac_at`).
- **2026-10-19** Spreadsheet cells carry their shown text plus a typed value;
  CSV is written as Excel writes it (CRLF, UTF-8 BOM only when not ASCII).
- **2026-10-19** PDF → Word built in-house (content stream + PDFKit +
  Vision), no helper: LibreOffice's PDF import makes drawing frames, not text.
- **2026-10-19** Open source under MIT, with signing values moved out of the
  project file into xcconfigs so a fresh clone builds without a team.
- **2026-10-18** Unsandboxed app instead of App Store-ready: it must
  write next to any file, run Homebrew's ffmpeg and drive iWork apps. An App
  Store version would need a sandbox rethink (security-scoped folder access, a
  bundled encoder).
- **2026-10-18** Native frameworks first, helpers only for the rest: ImageIO,
  AVFoundation, Vision, PDFKit, the Cocoa text system and bsdtar cover most
  formats; ffmpeg adds MP3/OGG/Opus/WMA/MKV/WebM/AVI/WMV; cwebp adds
  WebP output (ImageIO reads WebP but can't write it).
- **2026-10-18** XLSX, ODS, EPUB and PPTX are written (and XLSX/ODS/EPUB read)
  by Cutie itself as zipped XML, so they work without Office or iWork.
- **2026-10-18** Drops pick a slice by direction (pie menu): anywhere past the
  center hole counts, the center cancels.
- **2026-10-18** Icon: Phosphor's orange (MIT, see `CREDITS.md`) on an orange
  gradient as an Icon Composer file; the Dev icon fades from grey.

## Build / run / test
```sh
# build (agent/CLI builds use their own DerivedData)
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project cutie.xcodeproj -scheme cutie -derivedDataPath /tmp/cutie-dd build
# tests (engine end-to-end on real files, catalog, wheel geometry)
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project cutie.xcodeproj -scheme cutie -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/cutie-dd test
# UI snapshots to a folder (glass drawn as a flat stand-in; nothing opens on screen)
TEST_RUNNER_CUTIE_SNAPSHOTS=/tmp/cutie-snaps …same test command… -only-testing:cutieTests/SnapshotTests
# install the Release build to /Applications (quits a running copy first)
Tools/install-mac.sh
# a downloadable release: archive, Developer ID, Apple notarization, zip (prints its path)
Tools/release-mac.sh
```
Smoke-launching without the welcome window: `open -g -n <Cutie.app> --args -hasSeenWelcome YES`.

## Docs map
`README.md` · `PHILOSOPHY.md` · `TODO.md` (+ `DONE.md` once items ship) ·
`PATTERNS.md` · `CREDITS.md` · `LICENSE` · `private/README.md` (if present).
