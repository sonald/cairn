# M9 unlocked UI replay (2026-08-06)

Bundle: fresh `.build/m9-ui-app/Cairn.app`; corpus: tokio `be8ee45`;
file: `tokio/src/sync/mutex.rs`.

| Local time | Action | Observed result | Evidence |
|---|---|---|---|
| 08:54 | Reader live-scroll after an Outline navigation | Reader returned to file start; Outline had no selected row. This is the post-`didLiveScroll` follow state, rather than stale programmatic selection. | [dark-scroll-follow.jpeg](ui/dark-scroll-follow.jpeg) |
| 08:55 | Settings → Light | Files, Outline, Reader and Context use the light surface; exact footer remains truthful. | [light-reader.jpeg](ui/light-reader.jpeg) |
| 08:55 | Settings → SI Classic | All three surfaces share the SI Classic treatment. | [si-classic-reader.jpeg](ui/si-classic-reader.jpeg) |
| 08:56 | Outline → `Mutex` | Reader jumped to declaration at line 133; `Mutex` has native primary selection and occurrence emphasis. | [outline-mutex-selection.jpeg](ui/outline-mutex-selection.jpeg) |
| 08:57 | Escape | Reader native primary selection cleared while the outline row selection remained. | [escape-clears-reader-selection.jpeg](ui/escape-clears-reader-selection.jpeg) |

The live Relations pane exposes Callers, Calls, Implements, and References.
Its provider status was `Exact: deps unavailable (offline) · Safe`; consequently
there is no honest live relationship-row result to record for this run.

Limit: the desktop could not show a full 1600×1000 window. The pass for that
size is the existing real-`NSWindow` self-test; this replay supplies the
on-screen visual check at the available wide and compact sizes.
