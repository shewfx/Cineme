# Cinemé release versioning

`frontend/pubspec.yaml` is the single source of the app version. Use the
`MAJOR.MINOR.PATCH+ANDROID_CODE` format; keep the Android version code higher
than every previously shipped Android release.

- **PATCH**: fixes and small visual changes.
- **MINOR**: new features that remain compatible with existing users.
- **MAJOR**: incompatible changes.

Redeploying identical code keeps the same release version. A new version is
for a new release, not for each deployment attempt.

The About screen reads the installed app version from package metadata on both
Web and Android. Web's metadata is generated from `pubspec.yaml` in
`version.json`; Android's metadata is built from the same version field. The
source commit is injected at build time through `SOURCE_COMMIT` and displays
as `Development` in builds where that define is absent.

For Web and Android release builds, inject the short source SHA from
`git rev-parse --short HEAD` as `SOURCE_COMMIT`. For Android releases,
increment the `+ANDROID_CODE` portion of `frontend/pubspec.yaml` for each
release. Local development builds may omit `SOURCE_COMMIT`.
