import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_client/theme/app_theme.dart';
import 'dart:convert';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'dart:io';
import 'dart:async';
import 'web_player_platform_interface.dart';
import '../../services/saved_movies_service.dart';

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
  Offset? _tapDownPosition;

  @override
  void initState() {
    super.initState();

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

    // Enable debugging for Android WebView
    if (Platform.isAndroid &&
        _controller.platform is AndroidWebViewController) {
      final androidController =
          _controller.platform as AndroidWebViewController;
      androidController.setMediaPlaybackRequiresUserGesture(false);
    }

    // Force landscape and immersive mode
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel(
        'FlutterControlChannel',
        onMessageReceived: (JavaScriptMessage message) {
          try {
            // Check for simple string messages first
            if (message.message == 'tap') {
              _toggleControls();
              return;
            } else if (message.message == 'playing') {
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

            // Try parsing JSON for progress updates
            final dynamic data = jsonDecode(message.message);
            if (data is Map) {
              if (data['type'] == 'pause') {
                // Save immediately on pause
                final double currentTime =
                    (data['currentTime'] as num).toDouble();
                final double duration = (data['duration'] as num).toDouble();
                if (duration > 60 && mounted) {
                  final double progress = currentTime / duration;
                  SavedMoviesService().addToHistory(
                    widget.movie,
                    season: widget.season,
                    episode: widget.episode,
                    progress: progress,
                  );
                }
              } else if (data['type'] == 'timeupdate') {
                // Periodic saves during playback
                final double currentTime =
                    (data['currentTime'] as num).toDouble();
                final double duration = (data['duration'] as num).toDouble();

                if (duration > 60 && mounted) {
                  final double progress = currentTime / duration;
                  SavedMoviesService().addToHistory(
                    widget.movie,
                    season: widget.season,
                    episode: widget.episode,
                    progress: progress,
                  );
                }
              }
            }
          } catch (e) {
            // Ignore parse errors or other messages
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            final host = Uri.parse(request.url).host;
            final initialHost = Uri.parse(widget.initialUrl).host;

            // Allow initial host and its subdomains, or exact matches
            if (host.contains(initialHost) || initialHost.contains(host)) {
              return NavigationDecision.navigate;
            }

            debugPrint('Blocking redirect to: ${request.url}');
            return NavigationDecision.prevent;
          },
          onPageStarted: (String url) {
            if (mounted) {
              setState(() {
                _isLoading = true;
                _showControls = true;
              });
              _startHideTimer();
            }
          },
          onPageFinished: (String url) {
            if (mounted) {
              setState(() {
                _isLoading = false;
                _showControls = true;
              });
              _startHideTimer();
            }

            // Get saved progress to resume
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
              // For movies, we might need to fetch from history list if not in memory
              // But SavedMoviesService architecture is a bit split.
              // For now, let's try getMovieFromHistory
              final m = service.getMovieFromHistory(widget.movie.id);
              if (m != null) startProgress = m.progress ?? 0.0;
            }

            // Inject JS: suppress iOS fullscreen takeover, restore progress, track watch time.
            // NOTE: tap/play/pause JS listeners are intentionally removed — Flutter's Listener
            // widget handles taps natively, and play/pause state is inferred from progress events.
            _controller.runJavaScript("""
              // Always update the start position for this video
              window.flutterPlayerStartProgress = $startProgress;

              // -- iOS FULLSCREEN SUPPRESSION --
              // Inject CSS immediately so video never renders in a fullscreen-eligible state.
              (function injectStyle() {
                const style = document.createElement('style');
                style.textContent = [
                  'video { object-fit: contain !important; }',
                  '::-webkit-media-controls-fullscreen-button { display: none !important; }',
                  '::-webkit-media-controls-panel { display: none !important; }',
                ].join(' ');
                (document.head || document.documentElement).appendChild(style);
              })();

              // Override fullscreen APIs so the embed player can't trigger them
              (function blockFullscreen() {
                const noop = function() { return Promise.resolve(); };
                try { Element.prototype.requestFullscreen = noop; } catch(e) {}
                try { Element.prototype.webkitRequestFullscreen = noop; } catch(e) {}
                try { HTMLVideoElement.prototype.webkitEnterFullscreen = noop; } catch(e) {}
                try { HTMLVideoElement.prototype.webkitSetPresentationMode = function() {}; } catch(e) {}
                Object.defineProperty(document, 'fullscreenEnabled', { get: () => false });
                Object.defineProperty(document, 'webkitFullscreenEnabled', { get: () => false });
              })();

              // Only inject tracking once
              if (window.flutterTrackingActive) {
                console.log("Tracking already active, position updated to: " + ($startProgress * 100) + "%");
                return;
              }
              window.flutterTrackingActive = true;

              window.addEventListener('play', () => {
                FlutterControlChannel.postMessage('playing');
              }, true);

              window.addEventListener('pause', () => {
                FlutterControlChannel.postMessage('paused');
              }, true);

              // Find video element, including one level of Shadow DOM
              function findVideo() {
                let v = document.querySelector('video');
                if (v) return v;
                for (let el of document.querySelectorAll('*')) {
                  if (el.shadowRoot) {
                    v = el.shadowRoot.querySelector('video');
                    if (v) return v;
                  }
                }
                return null;
              }

              function applyInlineAndBlock(video) {
                // Force inline attributes
                video.setAttribute('playsinline', '');
                video.setAttribute('webkit-playsinline', '');
                video.removeAttribute('controls'); // remove native controls to prevent fullscreen button tap

                // Re-apply fullscreen block directly on the element
                try { video.webkitEnterFullscreen = function() {}; } catch(e) {}
                try { video.webkitSetPresentationMode = function() {}; } catch(e) {}
                try { video.requestFullscreen = function() { return Promise.resolve(); }; } catch(e) {}
                try { video.webkitRequestFullscreen = function() {}; } catch(e) {}

                // Intercept fullscreenchange in case the embed triggers it
                document.addEventListener('fullscreenchange', function(e) {
                  if (document.fullscreenElement) {
                    try { document.exitFullscreen(); } catch(err) {}
                  }
                }, true);
                document.addEventListener('webkitfullscreenchange', function(e) {
                  if (document.webkitFullscreenElement) {
                    try { document.webkitExitFullscreen(); } catch(err) {}
                  }
                }, true);
              }

              function setupTracking() {
                const video = findVideo();
                if (!video) {
                  setTimeout(setupTracking, 1000);
                  return;
                }

                console.log("Video found! Setting up tracking...");
                applyInlineAndBlock(video);

                let hasResumed = false;
                function resume() {
                  const startProg = window.flutterPlayerStartProgress || 0;
                  if (hasResumed || startProg < 0.01 || startProg > 0.95) return;
                  if (video.duration && Number.isFinite(video.duration)) {
                    video.currentTime = startProg * video.duration;
                    hasResumed = true;
                    console.log("Resumed to: " + video.currentTime + "s");
                  }
                }

                if (video.readyState >= 1) {
                  setTimeout(resume, 500);
                } else {
                  video.addEventListener('loadedmetadata', () => setTimeout(resume, 500), { once: true });
                }

                let lastSave = 0;
                video.addEventListener('timeupdate', () => {
                  const now = Date.now();
                  if (now - lastSave > 5000 && video.duration > 60) {
                    lastSave = now;
                    FlutterControlChannel.postMessage(JSON.stringify({
                      type: 'timeupdate',
                      currentTime: video.currentTime,
                      duration: video.duration
                    }));
                  }
                });

                video.addEventListener('pause', () => {
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
            """);
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint(
                'WebView error for url ${widget.initialUrl}: ${error.description} (code: ${error.errorCode}, type: ${error.errorType})');
          },
        ),
      )
      ..setUserAgent(
        Platform.isIOS
            ? "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
            : "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36",
      )
      ..loadRequest(
        Uri.parse(widget.initialUrl),
      );
  }

  void _toggleControls() {
    setState(() {
      // Always show controls on tap, and restart hide timer
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
    // Restore portrait and system UI
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
          Listener(
            onPointerDown: (event) => _tapDownPosition = event.position,
            onPointerUp: (event) {
              if (_tapDownPosition != null) {
                if ((event.position - _tapDownPosition!).distance < 20.0) {
                  _toggleControls();
                }
                _tapDownPosition = null;
              }
            },
            onPointerCancel: (_) => _tapDownPosition = null,
            child: WebViewWidget(controller: _controller),
          ),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryColor),
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
