import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dart:convert';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'dart:io';
import 'dart:async';
import 'web_player_platform_interface.dart';
import '../../services/saved_movies_service.dart';
import '../../widgets/custom_loader.dart';

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
  });

  @override
  State<WebPlayerMobile> createState() => _WebPlayerMobileState();
}

class _WebPlayerMobileState extends State<WebPlayerMobile> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _showControls = false;
  bool _isVideoPaused = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _setupController();
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

    // Delay orientation change to next frame so it doesn't race with
    // the widget tree build and WKWebView initialization.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    });

    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel(
        'FlutterControlChannel',
        onMessageReceived: (JavaScriptMessage message) {
          try {
            if (message.message == 'playing') {
              setState(() => _isVideoPaused = false);
              _startHideTimer();
              return;
            } else if (message.message == 'paused') {
              setState(() {
                _isVideoPaused = true;
                _showControls = true;
              });
              _hideTimer?.cancel();
              return;
            }

            // JSON progress updates
            final dynamic data = jsonDecode(message.message);
            if (data is Map) {
              if (data['type'] == 'pause') {
                final double currentTime =
                    (data['currentTime'] as num).toDouble();
                final double duration = (data['duration'] as num).toDouble();
                if (duration > 60 && mounted) {
                  SavedMoviesService().addToHistory(
                    widget.movie,
                    season: widget.season,
                    episode: widget.episode,
                    progress: currentTime / duration,
                  );
                }
              } else if (data['type'] == 'timeupdate') {
                final double currentTime =
                    (data['currentTime'] as num).toDouble();
                final double duration = (data['duration'] as num).toDouble();
                if (duration > 60 && mounted) {
                  SavedMoviesService().addToHistory(
                    widget.movie,
                    season: widget.season,
                    episode: widget.episode,
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
            final host = Uri.parse(request.url).host;
            final initialHost = Uri.parse(widget.initialUrl).host;
            if (host.contains(initialHost) || initialHost.contains(host)) {
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
              setState(() {
                _isLoading = true;
                _showControls = true;
              });
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
              setState(() {
                _isLoading = false;
                _showControls = true;
              });
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
    setState(() {
      _showControls = true;
    });
    if (!_isVideoPaused) {
      _startHideTimer();
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_isVideoPaused) {
        setState(() => _showControls = false);
      }
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ---------------------------------------------------------------
          // WebViewWidget sits directly in the tree — NO Listener wrapper.
          // On iOS, wrapping the WebView in a Listener intercepted every
          // touch before WKWebView could process it, creating a gesture
          // conflict that triggered native fullscreen at the platform level.
          // ---------------------------------------------------------------
          WebViewWidget(controller: _controller),

          // Transparent overlay that toggles close-button visibility.
          // Uses a raw Listener instead of GestureDetector so it does NOT
          // enter the gesture arena — the WebView keeps full touch control.
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _toggleControls(),
            ),
          ),

          if (_isLoading)
            const Center(
              child: CustomLoader(),
            ),
          Positioned(
            top: 20,
            left: 20,
            child: AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: SafeArea(
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: _showControls ? widget.onClose : null,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
