# Flutter client audit — implementation brief

Scope: torrent engine, stream resolution, video player, app shell. Music and book modes are excluded.
All paths are relative to `apps/flutter_client/`. Line numbers were correct on 2026-11-11 (build 52); re-locate by symbol name if they have drifted.

**Status of this document**

| Area | Status |
|---|---|
| 1. Video player | Complete. Items marked ✔ were re-checked against the code by a second pass. |
| 2. Native torrent engine (`packages/libtorrent_flutter`) | Complete. Items marked ✔ were re-checked. |
| 3. Dart torrent services (`lib/services/torrent`) | Complete. Items marked ✔ were re-checked. |
| 4. App shell, web player, secrets, build | Complete. Items marked ✔ were re-checked. |

Unmarked items come from a single read of the code and were not re-checked. Confirm each against the code before changing it; if the code does not match the description, skip the item and report it.

**Suggested order of work**

| Batch | Items | Why first / notes |
|---|---|---|
| 1. Stop background data and battery drain (Dart only) | P-H1 + S-C1, S-H1, S-M5 | Worst user-facing harm; no native rebuild |
| 2. Stop losing progress and data (Dart only) | P-H2, P-H4, S-M3, A-M3, A-H2 | Small, contained fixes |
| 3. Playback that recovers | P-H3, P-H5, P-M1, P-M8, S-H3, S-M6 | P-M1 needs a device test |
| 4. Native engine rebuild (one new tag) | N-H1, N-H2, N-M2, N-M3, N-M7, N-M8, N-M9, N-M10, N-L1, N-L3, N-L5, then N-M11 | Batch into a single rebuild; owner approves the release |
| 5. Owner actions | A-H1 (signing key), A-H3 (rotate/revoke keys) | Cannot be done by the implementer alone |
| 6. Hardening | S-M2, S-M4, A-M1, A-M2, A-M6, A-M7, S-M1 | |
| 7. Performance | P-M3, P-M4, N-M1, N-M4, N-M5, N-M6, N-M12, P-M2 | Measure on the S10 (frame timings) before and after |
| 8. Everything else | Remaining Medium, then Low, then CI/hygiene | A-M4 needs a tested migration |

**Rules for the implementer**

- Fix in the order listed; each item is independent unless it says otherwise.
- One commit per item, with the item ID in the message (e.g. `fix(player): P-H1 cancel resolves on dispose`).
- Do not refactor beyond what an item asks for. The structural note at the end of each section is optional follow-up work.
- Nothing here was measured on a device. Items marked "needs device test" must be verified on the S10 before being called done.
- User-facing rule that must be preserved: "watch on" streaming-link buttons open the provider app only, never a browser or search page.

---

## 1. Video player

Files: `lib/screens/player_screen.dart` (all line numbers below unless another file is named), `lib/widgets/player_gesture_overlay.dart`, `lib/widgets/glass_blur.dart`, `lib/services/subtitle_sync.dart`.

### High

#### P-H1 ✔ Leaving the player mid-switch leaves torrents downloading in the background

- Where: `_attemptStreamRecovery` 986 and 996, `_switchQuality` 1818, `_playEpisode` 2350, `_playEpisodeWithChosenStream` 2425, `_returnAfterFailedSwitch` 1875, `dispose` ~2806.
- Problem: none of the five `_resolver.resolveWithFallback(...)` calls in this file pass `isCancelled`. The resolver supports it (`stream_resolver.dart:647`) and `details_screen.dart:2223` already uses `isCancelled: () => !mounted`. After `dispose()`, an in-flight resolve still starts the new torrent; `_openMediaWithResume` then throws on the disposed player; the `catch` calls `_returnAfterFailedSwitch`, which resumes the torrent that `dispose()` just paused and calls `player.play()` on a disposed player.
- Scenario: Up Next fires (or the user taps Next / a quality), "Loading…" shows, the user presses back. Two torrents keep downloading with no player, possibly on mobile data. In the episode case, history already points at an episode that was never watched.
- Fix:
  1. Pass `isCancelled: () => !mounted` to all five calls. Catch `ResolveCancelledException` and return silently.
  2. After every `await` in those four functions add `if (!mounted) { _resolver.pause(result.torrentId); return; }`. The most important place is immediately after the resolve and before any `addToHistory` call.
  3. In `_returnAfterFailedSwitch` and `_showFailedEpisodeSwitch`, return immediately when `!mounted`.

#### P-H2 ✔ Stall recovery or a quality switch while opening discards the resume position, then overwrites the saved one

- Where: 952 (`final resumeAt = _currentPosition;`) → 1004 (`precisePosition: resumeAt`); the same pattern in `_switchQuality` (~1792 `savedPos`, ~1830).
- Problem: while a resumed title is still opening, `_currentPosition` is zero. Passing `precisePosition: Duration.zero` bypasses the saved-progress branch in `_openMediaWithResume`.
- Scenario: resume a movie at 1h05; the first copy is slow, recovery moves to another copy and starts at 0:00; the next periodic `_saveProgress` replaces the 1h05 entry with ~0.
- Fix: in both functions compute
  `final precise = (_isMediaOpening || _currentPosition < const Duration(seconds: 5)) ? null : _currentPosition;`
  and pass `precisePosition: precise`. `null` must take the existing saved-progress path.

#### P-H3 ✔ No handler for player errors or end of file: a dead stream shows a spinner forever

- Where: `_initPlayer` 576-750. There is no `player.stream.error` or `player.stream.completed` listener anywhere in the player (the only use in `lib/` is `subtitle_sync.dart:414`).
- Problem: if mpv fails to open or loses the URL, `_isMediaOpening` stays true and the stall watchdog (853-863) only acts while `_isPlaying`, so nothing ever recovers. At end of file with no Up Next shown, nothing happens either.
- Fix:
  - `_errorSub = player.stream.error.listen((e) { ... })`: when `mounted && !_switchingQuality && !_recoveringStream`, call `_attemptStreamRecovery(reason: 'mpv error: $e')`. When attempts are exhausted, set `_isMediaOpening = false` and show the existing "Try another quality" message.
  - `_completedSub = player.stream.completed.listen((done) { if (!done) return; ... })`: force-save progress; if a released next episode exists and Up Next is not showing, call `_playNextEpisode()`; otherwise show the controls.
  - Cancel both in `dispose`.
- Unverified: the exact mpv state after a failed load. Test by pointing the player at a URL that returns 404.

#### P-H4 ✔ Switching to the web player resets the current episode's progress to zero

- Where: `_openWebPlayer` 1981-2004, `_openWebPlayerForEpisode` 2025-2049; position listener 694-712; `dispose` (calls `_saveProgress(force: true)`).
- Problem: both functions start with `await player.stop()`, which emits position zero. `_closing` is not set on this path, so `_currentPosition` becomes zero. `Navigator.pop` then runs `dispose`, which force-saves progress 0 for the old episode, after `addToHistory(new episode)` has run.
- Scenario: 30 minutes into E3, the user picks E4 with a web source. E3's progress becomes 0 and Continue Watching flips back to E3.
- Fix: add a field `bool _progressFinal = false;`. At the top of both functions: `await _saveProgress(force: true); _progressFinal = true;` before `player.stop()`. Make the position listener return early when `_closing || _progressFinal`. Make `dispose` skip its `_saveProgress` when `_progressFinal` is set. `_close()` should set the flag after its own forced save.

