import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import 'dart:convert';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'dart:io';
import 'dart:async';
import 'web_player_platform_interface.dart';
import '../../models/movie.dart';
import '../../services/saved_movies_service.dart';
import '../../services/scraper_service.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/player_gesture_overlay.dart';
import '../../widgets/episode_drawer.dart';
import 'package:sensors_plus/sensors_plus.dart';

// ---------------------------------------------------------------------------
// Fullscreen-suppression JS injected in both onPageStarted and onPageFinished.
//
// WHY TWO PASSES?
//   • onPageStarted fires early — before most page JS runs — so our prototype
//     overrides are often in place before the embed player caches them.
//   • onPageFinished is a belt-and-suspenders pass that also sets up progress
//     tracking once the DOM / video element is available.
//
// WHY NOT WKUserScript.atDocumentStart?
//   The webview_flutter_wkwebview Dart API does not expose addUserScript on
//   WebKitWebViewController; the method lives on WKUserContentController which
//   is a lower-level Swift class not surfaced to Dart in this package version.
// ---------------------------------------------------------------------------
const String _kFullscreenSuppressJs = r"""
(function() {
  'use strict';

  // --- 1. Override fullscreen APIs on prototypes ---
  // Using Object.defineProperty (configurable:true allows us to re-run safely).
  function noop() { return Promise.resolve(); }
  function defineNoop(obj, prop) {
    try {
      Object.defineProperty(obj, prop, {
        value: noop, writable: true, configurable: true
      });
    } catch(e) {}
  }

  defineNoop(Element.prototype,             'requestFullscreen');
  defineNoop(Element.prototype,             'webkitRequestFullscreen');
  defineNoop(HTMLVideoElement.prototype,    'webkitEnterFullscreen');

  // webkitSetPresentationMode is the main iOS API for fullscreen/pip/inline
  try {
    Object.defineProperty(HTMLVideoElement.prototype, 'webkitSetPresentationMode', {
      value: function(mode) { /* ignore fullscreen & pip; only inline allowed */ },
      writable: true, configurable: true
    });
  } catch(e) {}

  // Report fullscreen as unsupported so players don't even try
  try { Object.defineProperty(document, 'fullscreenEnabled',       { get: function(){ return false; }, configurable: true }); } catch(e) {}
  try { Object.defineProperty(document, 'webkitFullscreenEnabled', { get: function(){ return false; }, configurable: true }); } catch(e) {}

  // --- 2. Exit fullscreen immediately if it still somehow fires ---
  document.addEventListener('fullscreenchange', function() {
    if (document.fullscreenElement) { try { document.exitFullscreen(); } catch(e) {} }
  }, true);
  document.addEventListener('webkitfullscreenchange', function() {
    if (document.webkitFullscreenElement) { try { document.webkitExitFullscreen(); } catch(e) {} }
  }, true);

  // --- 3. Helper: enforce inline on a single video element ---
  function enforceInline(video) {
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    defineNoop(video, 'webkitEnterFullscreen');
    defineNoop(video, 'requestFullscreen');
    defineNoop(video, 'webkitRequestFullscreen');
    try {
      Object.defineProperty(video, 'webkitSetPresentationMode', {
        value: function(mode) {}, writable: true, configurable: true
      });
    } catch(e) {}
  }

  // Apply to videos already in DOM
  (document.querySelectorAll('video') || []).forEach(enforceInline);

  // --- 4. MutationObserver: catch videos added after initial parse ---
  if (window._flutterFullscreenObserver) return; // already running
  window._flutterFullscreenObserver = new MutationObserver(function(mutations) {
    mutations.forEach(function(m) {
      m.addedNodes.forEach(function(node) {
        if (node.nodeType !== 1) return;
        if (node.tagName === 'VIDEO') {
          enforceInline(node);
        } else if (node.querySelectorAll) {
          node.querySelectorAll('video').forEach(enforceInline);
        }
      });
    });
  });
  window._flutterFullscreenObserver.observe(
    document.documentElement, { childList: true, subtree: true }
  );

  // --- 5. CSS: hide native fullscreen button; keep video contained ---
  if (!window._flutterFullscreenStyle) {
    var s = document.createElement('style');
    s.textContent =
      'video { object-fit: contain !important; }' +
      '::-webkit-media-controls-fullscreen-button { display: none !important; }';
    (document.head || document.documentElement).appendChild(s);
    window._flutterFullscreenStyle = true;
  }

  // --- 6. Block Media Session Details (Notification Screen) ---
  // Overrides the lock screen / control center media details so it
  // doesn't leak the scraper URL or show ugly details.
  if ('mediaSession' in navigator) {
    try {
      navigator.mediaSession.metadata = new MediaMetadata({
        title: 'Popcorn',
        artist: 'Playing Video',
        album: '',
        artwork: []
      });
      // Optionally block play/pause from lock screen overriding our state
      // navigator.mediaSession.setActionHandler('pause', function() {});
      // navigator.mediaSession.setActionHandler('play', function() {});
    } catch(e) {}
  }

  // --- 7. iOS viewport fix ---
  // WKWebView often renders embed pages at desktop scale, making buttons
  // tiny. Inject a proper viewport meta tag so content fills the screen
  // at device-native resolution.
  (function() {
    var existing = document.querySelector('meta[name="viewport"]');
    if (!existing) {
      var meta = document.createElement('meta');
      meta.name = 'viewport';
      meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
      (document.head || document.documentElement).appendChild(meta);
    } else {
      existing.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
    }
  })();
})();
""";

