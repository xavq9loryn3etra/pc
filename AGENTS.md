# Popcorn: notes for coding agents

Popcorn is a Flutter movie and series streaming app (phones, iPad, Windows, Android TV). The app is in `flutter_client/`. Read this whole file before starting any task. These are decisions the owner has already made, so don't reopen them.

## Working with the owner

- **The owner is not technical.** Explain in plain language with everyday words. Say what changed and why before giving any detail. Keep file paths and jargon short and at the end. When they have to do something themselves, give numbered steps.
- **Questions are not instructions.** For a "can we…?" or "is it possible…?" question, investigate (reading code and measuring is fine), propose an approach with a recommendation, then **wait for a clear go-ahead** ("do it", "go with it") before editing code. Clear instructions ("remove it", "do the new release") mean act now.
- **Publish without asking.** Once a requested change is finished and checked, commit and push in the same turn and say it's live. Don't ask "should I publish?". An app release reaches every user, so always say clearly when you've done one.
- Be honest: if something is untested or only partly works, say so.
- Never commit secrets (`secrets.json`, `flutter_client/.env`, `android/key.properties`).
- **Keep this file up to date.** When the owner makes a new decision, gives a correction or says "always"/"never", add it to the right section of this file in plain words (with the date), commit and push it with the work. Change or remove rules here that turn out to be wrong. Don't add one-off details that only matter to the current task.

## Releases

