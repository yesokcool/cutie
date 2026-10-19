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
