/// Scripted UI preview, opt-in only: `--dart-define=CINEME_PREVIEW=true`.
/// Enables fake repositories and local preview posters (ADR 002).
const isUiPreview = bool.fromEnvironment('CINEME_PREVIEW');