#### P-H5 ✔ (watchdog) Leaks when the player is closed while still starting up

- Stall watchdog, 745-749: the `Timer.periodic` is created after `await _openMediaWithResume(...)` with no `mounted` check. If the user backs out during a slow open, `dispose` cancels a null timer, and the timer then fires every 5 s for the life of the app, holding the whole State. Fix: `if (!mounted) return;` immediately before creating it (or create it in `initState`).
- Media session, 1123-1160: if `requestNotificationPermission()` or `activate()` is still pending when `dispose` runs, activation completes after the deactivate and `_mediaActionSub` is assigned after the cancel. Fix: after each `await` in that function, `if (!mounted) { await _mediaSession.deactivate(); return; }`.
- `_initPlayer` has no try/catch and runs after several awaits (583-608). Fix: bail on `!mounted` after each await, and wrap the body in try/catch that logs and shows the existing failure message.

### Medium

#### P-M1 media_kit's 5-second network timeout is never raised (needs device test)

- Where: mpv setup 582-600. media_kit sets `network-timeout=5` by default.
- Problem: the local torrent server can be silent for more than 5 s while waiting for a piece. ffmpeg then aborts the read and mpv tends to treat it as end of stream. This matches the "playback silently stops advancing" symptom the watchdog was written for.
- Fix: in `_initPlayer` set `network-timeout` to `60` and `stream-lavf-o` to `reconnect=1,reconnect_streamed=1,reconnect_delay_max=5`.
- Verify on the S10 with a poorly seeded torrent before and after.

#### P-M2 Cache sizes are the same on phones and desktop

- Where: 589-591 (`demuxer-max-bytes=150M`, `demuxer-max-back-bytes=50M`).
- Fix: on Android/iOS use `64M` / `16M`; keep the current values on Windows.
- Related: `demuxer-readahead-secs=10` has no effect while `cache-secs=60` is set. `cache-pause-initial=yes` with `cache-pause-wait=5` adds a fixed 5 s wait to every start and every stall; consider `cache-pause-wait=2`.

#### P-M3 The seek bar rebuilds on every position tick, even when hidden

- Where: position listener 694-718; seek bar 4571-4836; time label ~4988.
- Fix:
  1. In the position listener, update `_positionNotifier` only when `pos.inSeconds` changes or the delta is ≥ 250 ms.
  2. Compute skip ranges and partition fractions once (in `_rebuildSkipSegments` / `applyDuration`) and store them, instead of in `build`.
  3. Wrap the bottom bar in `Visibility(visible: _controlsVisible || <fading>, maintainState: true)` so hidden controls do not build.

#### P-M4 Live blur over playing video

- Where: `lib/widgets/glass_blur.dart` 186-190, 423-426; player 5031-5140 and 5205-5261.
- Problem: each `GlassPillButton` / `GlassBubbleBar` is its own `BackdropFilter`. The Skip Intro / Up Next pill stays over the video for 60-90 s, re-blurring every frame; with controls up there are 5-8 separate backdrop captures.
- Fix: add a `grouped` option to `GlassPillButton` / `GlassCircleButton` that uses the existing `BackdropGroup` (`main.dart:364`), and set it in the player. Alternative: a `paused: _isPlaying` option that shows a plain tint over moving video and frosts only when paused.

#### P-M5 Volume/brightness swipe applies a stale start value first

- Where: `lib/widgets/player_gesture_overlay.dart` 277-331.
- Problem: `_startValue` is filled asynchronously (`getVolume().then(...)`), but the same move event immediately computes `_startValue + delta` and applies it. On the first swipe the start value is 0.0.
- Scenario: at 60% volume, the first upward swipe drops the volume to ~6% for an instant.
- Fix: add `bool _startReady = false`. Clear it when the gesture type is chosen; in the `then` callback set `_startValue`, reset `_pointerStart` to the latest pointer position, and set `_startReady = true`. Skip applying values while `!_startReady`.

#### P-M6 Auto Sync's second mpv instance outlives the player and competes for the stream

- Where: `_autoSync` 3378-3383; `lib/services/subtitle_sync.dart` 388-430 (`decodeSound`).
- Problem: a second `Player()` reads up to 6 minutes of audio from the same stream URL as fast as it can, starting ~15 s into playback, with a 3-minute timeout and no cancellation.
- Fix: add a `bool Function()? isCancelled` (or a `Future<void> cancel`) parameter to `decodeSound`, race it against completion, and trigger it from `dispose` and on any stream change. Do not start unless buffered-ahead (`_bufferNotifier.value - position`) exceeds 30 s.

#### P-M7 Episode switches are not re-entrant, and state is committed before the new media opens

- Where: Next button 5116-5121, `_playNextEpisode` 2627, `_playEpisode` 2279, `_applyResolvedEpisode` 2457-2535, `_switchSeason` 2703-2719, play/pause 4864.
- Fix:
  1. `if (_switchingQuality) return;` at the top of `_playEpisode`, `_playEpisodeWithChosenStream` and `_switchQuality`.
  2. Give `_switchSeason` its own `_loadingSeason` flag instead of sharing `_switchingQuality`.
  3. Make `_playPause` (button and Space key) a no-op while `_switchingQuality`.
  4. Move the `addToHistory` / last-played writes in `_applyResolvedEpisode` to after `_openMediaWithResume` succeeds; or snapshot season/episode/duration fields and restore them in the catch.

#### P-M8 `_close()` can leave a permanent black screen

- Where: 531-567.
- Fix: wrap everything after the `setState(() => _closing = true)` in `try { … } catch (_) {} finally { if (mounted) Navigator.pop(context); }`.

### Low

- **P-L1** Stall watchdog can delete a fully downloaded copy (902-918, 995). When the torrent is complete, `downloadStuck` is always true. Fix: when `totalDone >= totalWanted`, skip `deleteByInfoHash` and just reopen at the current position.
- **P-L2** Held arrow keys flood seeks (1386, 1422-1434). Fix: keep accumulating `_lastSkipTarget` but issue the real `_seekTo` from a 150 ms trailing timer.
- **P-L3** Double-tapping a control also seeks 10 s (overlay 358-368; player 4196-4207). Fix: in `onDoubleTapSeek` / `onDoubleClick`, return if `_controlsPointerAt` is within the last second.
- **P-L4** Wakelock is held while paused (363, 2740). Fix: enable/disable from the `playing` listener, releasing ~60 s after pause.
- **P-L5** Small items:
  - `_selectSubtitle` 3721-3729: `setState` after an `await` with no `mounted` check.
  - Retimed subtitle files (`popcorn_sub_*`, 3579-3581) are never deleted. Delete `_retimedPaths` values in `dispose` and `_forgetFileSubtitles`.
  - `_subtitleText` 3513 creates a `Dio()` per call with no timeout. Use one shared instance with 15 s connect/receive timeouts.
  - `_syncMediaSessionPlaybackState` 1166 hard-codes `speed: 1.0` during the 2x hold.
  - `_showSubtitlePicker` 3934-4112 appears to be dead code; confirm with a search and remove.