class WebPlayerMobile extends WebPlayerPlatform {
  const WebPlayerMobile({
    super.key,
    required super.initialUrl,
    required super.onClose,
    required super.movie,
    super.season,
    super.episode,
    super.episodes,
    List<Season>? seasons,
    required Movie details,
  }) : super(
          seasons: seasons,
          details: details,
        );

  @override
  State<WebPlayerMobile> createState() => _WebPlayerMobileState();
}

class _WebPlayerMobileState extends State<WebPlayerMobile>
    with WidgetsBindingObserver {
  late final WebViewController _controller;
  bool _isLoading = true;
  Timer? _hideTimer;

  // Use ValueNotifiers so toggling controls doesn't rebuild the WebView
  // platform view — which on iOS WKWebView causes black-screen flashes.
  final ValueNotifier<bool> _showControls = ValueNotifier(false);
  final ValueNotifier<bool> _isVideoPaused = ValueNotifier(false);
  final ValueNotifier<bool> _showEpisodeDrawer = ValueNotifier(false);

  // What's actually loaded in the WebView
  late int _currentSeason;
  late int _currentEpisode;
  // What season the drawer is currently browsing (may differ from playing)
  late int _browsingSeason;
  late List<Episode> _episodes;

  // YouTube-style continuous gyro rotation
  StreamSubscription? _accelSubscription;
  DeviceOrientation _currentOrientation = DeviceOrientation.landscapeLeft;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    _currentSeason = widget.season ?? 1;
    _currentEpisode = widget.episode ?? 1;
    _browsingSeason = _currentSeason;
    _episodes = widget.episodes;
    
    _setupController();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // When the app goes to the background, pause video elements so WKWebView
      // does not keep playing audio in the background.
      _controller.runJavaScript(
          "document.querySelectorAll('video').forEach(function(v) { try { v.pause(); } catch(e){} });"
      );
    }
  }

  void _setupController() {
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    _controller = WebViewController.fromPlatformCreationParams(params);

    // Android: disable gesture requirement for autoplay
    if (Platform.isAndroid &&
        _controller.platform is AndroidWebViewController) {
      final androidController =
          _controller.platform as AndroidWebViewController;
      androidController.setMediaPlaybackRequiresUserGesture(false);
    }

    // iOS: extra hardening via the platform-specific controller
    if (Platform.isIOS &&
        _controller.platform is WebKitWebViewController) {
      final iosController =
          _controller.platform as WebKitWebViewController;
      // Disable back-forward swipe gestures — they can trigger native
      // view controller transitions that break inline playback.
      iosController.setAllowsBackForwardNavigationGestures(false);
    }

    // --- System UI & Orientation ---
    // On Android: immersiveSticky works perfectly with platform views.
    // On iOS: DO NOT use manual/immersiveSticky — both rip out system UI
    // overlays which conflicts with WKWebView's view controller hierarchy,
    // causing black screen flashes. Use edgeToEdge instead, which keeps
    // the status bar area but makes it transparent.
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }

    // --- YouTube-style continuous gyro rotation ---
    // Force landscape immediately, then continuously monitor the accelerometer
    // to auto-rotate between landscapeLeft and landscapeRight even when the
    // OS auto-rotate lock is ON.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _accelSubscription = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 500),
    ).listen((event) {
      if (!mounted) return;

      // Determine which landscape the phone is physically in:
      // x < -4 => phone top pointing right => landscapeRight
      // x >  4 => phone top pointing left  => landscapeLeft
      // |x| <= 4 => ambiguous / in-between, keep current
      DeviceOrientation? detected;
      if (event.x < -4.0) {
        detected = DeviceOrientation.landscapeRight;
      } else if (event.x > 4.0) {
        detected = DeviceOrientation.landscapeLeft;
      }

      if (detected != null && detected != _currentOrientation) {
        _currentOrientation = detected;
        SystemChrome.setPreferredOrientations([detected]);

        // After rotating, unlock both landscape directions so that
        // subsequent tilts are picked up naturally by the OS too.
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) {
            SystemChrome.setPreferredOrientations([
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]);
          }
        });
      }
    }, onError: (_) {
      // Sensors unavailable — just allow both landscape directions
      if (mounted) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    });

    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel(
        'FlutterControlChannel',
        onMessageReceived: (JavaScriptMessage message) {
          try {
            if (message.message == 'playing') {
              _isVideoPaused.value = false;
              _startHideTimer();
              return;
            } else if (message.message == 'paused') {
              _isVideoPaused.value = true;
              _showControls.value = true;
              _hideTimer?.cancel();
              return;
            }

            // JSON progress updates
            final dynamic data = jsonDecode(message.message);
            if (data is Map) {
              if (data['type'] == 'pause' || data['type'] == 'timeupdate') {
                final double currentTime =
                    (data['currentTime'] as num).toDouble();
                final double duration = (data['duration'] as num).toDouble();
                final int s = data.containsKey('season') ? data['season'] as int : _currentSeason;
                final int e = data.containsKey('episode') ? data['episode'] as int : _currentEpisode;

                if (duration > 60 && mounted) {
                  SavedMoviesService().addToHistory(
                    widget.movie,
                    season: s,
                    episode: e,
                    progress: currentTime / duration,
                  );
                }
              }
            }
          } catch (e) {
            // Ignore parse errors
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            // Allow all sub-frame loads (iframes, sub-resources).
            // iOS WKWebView fires this for iframe navigations that
            // Android WebView handles silently. Blocking them breaks
            // embed players that load content via nested iframes.
            if (!request.isMainFrame) {
              return NavigationDecision.navigate;
            }

            final uri = Uri.parse(request.url);
            final host = uri.host;
            final initialHost = Uri.parse(widget.initialUrl).host;

            // Same-origin — always allow
            if (host.contains(initialHost) || initialHost.contains(host)) {
              return NavigationDecision.navigate;
            }

            // Allow media/streaming URLs.
            // iOS WKWebView can report HLS manifest or direct video
            // fetches as navigation events (Android does not).
            final path = uri.path.toLowerCase();
            if (path.endsWith('.m3u8') || path.endsWith('.mp4') ||
                path.endsWith('.ts') || path.endsWith('.webm') ||
                path.endsWith('.mpd')) {
              return NavigationDecision.navigate;
            }

            // Allow common CDN/streaming sub-domains
            if (host.contains('cdn') || host.contains('stream') ||
                host.contains('cache') || host.contains('cloud')) {
              return NavigationDecision.navigate;
            }

            debugPrint('Blocking redirect to: ${request.url}');
            return NavigationDecision.prevent;
          },

          // ----------------------------------------------------------------
          // onPageStarted: EARLIEST available Dart callback.
          // Inject fullscreen suppression here so it runs before most of the
          // embed player's own JavaScript.
          // ----------------------------------------------------------------
          onPageStarted: (String url) {
            if (mounted) {
              setState(() => _isLoading = true);
              _showControls.value = true;
              _startHideTimer();
            }
            // Inject fullscreen-suppression as early as possible
            _controller.runJavaScript(_kFullscreenSuppressJs);
          },

          // ----------------------------------------------------------------
          // onPageFinished: set up progress tracking + re-run suppression
          // for any content loaded dynamically after page start.
          // ----------------------------------------------------------------
          onPageFinished: (String url) {
            if (mounted) {
              setState(() => _isLoading = false);
              _showControls.value = true;
              _startHideTimer();
            }

            // Get saved progress for resume
            double startProgress = 0.0;
            final service = SavedMoviesService();
            if (widget.season != null && widget.episode != null) {
              startProgress = service.getEpisodeProgress(
                    widget.movie.id,
                    widget.season!,
                    widget.episode!,
                  ) ??
                  0.0;
            } else {
              final m = service.getMovieFromHistory(widget.movie.id);
              if (m != null) startProgress = m.progress ?? 0.0;
            }

            // Re-run fullscreen suppression (belt-and-suspenders), then set
            // up play/pause events and progress tracking.
            _controller.runJavaScript("""
$_kFullscreenSuppressJs

window.flutterPlayerStartProgress = $startProgress;

if (window.flutterTrackingActive) {
  console.log('Tracking active, progress -> ' + ($startProgress * 100) + '%');
} else {
  window.flutterTrackingActive = true;

  window.addEventListener('play',  function() { FlutterControlChannel.postMessage('playing'); }, true);
  window.addEventListener('pause', function() { FlutterControlChannel.postMessage('paused');  }, true);

  function findVideo() {
    var v = document.querySelector('video');
    if (v) return v;
    var all = document.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      if (all[i].shadowRoot) {
        v = all[i].shadowRoot.querySelector('video');
        if (v) return v;
      }
    }
    return null;
  }

  function setupTracking() {
    var video = findVideo();
    if (!video) { setTimeout(setupTracking, 1000); return; }

    console.log('Flutter: video found, tracking active');
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');

    var hasResumed = false;
    function resume() {
      var p = window.flutterPlayerStartProgress || 0;
      if (hasResumed || p < 0.01 || p > 0.95) return;
      if (video.duration && isFinite(video.duration)) {
        video.currentTime = p * video.duration;
        hasResumed = true;
        console.log('Flutter: resumed to ' + video.currentTime + 's');
      }
    }
    if (video.readyState >= 1) { setTimeout(resume, 500); }
    else { video.addEventListener('loadedmetadata', function(){ setTimeout(resume, 500); }, { once: true }); }

    var lastSave = 0;
    video.addEventListener('timeupdate', function() {
      var now = Date.now();
      if (now - lastSave > 5000 && video.duration > 60) {
        lastSave = now;
        FlutterControlChannel.postMessage(JSON.stringify({
          type: 'timeupdate',
          currentTime: video.currentTime,
          duration: video.duration
        }));
      }
    });

    video.addEventListener('pause', function() {
      if (video.duration > 60) {
        FlutterControlChannel.postMessage(JSON.stringify({
          type: 'pause',
          currentTime: video.currentTime,
          duration: video.duration
        }));
      }
    });
  }

  setupTracking();
}
""");

            // iOS: Third-pass delayed re-injection.
            // Some embed players set up their video elements 2-5s after
            // the page "finishes" loading. Our MutationObserver catches
            // new <video> tags, but prototype overrides may have been
            // replaced by the player's own JS. Re-apply after a delay.
            if (Platform.isIOS) {
              Future.delayed(const Duration(seconds: 3), () {
                if (mounted) {
                  _controller.runJavaScript(_kFullscreenSuppressJs);
                }
              });
              Future.delayed(const Duration(seconds: 6), () {
                if (mounted) {
                  _controller.runJavaScript(_kFullscreenSuppressJs);
                }
              });
            }
          },

          onWebResourceError: (WebResourceError error) {
            debugPrint(
                'WebView error for url ${widget.initialUrl}: ${error.description} (code: ${error.errorCode}, type: ${error.errorType})');
          },
        ),
      )
      // Use Chrome user agent on BOTH platforms.
      // Safari UA makes embed players trigger native iOS fullscreen.
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',
      )
      ..loadRequest(
        Uri.parse(widget.initialUrl),
      );
  }

  void _toggleControls() {
    _showControls.value = true;
    if (!_isVideoPaused.value) {
      _startHideTimer();
    }
  }

  void _toggleEpisodeDrawer() {
    _showEpisodeDrawer.value = !_showEpisodeDrawer.value;
    if (_showEpisodeDrawer.value) {
      _showControls.value = false;
      // Reset drawer to show the currently-playing season
      if (_browsingSeason != _currentSeason) {
        _browsingSeason = _currentSeason;
        _episodes = widget.episodes;
        // Re-fetch in case episodes changed
        TMDBService().getSeasonDetails(widget.details.id, _currentSeason).then((eps) {
          if (mounted && _showEpisodeDrawer.value) {
            setState(() => _episodes = eps);
          }
        });
      }
    }
  }

  Future<void> _switchEpisode(int episodeNumber) async {
    // 1. Save current progress of old episode before switching
    final oldSeason = _currentSeason;
    final oldEpisode = _currentEpisode;
    
    await _controller.runJavaScript("""
      (function() {
        var v = document.querySelector('video');
        if (v && v.duration > 60) {
          FlutterControlChannel.postMessage(JSON.stringify({
            type: 'pause',
            currentTime: v.currentTime,
            duration: v.duration,
            season: $oldSeason,
            episode: $oldEpisode
          }));
        }
      })();
    """);

    setState(() {
      // Update both playing and browsing state
      _currentSeason = _browsingSeason;
      _currentEpisode = episodeNumber;
      _isLoading = true;
    });
    _showEpisodeDrawer.value = false;

    // 2. Generate new URL
    final newUrl = ScraperService().getEmbedUrl(
      widget.details.id,
      season: _currentSeason,
      episode: _currentEpisode,
      imdbId: widget.details.imdbId,
      provider: Platform.isIOS ? 'vsembed' : 'vidlink',
    );

    // 3. Load new URL
    _controller.loadRequest(Uri.parse(newUrl));
    
    // 4. Update history
    SavedMoviesService().addToHistory(
      widget.movie,
      season: _currentSeason,
      episode: _currentEpisode,
    );
  }

  Future<void> _switchSeason(int seasonNumber) async {
    // Only update browsing state — don't change what's playing
    setState(() => _isLoading = true);
    
    final episodes = await TMDBService().getSeasonDetails(
      widget.details.id,
      seasonNumber,
    );

    if (mounted) {
      setState(() {
        _browsingSeason = seasonNumber;
        _episodes = episodes;
        _isLoading = false;
      });
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_isVideoPaused.value) {
        _showControls.value = false;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Load blank page to destroy media elements and stop background audio instantly
    _controller.loadRequest(Uri.parse('about:blank'));
    
    _accelSubscription?.cancel();
    _hideTimer?.cancel();
    _showControls.dispose();
    _isVideoPaused.dispose();
    _showEpisodeDrawer.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // Prevent iOS back-swipe from accidentally closing the player
      child: Scaffold(
      backgroundColor: Colors.black,
      // Use a top-level Stack so the EpisodeDrawer sits ABOVE and OUTSIDE
      // the PlayerGestureOverlay. This prevents drawer touches from
      // triggering volume/brightness gestures.
      body: Stack(
        children: [
          // Layer 1: PlayerGestureOverlay + WebView + controls
          ValueListenableBuilder<bool>(
            valueListenable: _showEpisodeDrawer,
            builder: (context, drawerOpen, child) {
              return PlayerGestureOverlay(
                enabled: !drawerOpen,
                onTap: _toggleControls,
                onSwipeUp: widget.movie.type == 'tv' ? _toggleEpisodeDrawer : null,
                child: Stack(
                  children: [
                    // WebView is NOT inside any ValueListenableBuilder —
                    // it never gets rebuilt when controls toggle.
                    WebViewWidget(
                      controller: _controller,
                      // EagerGestureRecognizer is needed on Android to prevent
                      // Flutter's navigation system from stealing horizontal
                      // drags (seeking). On iOS, it causes touch coordinates to
                      // misalign with WKWebView's internal hit-testing, making
                      // buttons un-tappable without zooming in first.
                      gestureRecognizers: Platform.isAndroid
                          ? {
                              Factory<OneSequenceGestureRecognizer>(
                                () => EagerGestureRecognizer(),
                              ),
                            }
                          : const <Factory<OneSequenceGestureRecognizer>>{},
                    ),

                    if (_isLoading)
                      const Center(
                        child: CustomLoader(),
                      ),

                    // Only the close button rebuilds on controls visibility change.
                    Positioned(
                      top: 20,
                      left: 20,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _showControls,
                        builder: (context, visible, child) {
                          return AnimatedOpacity(
                            opacity: visible ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 300),
                            child: SafeArea(
                              child: Container(
                                decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  icon: const Icon(Icons.close, color: Colors.white),
                                  onPressed: visible ? widget.onClose : null,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          // Layer 2: Episode Drawer (fully outside gesture overlay)
          ValueListenableBuilder<bool>(
            valueListenable: _showEpisodeDrawer,
            builder: (context, showDrawer, _) {
              if (!showDrawer || widget.movie.type != 'tv') {
                return const SizedBox.shrink();
              }
              return Positioned.fill(
                child: EpisodeDrawer(
                  episodes: _episodes,
                  seasons: widget.seasons,
                  movie: widget.details, // Use details to get logoUrl
                  currentSeason: _browsingSeason,
                  playingSeason: _currentSeason,
                  playingEpisode: _currentEpisode,
                  movieId: widget.movie.id,
                  onEpisodeTap: _switchEpisode,
                  onSeasonChanged: _switchSeason,
                  onClose: () => _showEpisodeDrawer.value = false,
                ),
              );
            },
          ),
        ],
      ),
    ),
  );
}
}
