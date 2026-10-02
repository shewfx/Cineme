# ADR 002 — Local preview posters

Status: accepted by the project owner, 2026-10-02.

## Decision

The P1 UI-preview build (`--dart-define=CINEME_PREVIEW=true`) may display real poster images that the developer supplies locally in `frontend/preview_posters/<tmdbId>.jpg`. Image files in that folder are git-ignored; only its README is committed. Normal builds never read the folder. A missing file falls back to the designed placeholder at the same size.

## Why

The P1 visual direction is imagery-led (artwork fading into charcoal). Geometric placeholders alone cannot show whether that composition works with real artwork, and TMDB poster URLs belong to P3/P4, not P1.

## Tradeoff

Narrow exception to FRONTEND_SPEC "No movie-poster binaries bundled in source. UI fixture posters use local geometric placeholders": posters stay out of the repository (PROJECT_SPEC "Do not publish third-party poster files inside the repository" still holds) but can be packaged into a developer's local preview APK. The developer is responsible for having the right to use any image they place there. Preview APKs containing them must not be distributed.

## Affected contracts

FRONTEND_SPEC accessibility/assets note. No API, data model or scorer change. When real `poster_url` values arrive (P3/P4), `MoviePoster` loads them from the TMDB CDN and this folder remains preview-only.

## Validation

`git check-ignore` confirms `frontend/preview_posters/*.jpg` is ignored. The widget test suite runs without the folder's images (placeholder path). Manual: on the emulator, a local `104.jpg` (a generated synthetic test image, deleted afterwards) appeared as Run Lola Run's artwork, and films without a file showed the placeholder.
