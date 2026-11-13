# Popcorn

The Popcorn app for Android, Windows and iOS, built with Flutter.

## Project structure

- `flutter_client/`: the Flutter app.
- `docs/flags.json`: remote settings the app reads from GitHub Pages (required version, update link, maintenance mode).
- `.github/workflows/`: builds, tests and releases.

The download website and published releases live in a separate public repository: [popcorn-organization/popcorn](https://github.com/popcorn-organization/popcorn) ([website](https://popcorn-organization.github.io/popcorn/)).

## Releasing a new version

1. Raise `version:` in `flutter_client/pubspec.yaml` (e.g. `3.0.1+53` to `3.0.2+54`).
2. Push to `main`.

GitHub then builds the Android APK and the Windows installer, publishes them as the latest release, and once that succeeds updates `docs/flags.json` so the app asks older versions to update.

## Development

Run these from the `flutter_client` folder:

- **Run the app**: `flutter run --dart-define-from-file=secrets.json`
- **Get packages**: `flutter pub get`
- **Build the Android APK**: `flutter build apk --release --dart-define-from-file=secrets.json`
- **Build the Windows installer**: `powershell -ExecutionPolicy Bypass -File windows\installer\build_installer.ps1`
- **Generate launcher icons**: `dart run flutter_launcher_icons` (from `assets/icon.png` and `assets/icon-transparent.png`)

`secrets.json` (git-ignored) holds `GEMINI_API_KEY`. Android release builds are signed with the key referenced by `android/key.properties` (git-ignored).
