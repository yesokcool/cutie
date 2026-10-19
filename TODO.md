# TODO.md — Cutie

## Verify on the Mac
> **In plain words:** these all involve real windows, drags or other apps, so
> the tests can't check them. Each needs one try by hand.

- [ ] Drag from Finder and from the Desktop; switch wheels mid-drag; tap the
      open wheel's key again to close it; drop on the center (cancels) and
      outside the wheel (Finder does its normal thing, the wheel closes).
- [ ] The same in a full-screen app and on a second display.
- [ ] A ⌘-drag in Finder that was already holding ⌘ must *not* open Tools.
- [ ] Drag a result pill out to Finder; click a pill to reveal; a pill stays
      while the pointer is on it.
- [ ] Float: shelf appears, drag files out, drop more in, X closes.
- [ ] ⌃⌥C with files selected in Finder; arrows/Return/Escape; focus returns
      to Finder after.
- [ ] Pages: DOCX → Pages, Pages → PDF. Keynote: PPTX → PDF, PPTX → PNG (a
      folder of slides). Numbers: XLS → XLSX.
- [ ] Trim a video and a song; AirDrop; Move; Terminal.
- [ ] Glass look in light and dark (snapshots only show a flat stand-in).

## Pro-grade pass
> **In plain words:** a fidelity audit (2026-10-19) ran the real engine on
> fixtures built to stress each case. Image conversion and native MOV↔MP4 are
> close to pro tools; documents, spreadsheets, PDF→office and the ffmpeg path
> are not, and some paths lose data without saying so. The goal is output a
> professional would trust. In order of impact:

- [ ] **Never report a broken result as done.** Images are done
      (`FileIntegrity`; the same box walk fits MP4/MOV). Fail when ffmpeg's output is much shorter
      than the input (`FFmpeg.swift:36-49`); show the useful stderr line, not
      the last (`Shell.swift:13`); drop the 5000-page cap
      (`PDFRenderer.swift:21`); render off the main thread.
- [ ] **Text encodings:** Windows-1252/1250/MacRoman CSV, SRT and TXT fail
      today (`DocumentReader.swift:62-66`). Detect with
      `NSString.stringEncoding(for:…)`.
- [ ] **Spreadsheets:** apply `styles.xml` number formats when reading XLSX
      (dates come out as serials, 8.25% as 0.0825; `XLSX.swift:62-72`); print
      numbers to 15 significant digits instead of turning them into text
      (`XMLText.swift:22-28`); detect the CSV delimiter (`Spreadsheet.swift:9`);
      stream sheets with `XMLParser` (a 14 MB XLSX peaked at 3.9 GB).
- [ ] **ffmpeg rewrite:** probe first and remux with `-c copy` when streams fit;
      keep every stream (`-map 0:v:0 -map 0:a? -map 0:s?`, `mov_text`),
      `-map_metadata 0 -map_chapters 0`; HDR to 10-bit HEVC (`hvc1`), never
      10-bit H.264 or 8-bit with PQ tags (`FFmpeg.swift:10-13`,
      `MediaTools.swift:25`); `aac_at`, bitrate per channel, 24-bit PCM when
      the source is, cover art kept; two-pass loudnorm with `-ar`
      (`MediaTools.swift:117-122`).
- [ ] **Keep video metadata** (capture date, GPS) on Compress/Mute/Rotate:
      copy `asset.metadata` (`MediaTools.swift:37-46,62-77`).
- [x] **Images** (2026-10-19): truncated files refused (`FileIntegrity`);
      lossless JPEG rotate/flip/strip; tools keep colour space and depth;
      gain maps kept in JPG/HEIC/AVIF, PQ tone-mapped for SDR; every frame of
      GIF/APNG/WebP animations; DPI and XMP carried over; lossless sources make
      lossless WebP.
- [x] **PDF** (2026-10-19): CropBox renders; JPEGs go into PDFs as JPEG;
      merge keeps title and a bookmark per file with its own bookmarks; split
      keeps title/author; OCR per page in reading order
      (`RecognizeDocumentsRequest`); Compress via Ghostscript or a Quartz
      filter, refusing when it can't shrink; new **Make Searchable** tool
      (invisible text layer, rotation, links and bookmarks kept).
- [ ] **Office documents:** route DOCX→PDF through Pages and XLSX→PDF through
      Numbers when installed (`Executor.swift:53,64`); LibreOffice
      (`soffice --headless`) and pandoc as detected helpers for real layout,
      formulas, PPTX without Keynote, and structured MD/DOCX/EPUB. In-house now:
      Markdown body at 16 pt (`HTML.swift:34`), absolute `file://` image paths
      in HTML (`Markdown.swift:48-49`), page size from the locale.
- [ ] **PDF → Word:** text only today. Build it from Vision document structure
      plus extracted images, or call it "PDF → Text".
- [ ] **Smaller:** scratch on the output's volume
      (`.itemReplacementDirectory`, `Scratch.swift:8`); 7z for passwords and
      multi-volume archives; translate subtitle tags, ASS, subtitles out of
      video.
- [ ] **Fidelity tests** from the audit's fixtures, so these stay fixed.

## Buildable now
- [ ] *Drags from apps that don't hand over a file path* (Photos, Mail
      attachments, images from Safari) use "file promises"; Cutie ignores them
      today. Accept `NSFilePromiseReceiver` in `WheelDropView` and receive into
      the scratch folder first.
- [ ] *Merge videos* (Tools, several videos): one after another, scaled to the
      first's size (ffmpeg concat filter, or AVMutableComposition + a video
      composition).
- [ ] *PDF → Excel*: tables out of PDFs. Needs real table detection; not
      offered until it's good.
- [ ] *Choose the Finder-selection shortcut* (fixed at ⌃⌥C today).
- [ ] *Open With / drop on the menu bar icon* as other ways to open the wheel.
- [ ] *Keyboard mode extras*: type a format's first letter to jump to it.

## Ideas, undecided
- [?] An App Store version (needs the sandbox: security-scoped access to the
      original's folder, a bundled encoder instead of Homebrew's ffmpeg).
