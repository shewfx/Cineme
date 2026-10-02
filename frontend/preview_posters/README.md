# Preview posters (local only)

Preview-only exception, see `docs/adr/002-preview-posters.md`.

Put poster images you are allowed to use here as `<tmdbId>.jpg`
(e.g. `104.jpg` for Run Lola Run; ids are in `lib/features/today/data/fake_today_repository.dart`).
They are read only by the `--dart-define=CINEME_PREVIEW=true` build. A missing file falls back
to the designed placeholder. Image files in this folder are git-ignored and must never be committed.
