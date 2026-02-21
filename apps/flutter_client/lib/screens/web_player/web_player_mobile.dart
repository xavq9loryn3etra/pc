import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_client/theme/app_theme.dart';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'web_player_platform_interface.dart';
import '../../services/saved_movies_service.dart';

// ---------------------------------------------------------------------------
// Fullscreen-suppression JS injected at AT_DOCUMENT_START via UserScript.
//
// This runs BEFORE any page JavaScript — so our prototype overrides are in
// place before any embed player caches the native fullscreen APIs.
// ---------------------------------------------------------------------------
const String _kFullscreenSuppressJs = r"""
(function() {
  'use strict';

  // --- 1. Override fullscreen APIs on prototypes ---
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

  try {
    Object.defineProperty(HTMLVideoElement.prototype, 'webkitSetPresentationMode', {
      value: function(mode) { /* only inline allowed */ },
      writable: true, configurable: true
    });
  } catch(e) {}

  // Report fullscreen as unsupported
  try { Object.defineProperty(document, 'fullscreenEnabled',       { get: function(){ return false; }, configurable: true }); } catch(e) {}
  try { Object.defineProperty(document, 'webkitFullscreenEnabled', { get: function(){ return false; }, configurable: true }); } catch(e) {}

  // --- 2. Exit fullscreen immediately if it still somehow fires ---
  document.addEventListener('fullscreenchange', function() {
    if (document.fullscreenElement) { try { document.exitFullscreen(); } catch(e) {} }
  }, true);
  document.addEventListener('webkitfullscreenchange', function() {
    if (document.webkitFullscreenElement) { try { document.webkitExitFullscreen(); } catch(e) {} }
  }, true);

  // --- 3. Enforce inline on video elements ---
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

  (document.querySelectorAll('video') || []).forEach(enforceInline);

  // --- 4. MutationObserver for dynamically added videos ---
  if (window._flutterFullscreenObserver) return;
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

  // --- 5. CSS: hide native fullscreen button ---
  if (!window._flutterFullscreenStyle) {
    var s = document.createElement('style');
    s.textContent =
      'video { object-fit: contain !important; }' +
      '::-webkit-media-controls-fullscreen-button { display: none !important; }';
    (document.head || document.documentElement).appendChild(s);
    window._flutterFullscreenStyle = true;
  }

  // --- 6. Suppress iOS Now Playing / notification panel ---
  if (navigator.mediaSession) {
    try {
      navigator.mediaSession.metadata = null;
      navigator.mediaSession.setActionHandler('play', null);
      navigator.mediaSession.setActionHandler('pause', null);
      navigator.mediaSession.setActionHandler('seekbackward', null);
      navigator.mediaSession.setActionHandler('seekforward', null);
      navigator.mediaSession.setActionHandler('previoustrack', null);
      navigator.mediaSession.setActionHandler('nexttrack', null);
      Object.defineProperty(navigator.mediaSession, 'metadata', {
        get: function() { return null; },
        set: function() {},
        configurable: true
      });
      Object.defineProperty(navigator.mediaSession, 'playbackState', {
        get: function() { return 'none'; },
        set: function() {},
        configurable: true
      });
    } catch(e) {}
  }

  // --- 7. Relay postMessage from iframes to Flutter ---
  // Tracking JS in iframes can't access flutter_inappwebview directly,
  // so it posts messages to parent. This listener forwards them.
  if (window === window.top) {
    window.addEventListener('message', function(event) {
      try {
        var d = event.data;
        if (d && d.flutter_handler && window.flutter_inappwebview) {
          window.flutter_inappwebview.callHandler(d.flutter_handler, d.flutter_data);
        }
      } catch(e) {}
    }, false);
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
  InAppWebViewController? _controller;
  bool _isLoading = true;
  bool _isVideoPaused = true; // starts true so close button is visible

  @override
  void initState() {
    super.initState();

    // Force landscape and hide system UI
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: [],
      );
    }
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    super.dispose();
  }

  /// Build the tracking JavaScript (play/pause events, progress save/resume).
  /// Uses postMessage to communicate from iframes to the main frame,
  /// where the flutter_inappwebview JS bridge is available.
  String _buildTrackingJs(double startProgress) {
    return """
window.flutterPlayerStartProgress = $startProgress;

