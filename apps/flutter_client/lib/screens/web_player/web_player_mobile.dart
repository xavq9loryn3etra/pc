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
              setState(() => _isLoading = true);
            }
          },
          onPageFinished: (String url) {
            if (mounted) {
              setState(() => _isLoading = false);
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

            // Inject JS listener for click/tap, play/pause, and history tracking
            // We debounce the tap event
            // We also poll for the video element to restore progress and track time
            _controller.runJavaScript("""
              // Always update the start position for this video
              window.flutterPlayerStartProgress = $startProgress;
              
              // Only inject listeners once
              if (window.flutterTrackingActive) {
                console.log("Tracking already active, position updated to: " + ($startProgress * 100) + "%");
                return;
              }
              window.flutterTrackingActive = true;
              
              // Tap/Click for controls
              let lastTap = 0;
              const notifyTap = () => {
                const now = Date.now();
                if (now - lastTap > 300) {
                  lastTap = now;
                  FlutterControlChannel.postMessage('tap');
                }
              };

              window.addEventListener('click', notifyTap, true);
              window.addEventListener('touchstart', notifyTap, true);
              window.addEventListener('pointerdown', notifyTap, true);
              
              window.addEventListener('play', () => {
                FlutterControlChannel.postMessage('playing');
              }, true);
              
              window.addEventListener('pause', () => {
                FlutterControlChannel.postMessage('paused');
              }, true);

              // Find video element (simple search first, then Shadow DOM if needed)
              function findVideo() {
                let v = document.querySelector('video');
                if (v) return v;
                
                // Check one level of Shadow DOM
                const elements = document.querySelectorAll('*');
                for (let el of elements) {
                  if (el.shadowRoot) {
                    v = el.shadowRoot.querySelector('video');
                    if (v) return v;
                  }
                }
                return null;
              }

              function setupTracking() {
                const video = findVideo();
                if (!video) {
                  setTimeout(setupTracking, 1000);
                  return;
                }

                console.log("Video found! Setting up tracking...");
                let hasResumed = false;

                // Resume to saved position ONCE
                function resume() {
                  const startProg = window.flutterPlayerStartProgress || 0;
                  if (hasResumed || startProg < 0.01 || startProg > 0.95) return;
                  
                  if (video.duration && Number.isFinite(video.duration)) {
                    video.currentTime = startProg * video.duration;
                    hasResumed = true;
                    console.log("Resumed to: " + video.currentTime + "s");
                  }
                }

                // Try to resume after metadata loads
                if (video.readyState >= 1) {
                  setTimeout(resume, 500);
                } else {
                  video.addEventListener('loadedmetadata', () => setTimeout(resume, 500), {once: true});
                }

                // Track progress every 5 seconds
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

                // Save immediately on pause
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
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(color: Colors.amber),
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
