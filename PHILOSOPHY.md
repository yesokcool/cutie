# PHILOSOPHY.md — what Cutie is for

**A file converter you never open.** The common action — turn this file into
that one — happens in the middle of a drag you were already doing: tap a key,
drop, done. No window, no upload page, no "choose output format" dialog.
That's the whole point, so it settles most design calls: if a feature needs
a window, it had better be rare (Trim) or optional (Settings).

## What it holds to
- **Files stay on this Mac.** No network code at all. Helpers (ffmpeg, cwebp,
  Pages/Keynote/Numbers) are local programs.
- **Originals are sacred.** Cutie only ever adds files next to them, under a
  fresh name. A half-finished job leaves nothing behind.
- **Fewest clicks.** One gesture per job. Results appear where the file was
  dropped and can be dragged straight on to the next place.
- **Calm.** The wheel appears only when asked for (a key tapped mid-drag), and
  pills fade on their own. No badges, notifications, counters or nags.
- **Honest about limits.** A slice that needs a missing helper isn't shown;
  a failure says what went wrong in plain words.

## What it won't become
- A cloud converter, an account, or anything that phones home.
- A batch-job manager with queues and presets. One drag, one result.
- An editor. Trim uses QuickTime's own bar; anything needing more belongs in
  a real app.