### Optional structural follow-up (after all fixes above)

`_PlayerScreenState` has ~120 fields and one flag (`_switchingQuality`) shared by four flows. Extract in this order, one PR each:
1. `SubtitleSyncController` (2947-3741).
2. `StreamSwitcher`: one serialized switch job with a cancel token, owning `_switchQuality`, `_playEpisode*`, `_attemptStreamRecovery` and the watchdog.
3. `ProgressSaver`: the `_saveProgress` rules and the `_progressFinal` flag.
4. Bottom bar and seek bar as separate widgets taking the notifiers.

### Checked and found sound (do not change)

- `dispose` cancels every subscription, timer and controller created before it ran; teardown order (stop → dispose → pause torrent) is correct.
- Orientation, system UI, brightness, and Windows full screen are restored on every exit path.
- Back handling (`PopScope` → panel → drawer → `_close`) and the double-close guard.
- Position/buffer/speed go through `ValueNotifier`s; the `Video` widget is not rebuilt per tick.
- Resume keys are per episode; resume applies below 95%; forced save on app pause.

### Not verified

- Whether `cache-on-disk=yes` works on Android/iOS (decides the real memory cost in P-M2).
- `screen_brightness` restore on iOS when the app is killed mid-player.
- Accelerometer axis sign on iOS in `_turnLandscape` (518-522).
- 10-bit HEVC hardware decoding on the S10 and on iOS.

---

## 2. Native torrent engine

Files: `packages/libtorrent_flutter/src/torrent_bridge.cpp` ("cpp" below), `torrent_bridge.h`, `packages/libtorrent_flutter/lib/src/libtorrent_flutter_base.dart` ("base.dart"), `ffi_bindings.dart`, build files.

> **Read this first.** Android, iOS and Windows ship a **prebuilt** binary downloaded from the `libtorrent-native-v3` GitHub release (`packages/libtorrent_flutter/native/PREBUILT_RELEASE_URL`). Editing the `.cpp` changes nothing in the app until the `build-libtorrent-native` workflow is re-run under a **new tag** and `PREBUILT_RELEASE_URL` is bumped. Batch all native fixes into one rebuild. Publishing a release is an outward-facing step: ask the owner before running it.
>
> Any change to `torrent_bridge.h` structs or signatures must be mirrored in `ffi_bindings.dart` in the same commit. The current layouts match and were checked.

### High

#### N-H1 ✔ Unbounded RAM growth during playback (two leak paths)

- Path A — cpp 987-1018 (`on_piece_read`), 1291-1303 (`read_piece_data`), 1494-1514 (prefetch). `on_piece_read` stores each piece twice: `read_results[p] = std::move(r);` (998) and `cp->buffer.assign(...)` (1008). `read_piece_data` returns from the cache copy first (1296-1300) without erasing `read_results[piece]`. Prefetched pieces therefore stay in `read_results` until a seek (1682) or stream destruction. One full piece (1-16 MB) leaks per piece played whenever the download is ahead of playback; a 2 GB file tends towards 2 GB of RAM.
- Path B — cpp 1688-1697. On seek, `s->trailing_pieces.clear()` drops the list without freeing those pieces' `cp->buffer`. Each seek leaks ~3-5 pieces.
- Fix:
  1. In `read_piece_data`, on the cache-hit path, also erase `read_results[piece]` under `read_mu`. Simpler alternative: in `on_piece_read`, when `cache` exists and the cache write succeeded, do not populate `read_results`, and make `read_piece_data`'s wait predicate also accept "cache piece complete".
  2. In the seek flush, before `trailing_pieces.clear()`, release each trailing piece's buffer using the same lines as the eviction at 1547-1551.
  3. Add a hard cap: track total bytes held in cache buffers; when it exceeds `max(4 pieces, 64 MB)`, evict the least recently accessed piece that is not the one being served.
- Verify: play a fully cached 2 GB file on the S10 for 20 minutes and watch app memory (Android Studio profiler or `adb shell dumpsys meminfo`). It must plateau.

#### N-H2 Stream stop/start and session destroy block the UI thread

