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
- **ImageIO says a truncated JPEG is complete.** `CGImageSourceGetStatusAtIndex`
  returns `.statusComplete` for a half file and decoding fills the rest with
  grey. `FileIntegrity` walks the container instead (JPEG segments to EOI, PNG
  chunks to IEND, ISO boxes, RIFF size) — verified 2026-10-19.
- **Lossless JPEG edits:** `CGImageDestinationCopyImageSource` rotates/flips by
  rewriting only the orientation tag (pixels byte-identical, profile and GPS
  kept). `kCGImageDestinationOrientation` can't be combined with
  `kCGImageDestinationMetadata` (error "cannot be used with"), so stripping
  puts the orientation *inside* the replacement metadata. HEIC refuses the copy
  ("modifyHEIC failed"), so HEIC tools re-encode.
- **HDR:** `kCGImageSourceDecodeToHDR` + `kCGImageDestinationEncodeToISOGainmap`
  keeps a gain map in JPG, HEIC and AVIF (PNG/TIFF refuse it). For SDR targets,
  tone-map at *decode* (`kCGImageSourceDecodeToSDR`):
  `kCGImageDestinationEncodeToSDR` on a PQ image still writes PQ-tagged pixels.
- **A JPEG drawn into a PDF context stays JPEG** (`/DCTDecode`, no
  re-compression) when the CGImage comes straight from
  `CGImageSourceCreateImageAtIndex`; a decoded/cached copy (the old thumbnail
  path) is written as Flate, 6× bigger.
- **PDFKit (macOS 27) drops a new outline on a document opened from a file**:
  `outlineRoot = …` then `write` saves no bookmarks. A `PDFDocument()` built in
  memory keeps them, so `PDFConverter.rebuilt` copies the pages into one first.
  A Quartz filter on `write` also drops bookmarks (they're put back the same way).
- **`PDFPage.draw(with:to:)` and `transform(for:)`** include the box offset and
  rotation; Make Searchable inverts that transform to map Live Text's boxes
  (read from the upright render) back onto the unrotated page.

### Media (2026-10-19)
- **ffmpeg's `-movflags use_metadata_tags`** writes keys AVFoundation reads as
  `itsk/%00%00%00%01`, so Photos sees no location. Results from an
  iPhone-style source are re-saved through an AVFoundation passthrough with
  `session.metadata` (→ `loci`/`date` in MP4, `mdta` kept in MOV). That
  passthrough drops chapter text tracks, so it's skipped when there are
  chapters. `use_metadata_tags` also makes the mov muxer drop cover art
  (`covr`), so it's off when there's a cover.
- **Homebrew's ffmpeg has no zscale or libplacebo**, so it can't tone-map HDR;
  `AVVideoComposition.Configuration` with Rec. 709 colour does it instead.
- **libopus rejects the 5.1(side) layout**: `aformat` plus `-mapping_family 1`.
- **loudnorm reports only on stderr**; `FFmpeg.runCapturingLog` captures it
  through `sh -c 'exec "$0" "$@" 2>&1'`.
- **`-display_rotation:v:0` is an input option** and uses ffprobe's sign
  (−90 means clockwise).
- **An ffmpeg-written test MOV isn't iPhone-like**: tests write camera keys
  through AVFoundation.

### Documents and spreadsheets (2026-10-19)
- **Cocoa's HTML import reads 1 CSS px as 1 pt** (default text 12) and its
  export writes pt as px, hence `HTML.rewritingCSSLengths` (style regions only).
- **soffice exits 0 even when it couldn't load a file**: the output file is
  the only proof. Its CSV export needs filter option 9 = true ("as shown"),
  or currency comes out raw.
- **pandoc's DOCX reader nests media as `media/media/…`** and turns sized
  images into `<img>`; a Lua filter and flattening keep Markdown clean.
- **`NSAttributedString` can't cross into a `@concurrent` function**, even as
  a fresh copy (region rules), so `PDFRenderer` archives it first.
- **A `DateFormatter` per cell made a 1M-cell XLSX take 48 s and 1.1 GB.**
  Compile each format code once per style; cache month names.
- **UTF-16 without a BOM is valid UTF-8** (its zero bytes are legal), so it's
  checked first. Windows-1252 vs Mac Roman: Mac Roman's high half is mostly
  letters, so a capital mid-word counts against it (`TextDecoding.plausibility`).
- **Raw strings containing `"#`** (`"#FF0000"`, `"$"#,##0`) need `##"…"##`.

### PDF → Word (2026-10-19)
- **`PDFPage.characterBounds(at:)` drifts by one after every line break and
  ligature**; use `page.selection(for: NSRange(i, 1))?.bounds(for:)`.
- **PDFKit's text loses bold, italic and font names for fonts that aren't
  installed** (falls back to Times); `PDFContent` reads them from the content
  stream.
- **PDFKit can list a line's pieces out of order** ("Page of 1 10"); sort by
  x, except in right-to-left scripts.

### Archives and robustness (2026-10-19)
- **bsdtar asks for a ZIP password on the terminal and hangs**: always pass
  `--passphrase`, and `-p<dummy>` to 7-Zip. bsdtar reports a split 7z as
  "tar: (null)".
- **`ditto -c -k` ZIPs have no UTF-8 flag** (Windows shows garbled names) and
  add `__MACOSX`; bsdtar ZIPs are clean but drop xattrs. `ditto -x -k`
  restores Finder tags on extraction.
- **`volumeAvailableCapacityForImportantUsage` is 0 on non-boot disks**; fall
  back to `volumeAvailableCapacity`. Tests stand in for an external drive with
  an `hdiutil create` / `attach -nobrowse` disk image.