- The public app and website live at **popcorn-organization/popcorn** (website: GitHub Pages from `docs/` on main, https://popcorn-organization.github.io/popcorn/).
- `.github/workflows/publish-release.yml` in this repo publishes a release **only when `version:` in `flutter_client/pubspec.yaml` changes** on main. To ship: bump the version and push. Never reuse a version number. The workflow also updates the README's latest line and sets `docs/flags.json` `min_required_version` (Android and Windows).
- iPhone: Codemagic (`codemagic.yaml`, `xcode: latest`) builds TestFlight. The workflow does **not** raise the iPhone flag (`ios.min_required_version` in flags.json). Raise it only when asked, after the Codemagic "iOS TestFlight Release" check on the release commit succeeds plus ~10 minutes for Apple processing.
- From April 2027 iOS uploads need the iOS 27 SDK (Xcode 27). Near then, check that Codemagic's "latest" has moved; if it hasn't, pin `xcode: 27.x`.
- Set GitHub secrets with `gh secret set NAME --body "..."`. Piping from PowerShell adds CRLF and broke a release before.
- There is no Mac build yet (owner chose "later").

## Building and testing (Windows PC)

- Devices: the owner uses a **Galaxy S25 Ultra** daily (120 Hz, USB serial RFGYB1R4V2F). A **Galaxy S10** (60 Hz, OpenGLES) is on wireless adb for test installs and frame measurements. Its adb name changes between sessions, so run `adb devices` first.
- Android test install: `flutter build apk --release`, then `adb -s <serial> install -r <apk>`. Launch with `adb shell monkey -p com.popcorn.flutter_client -c android.intent.category.LAUNCHER 1`. A "prod build" on the S25 means this release build.
- Judge smoothness only on profile/release builds. Over ~16 ms per frame on the S10 will show on the S25.
- **Windows build:** close the running app (process `flutter_client`), then delete `windows/flutter/ephemeral`, `build/windows` and `.dart_tool/flutter_build`, then run `flutter build windows --release --dart-define-from-file=secrets.json` (~4–5 min). Deleting only the ephemeral folder makes it worse. Never build while the owner's own `flutter run` is going; two builds break each other. Testing an installed Windows release needs the installed Popcorn closed (single instance), so ask first and reopen it afterwards.
- Local builds need `--dart-define-from-file=secrets.json` for Google sync (`.\run` does this). The app has no built-in Gemini key.
- Python 3.13 is at `C:\Users\Megha\AppData\Local\Programs\Python\Python313\python.exe` (plain `python` may hit the Microsoft Store stub).

## Product rules

- **Movies and series only.** Hide documentaries, making-ofs/featurettes, stand-up specials, concert films, and talk/news/reality TV. Every list, row, recommendation and Ask result goes through `TMDBService.isUnsuitable`. Real musicals, comedies and sitcoms stay.
- **Never switch audio language.** Never play a different language than the one chosen: no fallback to a dub, not even with a notice. Every automatic copy choice (start fallback, stall recovery, next episode, resume) must filter to the chosen language. If nothing in that language works, stop and say so.
- **Streaming-service buttons ("watch on Netflix" etc.)** open only that service's app, directly to the title (`LaunchMode.externalNonBrowserApplication`). Never fall back to TMDB, a search page or any website. If it can't open, show a message.
- **Books and Music are switched off** on every platform (`AppModeService.booksAndMusic = false`). Don't advertise them.
- **Ramen** = anime mode (phones, iPad, Windows; colour #FD5602). Anime is blocked from Popcorn there (`TMDBService.isAnime`). TV has no mode switch and keeps anime in Popcorn. Never use fan edits (e.g. One Pace). Episode numbers go through EpisodeNumbering (Cinemeta) before Torrentio.
- **Ratings:** the title page shows the IMDb rating from Cinemeta. Home, trending and search lists are still TMDB, so don't claim they come from IMDb.
- **Lists of titles:** use dense poster grids, not side-scrolling carousels. Ask before replacing a grid with rows.
- **Plain glass = solid black.** On slow devices, battery saver and all TVs, every overlay is opaque AMOLED black (Ask's input is dark grey). New glass surfaces must use `glassTint(context)` / `glassSheetTint(context)` (glass_blur.dart), not `kGlassTint` directly.
- **Home hero slideshow** (top 10 trending, Ramen top 10 popular, `lib/widgets/hero_carousel.dart`): keep the easeInOutCubic 800 ms slide, 7 s per slide. Text, buttons and picture frames move exactly with the finger; only the image inside moves at half speed. On TV the remote never changes slides.
- **Subtitle panel (21 Nov 2026):** Show each subtitle language once and keep filenames hidden. Offer “Try another subtitle” when the selected language has alternatives. Timing is automatic. Never offer manual timing controls. Keep timing messages inside the panel. Show two glowing lines by the subtitles during active timing checks or while Sinhala subtitles for the current scene are being generated. Leave the player buttons steady. Require two separate stretches of dialogue to agree before applying a speech-based adjustment.
- **Sinhala subtitles:** auto-translated from English subtitles with the person's own Gemini key (Settings). Keep the model order and the spoken-Sinhala instructions in the translator. Without a key the option stays visible but greyed out ("Add your Gemini key in Settings"). The owner prefers greying things out to hiding them.
- **Sync (Google Drive appDataFolder, no server):** lists belong to the Google account. Sign in / Sign out (no switch). Signing out saves first, then clears local lists. "Delete synced data" only deletes data and never signs anyone out. Signing out never revokes Google's grant. No popups in Settings: Sync and Gemini key are their own pages. Tests: `test/sync_merge_test.dart`, `test/sync_flow_test.dart`.
- **Never** disguise traffic to use YouTube/Netflix "unlimited" data packages.

## TV app (Android TV / Google TV / Fire TV only, no Apple TV)

- Same layout as Windows, laid out at 1280 wide and scaled. Popcorn only (no mode picker).
- Gemini key is added from a phone via QR code (PhoneKeyServer).
- **Player remote:** controls appear ONLY when OK is pressed. OK shows them without pausing, with the play button selected (Netflix style). Left/right skip 10 s showing only the skip icon. Up/down do nothing while controls are hidden. A slow seek shows a centred spinner, not the controls. TV subtitles are 40% bigger.
- Continue Watching cards on TV have an "i" (info) button before play.

## Website (popcorn-organization/popcorn, `docs/`)

- Pages: Home, Features, Download, Help. Every page has the identical top bar, full width and footer. Check for sideways overflow at 320–1920 px widths before pushing.
- **No tag chips:** no small outlined capsule labels (version capsules, uppercase eyebrows, "THIS DEVICE"). Use plain text.
- **No decorative icons:** no icon-in-a-square tiles, no icons beside links, no tick circles, no numbered circles. They look AI-generated. Platform logos on download buttons are fine, as are the owner's own badges (Ask AI, surround, CC, GEN CC).
- Real screenshots only (film: *Possible Love*; series: *Ghosts*). Prefer the owner's own iPhone screenshots and don't crop them tightly.
- Never mention Stremio. Don't claim offline downloads, speech-generated subtitles, picture-in-picture, a speed menu, Books/Music, or iPhone/Mac availability.

## Open items (waiting on the owner)

- TV picture: prefer copies that aren't Dolby-Vision-only, and test debanding on the S10. Awaiting a go-ahead.
- "Download tonight" (cheap night-time data, Android first): recommended for later, not started.
- Google "Popcorn (Unverified)" verification: the owner said later.