- Stop — cpp 2711-2726, 1819-1823: stop closes the listen socket, then joins the server thread, which is in `select()` with a 200 ms timeout. Every stop freezes the UI up to 200 ms (plus up to 100 ms for the preload thread's sleep at 1935). Happens on player close, episode switch and `coolDown`.
- Lost wake-up — cpp 2711-2713, 1032-1035: `active = false; wake_all();` is done without holding `piece_mu`/`read_mu`. A waiter between predicate check and block misses the notify and waits its full timeout (60 s at 1450, 10 s at 1323, 30 s at 1930). The join then hangs that long: an ANR.
- Start — cpp 2682-2683: polls `running` in 10 ms sleeps, up to 2 s if bind fails.
- Destroy — cpp 2171-2228: up to 3 s polling, joins, a 200 ms sleep, then a blocking `delete sw`. The second resume-flush loop (2219-2224) is dead work because the alert thread is already joined.
- Fix, native:
  1. Set flags under the mutexes: `{ std::lock_guard l(piece_mu); active = false; } piece_cv.notify_all(); { std::lock_guard l(read_mu); } read_cv.notify_all();`. Same for the `seek_generation` bump at 1675.
  2. Create, bind and listen on the socket synchronously inside `lt_start_stream` before spawning the server thread; delete the `running` poll loop.
  3. Replace `select()` with `poll()` (`WSAPoll` on Windows) on the listen fd plus a wake fd (pipe/eventfd; loopback self-connect on Windows). Only the server thread closes the listen socket. This also fixes N-M10 and N-L4.
  4. In `lt_stop_stream`, move the `unique_ptr<StreamEngine>` to a detached reaper thread that joins and destroys it, so the caller returns immediately.
  5. In destroy: delete the second flush loop and the 200 ms sleep.
- Fix, Dart (can ship without a native rebuild, do this first): in `base.dart`, run `stopStream`, `stopAllStreamsForTorrent` and `dispose` through `Isolate.run`, passing the session pointer address as an `int`.

### Medium

#### N-M1 Status polling does heavy synchronous work on the UI thread every 600 ms

- cpp 2408-2421, 239-308: `lt_get_all_statuses` calls `status(query_pieces)` and `torrent_file()` per registered torrent and loops over every piece bit. The Dart side never reads `piecesDone`/`numPieces` (base.dart 58-76).
- base.dart 481: `calloc<LtTorrentStatus>(max(count, _maxTorrents))` allocates ~1.9 MB per poll.
- cpp 2793: `fill_stream_status` calls `status()` with all flags plus `make_url()` while holding `streams_mu`, which the alert thread needs.
- base.dart 463-470: a `NativeCallable` per poll replays up to 2048 alerts into an empty handler.
- Fix (minimum): pass `{}` flags at cpp 2418, 2431 and 2793; delete the pieces loop; use `st.name` instead of `torrent_file()`; cache the URL string in `StreamEngine` at start; allocate one persistent status buffer in Dart sized to `count`; delete `_pollAlerts` and stop queueing alerts natively when no consumer is registered.

#### N-M2 A piece that finishes during `lt_start_stream` is never seen; the stream stalls on it

- cpp 2652-2676: `pieces_have` is seeded from a status snapshot at 2652, but the stream is only added to `sw->streams` at 2675. A `piece_finished_alert` in between is dropped (1175-1181).
- Fix: insert the stream into `sw->streams` first, then take the snapshot and merge under `piece_mu`. Also make waits self-healing: on any wait timeout in `serve_range`/`wait_for_piece`, call `s->handle.have_piece(lt::piece_index_t(p))`; if true, insert into `pieces_have` and continue.

#### N-M3 The server cuts the HTTP response after 60 s without a piece

- cpp 1450-1463, 1470-1474: `piece_cv.wait_for(lk, 60s, …)`; on timeout `serve_range` returns false and the socket is closed mid-body. A 16 MB piece at 200 KB/s takes 80 s, so slow swarms always truncate and mpv sees premature EOF.
- Fix: loop the wait in 5 s slices with no overall deadline while `active` and the generation is unchanged. Each slice: re-assert priority/deadline for `p`, run the `have_piece` check from N-M2, and probe the client socket (`recv(MSG_PEEK | MSG_DONTWAIT) == 0` or `poll` for `POLLHUP|POLLERR`) so a disconnected client ends the thread.
- Pairs with P-M1 (player-side timeout). Do both.

#### N-M4 Seek detection uses one stream-global position; concurrent connections abort each other

- cpp 1657-1662, 1391, 1400: any non-tail request more than 64 KB from the shared `read_head` bumps `seek_generation`, which makes every other `serve_range` exit mid-body.
- Also: `is_tail = range_start > file_size - piece_length*10` treats a real user seek into the last 10 pieces (up to 160 MB) as a tail probe, so no priorities move. For files smaller than 10 pieces, every request is "tail".
- Fix: give each connection its own `std::atomic<bool> cancelled`; `serve_range` checks its own flag. A new non-tail `GET` with a parsed Range becomes the primary and cancels only the previous primary. Narrow the tail test to `rstart >= file_size - min(PROTECT_BYTES, file_size / 20)`.
- Unverified: how many concurrent connections mpv actually opens. Log connection count on device before and after.

#### N-M5 A seek leaves the previous 17-piece window at top priority

- cpp 1427-1444 sets `p..p+16` to priority 7/6; on seek, 1718-1722 clears deadlines but not priorities. Up to 68-270 MB at the old position keeps downloading per seek.
- Fix: record the active window (`win_lo`, `win_hi`) in `StreamEngine` under a mutex. On seek, set every piece in the old window that is not in `pieces_have`, not in the new window and not in the head/tail protect ranges to `lt::dont_download`. Also set `s->preloading = false` on seek.

#### N-M6 Read-ahead only happens while the reader is blocked; cache-size settings do nothing

- cpp 1420-1445: upcoming pieces are prioritised only inside `if (!have_it)`. cpp 532, 610, 688: `clean_pieces`, `set_load_priority`, `clear_priority_impl` are stubs. `lt_set_cache_settings(capacity)` and most `lt_bt_config` fields are no-ops. `player_screen.dart:1086-1101` shrinks the cache in the background to save mobile data; that call currently has no effect.
- Fix: after each piece is sent, ensure pieces `(p, p+N]` have priority (top for +1..+2, 6 beyond) with staggered deadlines, where `N = clamp(capacity / piece_length, 4, 64)` and `capacity` is an `std::atomic<int64_t>` set by `lt_set_cache_settings`. Delete the unused `lt_bt_config` fields from the struct **and** the Dart model, or wire them.

#### N-M7 ✔ (stop path) Torrents download everything before a stream exists and after one stops

- Add path — cpp 2287-2294: torrents are added with default priorities, so once metadata arrives the whole torrent downloads until Dart pauses it (≤ 600 ms later). This applies to all raced warm-up copies, including on mobile data.
- Stop path — cpp 2744-2752: `lt_stop_stream` ends with `prioritize_files(all default_priority)`. On an episode switch (`stopAllStreamsForTorrent` then `_openStream`, `torrent_engine_service.dart:274-279`), this async job can land after the new stream's `prioritize_pieces` and make the whole season pack wanted — the race the comment at cpp 2598-2603 warns about.
- Fix: delete the "restore default file priorities" block in `lt_stop_stream`. In `lt_add_magnet`/`lt_add_torrent_file` set `atp.flags |= lt::torrent_flags::default_dont_download` (confirm it exists in libtorrent 2.0.11's `torrent_flags.hpp`; if not, call `prioritize_files(all dont_download)` in the `metadata_received_alert` handler at 1209-1228).
- Verify: log `totalWanted` after a same-pack episode switch; it must equal one file's size.

#### N-M8 `lt_preload_stream` can abort the app if called twice

- cpp 2862-2869: `preloading` is set inside the new thread (1907); a second call move-assigns onto a joinable `std::thread`, which calls `std::terminate`. Latent: the app calls it once per stream today.
- Fix: `bool exp = false; if (!s->preloading.compare_exchange_strong(exp, true)) return 0; if (s->preload_thread.joinable()) s->preload_thread.join();` then spawn; remove the `store(true)` at 1907. Delete the pointless 5 s cache wait at 1932-1936.

#### N-M9 ✔ (CORS) The stream server has no token and allows any origin

- cpp 1615-1634: the request path is ignored; any `GET` to the port returns the file. cpp 1624, 1754: `Access-Control-Allow-Origin: *`. Binding is loopback (correct).
- Risk: any other app, or a web page in the user's browser, can read the stream or send range requests that break playback via N-M4.
- Fix: generate 16 random bytes per stream; put them in `make_url()` as `/stream/<token>/<idx>`; parse the request line, require `GET`/`HEAD` and an exact path match, reply `404` otherwise. Remove the CORS/DLNA headers and the `OPTIONS` branch.

#### N-M10 ✔ `select()` with `FD_SET` on a descriptor that may exceed 1023

- cpp 1820-1822. The session allows `connections_limit * 20` sockets (cpp 2965), so the listen fd can exceed `FD_SETSIZE`; `FD_SET` then writes out of bounds (abort on Android). Fixed by the `poll()` change in N-H2.

#### N-M11 Prebuilt binaries have no integrity check and the release tag is mutable

- `packages/libtorrent_flutter/android/build.gradle` 49-75, `windows/CMakeLists.txt` 48-72, `ios/libtorrent_flutter.podspec` 43-62 download and unpack a zip with no hash check. The workflow uses `gh release upload … --clobber`. The `.source` marker stores only the URL, so a rebuilt tag is never re-fetched by a cached machine.
- Fix: have the workflow emit `SHA256SUMS`; commit it as `native/PREBUILT_SHA256`; verify in all three consumers (CMake `EXPECTED_HASH SHA256=`, Gradle `MessageDigest`, Ruby `Digest::SHA256`); write the hash into `.source`; remove `--clobber` and fail if the tag exists.

#### N-M12 Session settings that cost battery, data or peers on mobile

All in cpp unless noted. Values are confirmed; the impact is a judgement, so change conservatively and test on a thin swarm.
- 2005-2007, 2965: `connection_speed 200`, `torrent_connect_boost 200`, session limit 1000. Set `atp.max_connections = bt_config.connections_limit` at add time, `connection_speed` 30-50, session limit `4 ×` per-torrent.
- 2057: `unchoke_slots_limit -1` with a 1 MB/s upload cap on every network. Add a metered profile (4 unchoke slots, 50-100 KB/s upload) applied through `lt_configure_session` when Dart reports mobile data.
- 2071-2073: `dht_announce_interval 60` (default 900), announce to all trackers and tiers. Restore the default interval.
- 2933-2935: `lt_configure_session` with `enable_ipv6 = 0` rewrites `listen_interfaces` to `0.0.0.0:6881`, dropping IPv6 peers and ignoring `peers_listen_port`. Listen on both `0.0.0.0` and `[::]` with the configured port.
- 2018-2021: `piece_timeout 5`, `request_timeout 5`, `peer_timeout 15`, `inactivity_timeout 15` drop slow but usable peers. Raise to 20 / 20 / 60 / 60.
- 1198-1199, 2374: resume data is written on the alert thread on every pause. Move `write_resume` to a small worker thread.

### Low

- **N-L1 ✔** cpp 93-113: debug log to a hardcoded developer path (`C:\Users\Ayman\Desktop\torrent_debug.log`) is compiled into shipped binaries; every `TB_LOG` takes a global mutex and retries the failing `fopen`. Fix: wrap in `#ifdef TB_DEBUG_LOG`, otherwise `#define TB_LOG(...) ((void)0)`.
- **N-L2** cpp 1345-1367, 1640-1645: Range handling. Implement suffix ranges (`bytes=-N`), return `416` with `Content-Range: bytes */<size>` for a start past EOF, and parse the method from the request line only.
- **N-L3** cpp 1372-1373, 1602-1603: `EINTR` is treated as fatal. Add `if (n < 0 && errno == EINTR) continue;`.
- **N-L4** cpp 2716-2719, 2195-2198 vs 1870-1873: the listen socket is closed from two threads. Fixed by single ownership in N-H2.
- **N-L5** Exceptions can escape `extern "C"`: `lt_start_stream` (2513-2581), `lt_remove_torrent` (2355), `lt_set_download_limit`, `lt_set_upload_limit`, `lt_poll_alerts`. Wrap every exported body in `try { … } catch (...) { set_err(...); return <error>; }`.
- **N-L6** cpp 1975, 2161-2166: session-state file uses `std::ifstream(char*)` (fails on non-ASCII Windows profile paths) and a non-atomic remove+rename. Use `std::filesystem::u8path` and `std::filesystem::rename`, as `write_resume` already does.
- **N-L7** cpp 167-188, 224: resume data is never found for hybrid v1+v2 torrents. Name and compare by the v1 hash when `has_v1()`.
- **N-L8** base.dart 262-266: `removeTorrent` does not stop that torrent's streams. Call `stopAllStreamsForTorrent(id)` first. (Dart-only; see also S-M4.)
- **N-L9** base.dart 22-41: trackers are fetched at runtime from a third-party list and appended unvalidated, including https trackers this build cannot use. Filter to `udp://` and cap at 8, or pass `fetchTrackers: false` and use the static list.

### Checked and found sound (do not change)

- Struct layouts and function signatures match between `torrent_bridge.h` and `ffi_bindings.dart`.
- FFI string and buffer lifetimes; every allocation is freed in `finally`.
- Lock ordering (no inversion found) and teardown order.
- HTTP server binds loopback; no path traversal or header injection; byte arithmetic is consistent.

### Not verified

- libtorrent 2.0.11 details relied on from memory (`default_dont_download`, async `prioritize_files` timing).
- Whether the published `v3` binaries were built from the current working-tree `.cpp`. The workflow file has uncommitted changes.
- iOS behaviour when the app is suspended (server threads, sockets).

---

## 3. Dart torrent services

Files: `lib/services/torrent/*`, `lib/services/background_download_service.dart`, `android/app/src/main/AndroidManifest.xml`.

### Critical

#### S-C1 ✔ Closing the player mid-switch leaks two running torrents

Same bug as **P-H1**, seen from the engine side. In addition to the P-H1 fix:
- `lib/services/torrent/torrent_engine_service.dart:662-668`: make `resume(int id)` a no-op unless `_streaming.contains(id)`. `pause()` removes the id, so a late resume can no longer restart a closed torrent.
- Combined with N-M7 (stop restores default priorities), the leaked torrent currently downloads an entire season pack. Fix P-H1 + this item first; they need no native rebuild.

### High

#### S-H1 ✔ (manifest) The Android background service has no stop condition and survives the app

- Where: `android/app/src/main/AndroidManifest.xml:53-56` (no `android:stopWithTask`); `lib/services/background_download_service.dart:35-67`; `player_screen.dart:1092-1102`.
- Problem: the service starts on app pause and stops only on resume or player dispose, holding a wake lock and Wi-Fi lock. Without `stopWithTask`, the plugin restarts the service after the app is swiped away. On Android 15+, a `dataSync` service is limited to 6 h per day and the plugin has no `onTimeout` handler (crash risk; unverified).
- Fix:
  1. Add `android:stopWithTask="true"` to the `<service>`.
  2. Call `BackgroundDownloadService.instance.stop()` once in `main()` (inside try/catch) to clear a stale service.
  3. Bound the run: when the app is backgrounded, start a 10-minute timer that pauses the torrent and calls `stop()`; cancel it and resume the torrent on `resumed`.
  4. Fix the start/stop race (S-M5).

#### S-H2 Same-torrent episode switch can make the whole pack download

Dart side of **N-M7**: `torrent_engine_service.dart:274-279` (`stopAllStreamsForTorrent` then `_openStream`), also 564-565 and 652. Fixed by deleting the native priority-restore block. No Dart change needed beyond verifying `totalWanted` after the rebuild.

#### S-H3 ✔ (cache write) Partial search results are cached for 20 minutes

- Where: `lib/services/torrent/torrent_index_service.dart:335-370` (`_gather`); `lib/services/torrent/stream_resolver.dart:141-163` (`_find`; 160: `_found[key] = …` whenever `found.isNotEmpty`).
- Problem: `_gather` returns after 8 s if any source answered. Torrentio takes 15-20 s on a cache miss. Whatever came back is cached, so a slow first lookup hides season packs and most copies for 20 minutes.
- Fix: make `_gather` return `({List<TorrentStream> streams, bool complete})`, where `complete` means every lookup finished without throwing. Each of `_torrentio`/`_yts`/`_pirateBay` must distinguish failure (return `null`) from "no results" (empty list). In `_find`, cache only when `complete`. Let late lookups finish in the background and overwrite `_found[key]` with the merged list.

### Medium

#### S-M1 No free-space check

- Where: `lib/services/torrent/torrent_storage_service.dart:82-130`. The 2 GB limit runs only at app start and player close and skips the in-use torrent. Nothing checks free disk space, so a 20-60 GB copy can fill the device; write errors then trigger the stall watchdog, which wipes and restarts.
- Fix: add a free-bytes query (Android `StatFs` through the existing `popcorn/device` method channel in `MainActivity.kt`; `GetDiskFreeSpaceEx` via `ffi` on Windows; `NSFileManager` attributes on iOS). In `resolveWithFallback`, skip copies larger than `free - 500 MB`. During playback, check every 30 s and pause the torrent with a clear message when free space drops below 500 MB.

#### S-M2 Remote `infoHash` is used unvalidated in the magnet and the save path

- Where: `torrent_engine_service.dart:195` (`'magnet:?xt=urn:btih:$key$trackerParams'`), 204; `lib/services/torrent/torrent_paths.dart:27-30` (`'$dir/$infoHash'`); `torrent_index_service.dart:163, 391, 423, 472`; `torrent_storage_service.dart:152-177`.
- Risk: a hostile index can return a hash containing `&dn=` or `../`, which escapes the torrents directory; `_deleteByPath` can then recursively delete an attacker-chosen path (plausible on Windows; unverified).
- Fix: one helper `bool isValidInfoHash(String h) => RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(h);`. Apply in `TorrentStream.fromJson` and `fromRelease` (drop invalid entries and lowercase the hash), and assert in `TorrentEngineService.connect` and `TorrentPaths.savePathFor` (throw `ArgumentError`).

#### S-M3 Cached downloads are deleted when they should be kept (three paths)

- After wipe-recovery: `player_screen.dart:995-1000` — the `else` branch never calls `_rememberPlayedTorrent`, so the re-downloaded copy is unregistered and is deleted by `coolDown` when the details page closes. Fix: call `await _rememberPlayedTorrent(resolved.stream);` in the `else` branch too.
- On `startStream` failure: `stream_resolver.dart:700`, `torrent_engine_service.dart:135` — `cleanup(id)` runs on any exception, even for a torrent that already has data. Fix: have `connect` report whether it added the torrent; `cleanup` only then, otherwise `pause`.
- Nested details pages: `torrent_engine_service.dart:404`, `details_screen.dart:433-446` — `warmUp` returns early when a target is already live, but the caller still records it and later cools it down. Fix: `warmUp` returns the list of hashes it actually started; the caller stores only those.

#### S-M4 `TorrentStorageService._deleteByPath` bypasses the engine service

- Where: `torrent_storage_service.dart:157-178`. It calls `engine.removeTorrent(liveId, deleteFiles: true)` directly, which does not stop streams (see N-L8) and leaves `_warmStreams`, `_idsByHash`, `_streaming` stale. It matches the live torrent by `savePath == path`, which can fail on Windows (mixed separators, hash casing).
- Fix: add `Future<void> forget(String infoHash)` to `TorrentEngineService` that looks up `_idsByHash[infoHash.toLowerCase()]` and calls the existing `cleanup(id)`. Call it from `_deleteByPath`, then delete the directory if it still exists. Lowercase the hash in `deleteByInfoHash`.

#### S-M5 `BackgroundDownloadService.start()`/`stop()` race; permission prompt at the wrong moment

- Where: `background_download_service.dart:44-67`.
- Fix: keep a `bool _wanted` set synchronously by `start`/`stop`; serialise both through one future chain; re-check `_wanted` after each `await`. Remove `requestNotificationPermission()` from here (the player already asks in `_initMediaSession`).

#### S-M6 Search can hang for minutes

- Where: `torrent_index_service.dart:301` (`Dio()` with no `connectTimeout`), 341-358.
- Fix: `Dio(BaseOptions(connectTimeout: const Duration(seconds: 8), …))`, and a hard 30 s cap timer in `_gather` that completes regardless.

#### S-M7 File choice when the index gives no file index

- Where: `torrent_engine_service.dart:255, 479, 610-620`. `_findLargestVideoFile` returns the largest file of any type and ignores `FileInfo.isStreamable`.
- Fix: filter to `isStreamable` files; drop names matching `sample|trailer|extras` (case-insensitive); pick the largest of what remains; throw if none, so the fallback moves to the next copy.

#### S-M8 Ranking ignores codecs (needs device test)

- Where: `stream_resolver.dart:362-376, 536-580`. "Smallest healthy copy first" favours x265 10-bit and AV1 encodes, which are the hardest to decode. The S10 has no AV1 hardware decoder.
- Fix: add `int codecRank(TorrentStream s)` from the release name (`av1` worst; then `x265|hevc|h.?265` with `10.?bit`; `DV|DoVi|Dolby.?Vision` without `HDR`). Apply it in `_bestFirst` immediately before the size comparison. Start with AV1 demotion only, and widen after testing on the S10.

#### S-M9 Torrent data sits in backed-up storage

- Where: `torrent_paths.dart:11-14`; the manifest has no backup rules.
- Fix: Android — add `android:dataExtractionRules` and `android:fullBackupContent` excluding `torrents/` and `engine_state.dat`. iOS — set the exclude-from-backup attribute on the torrents folder.

### Low

- **S-L1** `lib/services/torrent/torrent_download_registry.dart:84-148`; `player_screen.dart:1299-1307`: the registry is never pruned and is rewritten every 5 s. In `enforceLimit`, remove registry keys with no directory on disk. Persist progress every 30 s plus on pause/dispose. (Same theme as A-M10.)
- **S-L2** `torrent_engine_service.dart:28-69, 684-697`: `init()` has no in-flight guard; `dispose()` leaves `_initialized = true`. Store `Future<void>? _initializing` and return it; in `dispose` reset `_initialized` and clear `_idsByHash`, `_streaming`, `_warmStreams`, `_connecting`.
- **S-L3** `stream_resolver.dart:685`: race losers stay in the session. Remove them with `removeTorrent(deleteFiles: false)` when they are not in the registry.
- **S-L4** `torrent_index_service.dart:161-163`: one malformed Torrentio entry discards the whole response. Wrap each `fromJson` in its own try and skip failures.
- **S-L5** `torrent_index_service.dart:373, 461`: Torrentio and apibay each have one hard-coded endpoint. Move the endpoint lists into the remote flags (`docs/flags.json`) with the current values as defaults.
- **S-L6** `torrent_engine_service.dart:538-550`: the 6 MB mobile-data head-start cap overshoots (checked every 500 ms at up to 10 MB/s) and the network type is sampled once. Set a download rate limit of 1 MB/s for head starts on mobile data and re-check the network type on each tick.

### Checked and found sound (do not change)

- `_waitForMetadata` and `resolveWithFallback` are bounded and clean up their subscriptions.
- `connect()` shares one future among concurrent callers.
- Queries and tracker URLs are encoded.
- Torrents are paused (not seeding) after a normal player close.
- `DownloadAheadSettings` is honoured in `warmUp`.
- Foreground-service permissions are declared correctly for SDK 34+.

### Not verified

- Whether libtorrent normalises `save_path` on Windows (affects S-M4).
- Android 15 `dataSync` timeout behaviour with this plugin version.
- iOS: whether the local stream server survives suspend/resume.

## 4. App shell, web player, secrets, build

Files: `lib/main.dart`, `lib/screens/details_screen.dart`, `lib/screens/web_player/*`, `lib/services/*` (non-torrent), `android/`, `ios/`, `../../codemagic.yaml`, `../../.github/workflows/`.

### High

#### A-H1 ✔ Android release builds are signed with the debug key

- Where: `android/app/build.gradle.kts:37` (`signingConfig = signingConfigs.getByName("debug")`); `../../codemagic.yaml:19` builds `--release` with no keystore.
- Scenario: an APK built on Codemagic or another PC has a different signature from the installed one. The in-app update fails to install, and the user must uninstall and loses history and favourites.
- Fix:
  1. The owner creates one release keystore and keeps it out of git. **This step needs the owner; do not generate a keystore unprompted.**
  2. In `build.gradle.kts`, load `android/key.properties` if it exists, define `signingConfigs.create("release")` from it, and use it in `buildTypes.release`. Fall back to debug only when the file is absent.
  3. Add `android/key.properties` and `*.jks` to `.gitignore`.
  4. In Codemagic, add the keystore under `android_signing` and write `key.properties` from environment variables.
- Note for the owner: the first build signed with the new key will itself require one uninstall/reinstall for existing users.

#### A-H2 ✔ `main()` can throw before `runApp`, leaving a blank window; no global error handlers

- Where: `lib/main.dart:80-86` — six unguarded awaits (`WindowFullScreen.init`, `SavedMoviesService().init`, `AppModeService().init`, `FeatureFlagsService().init`, `VisualEffectsService().init`, `DownloadAheadSettings().init`). No `FlutterError.onError`, `PlatformDispatcher.instance.onError`, `runZonedGuarded` or `ErrorWidget.builder` anywhere in `lib/`.
- Scenario (Windows): history JSON is rewritten every ~5 s during playback. A crash or power cut mid-write truncates the prefs file; `SharedPreferences.getInstance()` then throws on every launch and the app shows an empty window until the file is deleted by hand. (Code path confirmed; the truncation was not reproduced.)
- Fix:
  1. Wrap each init in its own `try { … } catch (e, s) { debugPrint('init failed: $e\n$s'); }` so `runApp` always runs. Each service must have safe defaults when its init failed.
  2. On Windows, if `SharedPreferences.getInstance()` throws `FormatException`, rename the prefs file to `.bak` and retry once.
  3. At the top of `main`, set `FlutterError.onError` and `PlatformDispatcher.instance.onError = (e, s) { debugPrint(...); return true; }`.
  4. In release mode, set `ErrorWidget.builder` to a small "Something went wrong" widget.

#### A-H3 ✔ TMDB and OMDB keys are committed and bundled; the OMDB key is unused

- Where: `.env` (tracked in git; keys `TMDB_API_KEY`, `OMDB_API_KEY`), `pubspec.yaml` assets (`- .env`), `lib/services/tmdb_service.dart:40`. `OMDB_API_KEY` is referenced nowhere in `lib/`.
- Risk: neither key is billable, but if the TMDB key is abused and suspended, every browse/search call fails for all users until a new build ships.
- Fix:
  1. Delete the `OMDB_API_KEY` line. **Owner action:** revoke that key at OMDB and rotate the TMDB key.
  2. Read the TMDB key from `String.fromEnvironment('TMDB_API_KEY')` and pass it by `--dart-define` the same way the Gemini key already is (see `codemagic.yaml`). Remove `flutter_dotenv` usage, `git rm --cached .env`, add `.env` to `.gitignore`, remove it from pubspec assets.
  3. Optional, for rotation without a release: let `docs/flags.json` carry a `tmdb_key` override that `TMDBService._apiKey` prefers when present.
- The Gemini key is handled correctly (git-ignored `secrets.json`, `--dart-define`). **Owner action:** restrict it to the Generative Language API and keep billing disabled on that Google project.

### Medium

#### A-M1 ✔ Web player redirect blocking is weak on mobile and absent on Windows

- Where: `lib/screens/web_player/web_player_mobile.dart:367-403` (381: `host.contains(initialHost) || initialHost.contains(host)`; 396-397: allows any host containing `cdn`/`stream`/`cache`/`cloud`; also allows any URL ending in a media extension). `web_player_windows.dart:41-59` has no main-frame navigation restriction.
- Problem: substring matching lets `vidlink.pro.evil.com` through; an empty host passes because `"x".contains("")` is true; `Uri.parse` can throw inside the callback.
- Fix (mobile): replace the checks with
  `final u = Uri.tryParse(request.url); if (u == null || u.scheme != 'https' || u.host.isEmpty) return NavigationDecision.prevent; final h = u.host.toLowerCase(); final ok = h == initialHost || h.endsWith('.$initialHost') || _providerHosts.contains(h);`
  where `_providerHosts` is an explicit per-provider set. Remove the keyword and file-extension rules. Apply only to main-frame navigations.
- Fix (Windows): listen to `_controller.url`; when the host leaves the allow-list, call `_controller.loadUrl(widget.initialUrl)`.
- Reachability: the web player is currently behind flags that are `false`, plus the player fallbacks at `player_screen.dart:1981` and `:2025`. Lower priority while those stay off.

#### A-M2 The JavaScript channel trusts messages from any frame

- Where: `web_player_mobile.dart:325-363`; `web_player_windows.dart:202-251`.
- Problem: `data['season'] as int`, `data['episode'] as int` and `currentTime / duration` from the page go straight into `SavedMoviesService().addToHistory`. Any ad iframe can write arbitrary history entries in a loop.
- Fix: ignore `season`/`episode` from the page and use the Dart-side `_currentSeason`/`_currentEpisode`. Compute `p = currentTime / duration`; drop the message unless `p.isFinite && p >= 0 && p <= 1`. Throttle saves to one per 4 s on mobile (Windows already does).

#### A-M3 Backup import wipes everything before validating

- Where: `lib/services/backup_service.dart:56-79`; `lib/services/saved_movies_service.dart:155-171, 184`; `lib/models/movie.dart:171-190`.
- Scenario: the user picks the wrong `.json`. All data is cleared and replaced with junk, and the import reports success. A malformed history entry then makes `SavedMoviesService().history` throw on every home-screen build.
- Fix:
  1. On export add `"_popcorn_backup": 1`. On import, before `prefs.clear()`, require that marker or at least one of `favorites_v1` / `watch_history_v1`; otherwise return an error.
  2. Write only keys matching the known names/prefixes with the expected types.
  3. Snapshot old values first and restore them if any write throws.
  4. Make `Movie.fromStorageJson` tolerant: `id: '${json['id']}'`, `year: (json['year'] as num?)?.toInt() ?? 0`, etc.
  5. In `history`, `init()` and `getMovieFromHistory`, skip entries that fail to parse instead of throwing.
  6. Call `FeatureFlagsService().init()` after import.

#### A-M4 History, progress and favourites are keyed by TMDB id alone

- Where: `saved_movies_service.dart:101-103, 109-117, 183, 232, 241`; `tmdb_service.dart:537`; `details_screen.dart:851, 1116, 2113-2115`.
- Problem: TMDB movie ids and TV ids are separate number spaces. Movie #1399 and show #1399 share progress, favourite state and Continue Watching.
- Fix: add `String get storageKey => '${type}_$id'` to `Movie`; use it for the history map, episode keys, the favourites check and the last-played fallback. Add a one-time migration in `SavedMoviesService.init()` that re-keys existing entries using the stored `movie.type`, guarded by a `storage_key_migrated_v1` flag. **Test the migration against a real backup before shipping; a bug here loses user history.**

#### A-M5 Web player resumes the new episode at the old episode's position

- Where: `web_player_mobile.dart:431-444`, `583-629`.
- Fix: in `onPageFinished`, look up progress with `_currentSeason`/`_currentEpisode` instead of `widget.season`/`widget.episode`. In `_switchEpisode`, set `_ignoreProgressUntilLoaded = true`, honoured by the channel handler and cleared in `onPageStarted` of the new URL. Add `if (!mounted) return;` after the `await` at ~603.

#### A-M6 ✔ Cleartext HTTP is allowed app-wide

- Where: `android/app/src/main/AndroidManifest.xml:15` (`usesCleartextTraffic="true"`); `ios/Runner/Info.plist:74-78` (`NSAllowsArbitraryLoads`).
- Fix: Android — remove the attribute; add `res/xml/network_security_config.xml` permitting cleartext for `127.0.0.1` and `localhost` only and reference it from the manifest. iOS — replace `NSAllowsArbitraryLoads` with `NSAllowsLocalNetworking = true`.
- Needs device test: confirm torrent playback (served from `http://127.0.0.1`) and external subtitle downloads still work on both platforms.

#### A-M7 Deep links bypass the maintenance/update screens and trigger torrent warm-up

- Where: `lib/services/deep_link_service.dart:42-71`; `lib/main.dart:166`; `details_screen.dart:424-442, 571-581`.
- Problem: `popcorn://details?id=…&type=…` pushes `DetailsScreen` on the root navigator regardless of app state; `id`/`type` are not validated; opening a movie page runs `_warmUpMovie`, which joins the swarm without a tap.
- Fix:
  1. Validate `RegExp(r'^\d{1,9}$').hasMatch(id)` and `type == 'movie' || type == 'tv'`; drop the link otherwise.
  2. Expose a `ValueNotifier<bool> appReady` from `_MyAppState` (true only past splash/onboarding and not on maintenance/update). Queue the link until true; drop it on maintenance or forced update.
  3. Add `fromDeepLink` to `DetailsScreen` and skip `_warmUpMovie` when set.

#### A-M8 Remote flags: stale lock with no retry; changes not applied on resume

- Where: `lib/services/feature_flags_service.dart:62-91`; `lib/main.dart:188-190, 215-246`; `lib/screens/update_overlay.dart:27`.
- Fix: on `AppLifecycleState.resumed`, `await refreshIfStale()` then re-run the maintenance/update part of `_checkConfig` (both directions). Add a "Try again" button to `MaintenanceOverlay`. In `UpdateOverlay`, use `Uri.tryParse` and require `https`.

#### A-M9 TV "Resume" button has no in-flight guard; season loads can arrive out of order

- Where: `details_screen.dart:703-732, 1565-1615, 1860-1870`.
- Fix: add a `bool _resuming` guard (set, `try/finally` clear) and `if (!mounted) return;` after the await. In `_loadSeasonDetails`, use `final token = ++_seasonRequest;` and apply results only when `token == _seasonRequest && mounted`.

#### A-M10 Stored history grows without limit and is fully rewritten every 5 seconds

- Where: `saved_movies_service.dart:232-245, 271-279`; `streaming_link_service.dart:205-211`.
- Fix: cap history at 200 titles (evict oldest `last_watched` and its episode keys). Debounce `_saveHistory` to once per 15 s with a flush on app pause and player dispose. Store the Wikidata id cache as one JSON map capped at 300 entries.
- This also shrinks the corruption window described in A-H2.

### Low

- **A-L1** Double-tap windows in quality pickers. `details_screen.dart:2188-2212`: set `_startingOption` before the first `await` (or return early if it is non-null). `lib/widgets/episode_browser.dart:617-630` (`_choose`): add a `_choosing` flag and a `mounted` check.
- **A-L2** `tmdb_service.dart:358-381`: the movie→TV fallback fires on any error. Fall through only on HTTP 404 and reject unknown types.
- **A-L3** `tmdb_service.dart:1053-1064`: hard casts on episode `name`/`overview`. Use `as String? ?? 'Episode $n'` / `?? ''`.
- **A-L4** `tmdb_service.dart:37`: `_cache` never evicts. Cap at 200 entries, oldest first. Add one retry with backoff on HTTP 429.
- **A-L5** `ai_service.dart:113, 136, 147-157, 211-212, 255`: add `connectTimeout: 10s`; add a generic `catch (_)` that moves on to the next model; count the question against the daily limit only after a model answers.
- **A-L6** `details_screen.dart:540`: `rethrow` inside un-awaited `_loadDetails` becomes an unhandled async error. Remove the rethrow; the error state is already set.
- **A-L7** `web_player_mobile.dart:678-679`: `PopScope(canPop: false)` has no handler, so Android back does nothing. Add `onPopInvokedWithResult: (didPop, _) { if (!didPop) widget.onClose(); }`.
- **A-L8** Android manifest: add `android:maxSdkVersion="32"` to `READ_EXTERNAL_STORAGE`; drop `requestLegacyExternalStorage`. The foreground service declares only `dataSync` (Android 15 caps that at 6 h/day) although `FOREGROUND_SERVICE_MEDIA_PLAYBACK` is requested — see section 3 before changing.
- **A-L9** `android/app/proguard-rules.pro:11-12`: the `com.libtorrent.**` rules match nothing. Harmless; remove.

### CI and repo hygiene

- **A-C1** ✔ Tracked files to remove with `git rm --cached` and add to `.gitignore`: `diff.txt`, `diff_utf8.txt`, `android/build/`, `lib/temp_source.html`, `lib/temp_source_iframe.html`, `lib/temp_source_prorcp.html` (unreferenced; delete from disk too), `.env` (see A-H3).
- **A-C2** `../../codemagic.yaml:89-111` and `../../.github/workflows/build-flutter.yml:43-56` build macOS, but there is no `macos/` folder. Remove those jobs.
- **A-C3** `build-flutter.yml` triggers only on branch `flutter-migration` and uses unpinned Flutter. Trigger on `main`, pin 3.44.6, update to `actions/checkout@v4`.
- **A-C4** `codemagic.yaml:22` lists an `.aab` artifact that is never built. Remove.
- **A-C5** No `flutter analyze` or `flutter test` in CI. Add both. Six real tests (subtitle and skip-segment) exist on disk but are untracked; `git add` them and delete the placeholder `test/widget_test.dart`.

### Checked and found sound (do not change)

- Splash cannot hang (all fetches time-limited with fallbacks).
- Feature-flag parsing is type-checked with defaults and fails open on garbage.
- Streaming-service links: hard-coded hosts, app-only launch (`externalNonBrowserApplication`) with a message on failure.
- Details screen cancels its request on dispose and checks `mounted` after awaits in its main loaders.
- No keystore or `secrets.json` has ever been committed.

### Not verified

- Whether a minified release build runs (no build was performed).
- Native WebView defaults for file access and mixed content.
- Whether Dio error text printed by `print('TMDB … Error: $e')` includes the `api_key` query parameter in device logs. If it does, strip it.