if (window.flutterTrackingActive) {
  console.log('Tracking active, progress -> ' + (${startProgress} * 100) + '%');
} else {
  window.flutterTrackingActive = true;

  // Helper: send message to Flutter via the bridge or via postMessage to parent
  function toFlutter(handler, data) {
    try {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler(handler, data);
        return;
      }
    } catch(e) {}
    // Fallback: post to parent (for iframe contexts)
    try {
      window.parent.postMessage({ flutter_handler: handler, flutter_data: data }, '*');
    } catch(e) {}
  }

  window.addEventListener('play',  function() { toFlutter('onPlayPause', 'playing'); }, true);
  window.addEventListener('pause', function() { toFlutter('onPlayPause', 'paused');  }, true);

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
        toFlutter('onProgress', JSON.stringify({
          type: 'timeupdate',
          currentTime: video.currentTime,
          duration: video.duration
        }));
      }
    });

    video.addEventListener('pause', function() {
      if (video.duration > 60) {
        toFlutter('onProgress', JSON.stringify({
          type: 'pause',
          currentTime: video.currentTime,
          duration: video.duration
        }));
      }
    });
  }

  setupTracking();
}
""";
  }

  void _handleProgress(String jsonStr) {
    try {
      final dynamic data = jsonDecode(jsonStr);
      if (data is Map) {
        final double currentTime = (data['currentTime'] as num).toDouble();
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
    } catch (e) {
      // Ignore parse errors
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onClose();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(widget.initialUrl),
              ),
              initialUserScripts: UnmodifiableListView([
                // Injected at DOCUMENT_START in ALL frames (including iframes).
                // Embed players load their video in iframes — without
                // forMainFrameOnly: false, the script only runs on the outer
                // page and misses the actual video element.
                UserScript(
                  source: _kFullscreenSuppressJs,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  forMainFrameOnly: false,
                ),
              ]),
              initialSettings: InAppWebViewSettings(
                // --- Inline playback ---
                allowsInlineMediaPlayback: true,
                mediaPlaybackRequiresUserGesture: false,

                // --- General ---
                javaScriptEnabled: true,
                supportZoom: false,
                disableVerticalScroll: false,
                disableHorizontalScroll: false,

                // --- iOS-specific ---
                allowsBackForwardNavigationGestures: false,
                allowsPictureInPictureMediaPlayback: false,
                isFraudulentWebsiteWarningEnabled: false,
                suppressesIncrementalRendering: false,

                // User agent: only set on Android. On iOS, leave as default
                // (WKWebView Safari UA). Passing '' breaks sites.
                userAgent: Platform.isAndroid
                    ? 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36'
                    : null,
              ),

              // --- Block pop-up windows (always ads) ---
              onCreateWindow: (controller, createWindowAction) async {
                debugPrint('Blocked pop-up: ${createWindowAction.request.url}');
                return false;
              },

              // --- Block ad redirects while allowing CDN/video loads ---
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final url = navigationAction.request.url;
                if (url == null) return NavigationActionPolicy.ALLOW;

                final initialHost = Uri.parse(widget.initialUrl).host;
                final targetHost = url.host;

                // Allow same-domain navigations
                if (targetHost.contains(initialHost) ||
                    initialHost.contains(targetHost)) {
                  return NavigationActionPolicy.ALLOW;
                }

                // Block navigations triggered by user clicks to other domains
                // (these are ad clicks). Allow everything else (sub-resources,
                // iframes, XHR, etc. needed for video loading from CDNs).
                final isMainFrame = navigationAction.isForMainFrame;
                if (isMainFrame) {
                  debugPrint('Blocked ad redirect: $url');
                  return NavigationActionPolicy.CANCEL;
                }

                return NavigationActionPolicy.ALLOW;
              },

              // --- Native fullscreen callback ---
              // Do NOT try to exit fullscreen here — the native transition has
              // already started, and calling exitFullscreen creates a rapid
              // enter-then-exit that flashes a white screen.
              // The UserScript at AT_DOCUMENT_START should prevent fullscreen
              // from being requested in the first place.
              onEnterFullscreen: (controller) {
                debugPrint(
                    'WebView entered fullscreen — UserScript should have prevented this');
              },

              onWebViewCreated: (controller) {
                _controller = controller;

                // Register JS handlers
                controller.addJavaScriptHandler(
                  handlerName: 'onPlayPause',
                  callback: (args) {
                    if (args.isNotEmpty && mounted) {
                      final state = args[0] as String;
                      setState(() => _isVideoPaused = state == 'paused');
                    }
                  },
                );

                controller.addJavaScriptHandler(
                  handlerName: 'onProgress',
                  callback: (args) {
                    if (args.isNotEmpty) {
                      _handleProgress(args[0] as String);
                    }
                  },
                );
              },

              // Listen for postMessage from iframes (tracking JS fallback)
              onConsoleMessage: (controller, consoleMessage) {
                // No-op — just suppresses console noise in debug
              },

              onLoadStart: (controller, url) {
                if (mounted) {
                  setState(() => _isLoading = true);
                }
              },

              onLoadStop: (controller, url) async {
                if (mounted) {
                  setState(() => _isLoading = false);
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

                // Re-run fullscreen suppression + set up tracking
                await controller.evaluateJavascript(
                  source:
                      '$_kFullscreenSuppressJs\n${_buildTrackingJs(startProgress)}',
                );
              },

              onReceivedError: (controller, request, error) {
                debugPrint(
                  'WebView error for ${request.url}: ${error.description} (type: ${error.type})',
                );
              },
            ),

            if (_isLoading)
              const Center(
                child: CircularProgressIndicator(color: AppTheme.primaryColor),
              ),

            // Close button — visible when paused or loading, hidden during playback.
            Positioned(
              top: 20,
              left: 20,
              child: AnimatedOpacity(
                opacity: (_isLoading || _isVideoPaused) ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: IgnorePointer(
                  ignoring: !(_isLoading || _isVideoPaused),
                  child: SafeArea(
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: widget.onClose,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
