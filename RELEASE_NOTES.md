# Popcorn release notes

What's new in each version, newest first, in plain words for the people who
watch with Popcorn. The app shows these on its update pages (the newest five
versions), and each version's notes also go on its page on the download site.

Adding a version: before bumping `version:` in `flutter_client/pubspec.yaml`,
put a `## x.y.z` heading at the top with a `- ` line for each change people
will notice. Keep each line short and free of technical words.

- A new **last** number (4.5.3 → 4.5.4) is a small update: nobody is
  interrupted; Settings offers it, with a dot on its tab.
- A new **middle or first** number (4.5.x → 4.6.0) is a big update: everyone
  older sees the full-screen update when they open the app.

## 4.7.0
- On TVs with little memory, Popcorn now uses much less of it while you browse, so it runs more steadily there.
- On the Home screen, the Popcorn logo now scrolls away smoothly instead of being cut off at the top.
- Subtitles stay above the progress bar when you open a menu while watching.
- On Windows, Popcorn always opens when you click it, even right after closing it.

## 4.6.0
- Small updates no longer interrupt you: Settings shows when one is ready, with what's new, and you update when you like.
- The update screen now shows what's new.
- Sinhala subtitles get in time much sooner, using the English subtitles built into the video when it has them.
- When two people speak in one Sinhala subtitle, each gets their own line again.
- Subtitles stay on screen when you pause.
- The "Syncing subtitles…" note is now the same size as the subtitles.
- The Home slideshow is cleaner, with the title's logo a little lower.
- Moving between tabs is calmer: the background glow stays still.
- On Windows, the side panel is tidier and the Ask button shows the Ask logo.

## 4.5.3
- When something goes wrong, Popcorn sends a short crash report so it can be fixed. It never includes your Google account or keys.

## 4.5.2
- Sinhala subtitles are in time straight away when the English ones already are.

## 4.5.1
- Page titles get their frosted backing back as you scroll.
- Logos in the Home slideshow no longer appear late.

## 4.5.0
- Subtitles get in time with the film by themselves, and Popcorn picks the copy that fits.
- Finished films leave Continue Watching. A finished series comes back when a new episode is out.
- Press and hold a Continue Watching card for More Info, or to remove it, with Undo.
- Smoother playback on TVs while subtitles sync.
