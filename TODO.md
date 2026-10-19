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
> **In plain words:** a fidelity audit (2026-10-19) found that documents,
> spreadsheets, PDF → office and the ffmpeg path weren't good enough for
> professionals, and some paths lost data silently. All of it was rebuilt the
> same day, with fidelity tests for each point. What's left:

- [x] **Images**, **PDF**, **video and audio**, **spreadsheets**, **text
      encodings**, **subtitles**, **office documents** (LibreOffice, pandoc),
      **PDF → Word / Excel**, **robustness** (plain errors, scratch on the
      result's disk, password and split archives, cut-off files refused,
      cancelled batches leave nothing) — 2026-10-19, see the decision log.
- [ ] **PDF → Word, next:** multi-column pages (come out as one column),
      footnotes (become paragraphs), text boxes and sidebars (inline). Route
      PDF → RTF/HTML/EPUB/Markdown through the same model (still text only).
- [ ] **Picture subtitles** (DVD/Blu-ray) to text needs OCR of each cue.
- [ ] **HDR → SDR video** goes through a ProRes 422 intermediate: large for
      long 4K clips. A streaming tone-map would avoid it.
- [ ] **LibreOffice runs with a fresh profile per job** (safe, a few seconds
      slower). A cached profile with a lock would be faster.
- [ ] **Password entry** for encrypted archives (they're reported, not opened).

## Verify on the Mac (pro-grade pass)
- [ ] Pages DOCX → PDF and Numbers XLSX → PDF with LibreOffice *not*
      installed (Cutie falls back to them; untested because they open on screen).
- [ ] Open a PDF → Word result in Microsoft Word and in Pages.
- [ ] LibreOffice conversions never show a Dock icon or window.
- [ ] An iPhone video after Compress/Mute/Rotate still shows its place in Photos.

## Buildable now
- [ ] *Drags from apps that don't hand over a file path* (Photos, Mail
      attachments, images from Safari) use "file promises"; Cutie ignores them
      today. Accept `NSFilePromiseReceiver` in `WheelDropView` and receive into
      the scratch folder first.
- [ ] *Merge videos* (Tools, several videos): one after another, scaled to the
      first's size (ffmpeg concat filter, or AVMutableComposition + a video
      composition).
- [ ] *Choose the Finder-selection shortcut* (fixed at ⌃⌥C today).
- [ ] *Open With / drop on the menu bar icon* as other ways to open the wheel.
- [ ] *Keyboard mode extras*: type a format's first letter to jump to it.

## Ideas, undecided
- [?] An App Store version (needs the sandbox: security-scoped access to the
      original's folder, a bundled encoder instead of Homebrew's ffmpeg).
