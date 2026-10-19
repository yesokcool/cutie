# PATTERNS.md — how Cutie does things, and what bit us

## Techniques

### Noticing a file drag anywhere, without permissions (`DragMonitor`)
Keyboard event taps and global *key* monitors need Accessibility / Input
Monitoring. Cutie needs neither:
1. A global **mouse-down** monitor (mouse monitors need no permission) starts a
   60 Hz timer that runs only while the button is held.
2. Each tick reads `NSPasteboard(name: .drag).changeCount`. When it moves, some
   app started a drag; if the pasteboard holds file URLs, those are the files.
3. `NSEvent.modifierFlags` (class property) is the live modifier state. A wheel
   opens on a key that went down *after* the drag was detected, so a drag that
   began with ⌘ held doesn't count.
4. When the button comes up, the timer stops and an open wheel closes ~0.3 s
   later unless the drop landed on it.
A local monitor does the same for drags starting in Cutie's own panels.

### A drop target that appears mid-drag (`WheelPanel` / `WheelDropView`)
Borderless, clear, `.nonactivatingPanel`, level `.popUpMenu`,
`[.canJoinAllSpaces, .fullScreenAuxiliary]`. It never activates Cutie, so the
drag in progress (owned by Finder) carries on and simply finds a new
destination under the pointer. `WheelDropView` overrides `hitTest` to return
itself, so SwiftUI only draws; every drag/mouse/key event is handled in AppKit
and pushed into `WheelModel`. Return `.copy`/`.generic`/`.link` from
`draggingUpdated` — ⌘ during a drag restricts the source to `.generic`, ⌃ to
`.link` — and never `.move`.

### Results you can drag on (`FileDragView`)
An NSView hosting the SwiftUI pill that starts its own `NSDraggingSession` of
file URLs, with a `passThrough` rect (the X) where clicks go to SwiftUI. The
source mask outside the app is copy+move+generic+link, so Finder behaves as if
the drag came from Finder (move on the same disk, copy across disks).

### Every job: scratch first, then place (`Executor`, `Output`, `Scratch`)
Converters write into a per-job temp folder; `Output.place` moves the finished
file (or folder) beside the original under a Finder-style unique name. A crash
or cancel leaves nothing half-written next to the user's files.

### Seeing the UI without opening it
`SnapshotTests` render views in a never-shown window with `cacheDisplay`
(AppKit controls draw too; `ImageRenderer` would leave them blank). Liquid
Glass needs a live window behind it, so `\.isSnapshot` swaps `cutieGlass` for
a flat fill of the same shape. Run with `TEST_RUNNER_CUTIE_SNAPSHOTS=<folder>`.

### Icon Composer glyphs need their own 1024 canvas
An SVG layer is placed at its own point size, so Phosphor's 256-unit glyph came
out a quarter of the icon. Wrap the path in a 1024×1024 SVG with
`translate(…) scale(2.6)` (Budget's wallet does the same).

## Gotchas & lessons

- **Relative XPath on an `XMLElement` leaks into later siblings.**
  `isElement.nodes(forXPath: ".//*[local-name()='t']")` on the *last* cell of a
  row returned that cell's text **plus every later cell's**, so CSV → XLSX → CSV
  glued rows together. Verified with a 3-cell document (2026-10-18). Walk
  `children` by hand (`XLSX.text(of:)`, `ODS.tableRows(in:)`); document-level
  XPath (`//…` on the `XMLDocument`) is fine.
- **`case .a, .b where condition:` guards only `.b`.** `.mp4` matched even for
  non-native video in a first draft of `MediaConverter`; it's an if chain now.
- **Cocoa's DOCX writer drops hyperlinks**, and DOCX read back gives list
  bullets as plain text (`"\t•\t"`) with no `NSTextList`. `Markdown.markdown`
  recognises those text bullets; links can't survive DOCX.
- **ImageIO reads WebP but can't write it** (macOS 27), and Homebrew's ffmpeg
  has no libwebp encoder, hence `cwebp`.
- **AVAudioFile writes FLAC** (`kAudioFormatFLAC`, `.flac`) and reads Ogg Opus
  on macOS 26+; AVFoundation can't open MKV/WebM/AVI at all.
- **JPG/BMP have no alpha**: ImageIO turns transparent pixels black, so
  `ImageConverter.flattened` puts them on white first.
- **Phone photos are stored sideways** with an EXIF orientation; loading through
  `CGImageSourceCreateThumbnailAtIndex(…WithTransform…)` at full size bakes it
  in, then the written orientation tag is reset to 1.
- **`PDFPage.draw(with:to:)` applies the page's rotation** (tested), so a
  rotated page renders landscape without extra transforms.
- **Live Text's first run takes ~20 s** while the model loads (tests included).
