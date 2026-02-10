import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
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
  int _lastUpdate = 0;
  bool _canSave = false;

  @override
  void initState() {
    super.initState();

    // Prevent overwriting history for the first 15 seconds
    // This gives the user time to scrub to their previous position
    // if the player fails to resume automatically.
    Future.delayed(const Duration(seconds: 15), () {
      if (mounted) _canSave = true;
    });

    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    _controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            // Update loading bar.
          },
          onPageStarted: (String url) {},
          onPageFinished: (String url) {},
          onWebResourceError: (WebResourceError error) {},
        ),
      )
      ..addJavaScriptChannel(
        'PlayerBridge',
        onMessageReceived: (JavaScriptMessage message) {
          _handleMessage(message.message);
        },
      );

    _loadContent();
  }

  void _loadContent() {
    // HTML Wrapper to force iframe behavior and consistent messaging
    final String htmlContent =
        '''
      <!DOCTYPE html>
      <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
          body, html { margin: 0; padding: 0; width: 100%; height: 100%; background-color: black; overflow: hidden; }
          iframe { width: 100%; height: 100%; border: none; }
        </style>
      </head>
      <body>
        <iframe 
          src="${widget.initialUrl}" 
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen" 
          sandbox="allow-scripts allow-same-origin allow-presentation allow-forms"
          allowfullscreen
        ></iframe>
        <script>
          window.addEventListener('message', function(e) {
            try {
              // Forward to Flutter via JavaScriptChannel
              if(window.PlayerBridge) {
                 var payload = e.data;
                 if (typeof payload === 'object') {
                    payload = JSON.stringify(payload);
                 }
                 window.PlayerBridge.postMessage(payload);
              }
            } catch(err) {}
          });
        </script>
      </body>
      </html>
    ''';

    _controller.loadHtmlString(htmlContent, baseUrl: 'https://vidking.net/');
  }

  void _handleMessage(String msg) {
    print("MobilePlayer: Msg: $msg"); // Debug Log
    try {
      final dynamic outerPayload = jsonDecode(msg);

      if (outerPayload is Map) {
        if (outerPayload['type'] == 'PLAYER_EVENT' &&
            outerPayload['data'] != null) {
          final data = outerPayload['data'];
          final event = data['event'];

          if (event == 'timeupdate' || event == 'pause') {
            final double currentTime = (data['currentTime'] as num).toDouble();
            final double duration = (data['duration'] as num).toDouble();

            if (duration > 0) {
              final double progress = currentTime / duration;
              final now = DateTime.now().millisecondsSinceEpoch;

              if (event == 'pause' || (now - _lastUpdate > 5000)) {
                _saveProgress(progress);
                _lastUpdate = now;
              }
            }
          }
        }
      }
    } catch (e) {
      // Ignore parsing errors
    }
  }

  void _saveProgress(double progress) {
    if (!_canSave) return;
    SavedMoviesService().addToHistory(
      widget.movie,
      season: widget.season,
      episode: widget.episode,
      progress: progress,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            Positioned(
              top: 10,
              left: 10,
              child: FloatingActionButton(
                heroTag: 'close_player_btn', // Unique tag
                mini: true,
                backgroundColor: Colors.black54,
                child: const Icon(Icons.close, color: Colors.white),
                onPressed: widget.onClose,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
