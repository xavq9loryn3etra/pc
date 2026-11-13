@echo off
rem "flutter run" with the git-ignored secrets.json (the Gemini key for Ask).
rem Anything after it is passed on, e.g.:  .\run -d windows   .\run --release
flutter run --dart-define-from-file=secrets.json %*
