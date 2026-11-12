import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/tmdb_service.dart';
import '../screens/details_screen.dart';

class DeepLinkService {
  static final DeepLinkService _instance = DeepLinkService._internal();
  factory DeepLinkService() => _instance;
  DeepLinkService._internal();

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  GlobalKey<NavigatorState>? _navigatorKey;

  /// True once the app is past its splash and first-run screens. A link
  /// that arrives earlier waits for this (see [_pending]).
  final ValueNotifier<bool> appReady = ValueNotifier(false);

  /// True while the maintenance or forced-update screen is up: a link is
  /// dropped then, not opened over it.
  bool blocked = false;

  /// The latest link that arrived before the app was ready: (id, type).
  (String, String)? _pending;

  void init(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
    _appLinks = AppLinks();
    appReady.addListener(_openPending);
    _initDeepLinks();
  }

  /// Called by the app as its screen changes.
  void setAppState({required bool ready, required bool blocked}) {
    this.blocked = blocked;
    if (blocked) _pending = null;
    appReady.value = ready && !blocked;
  }

  Future<void> _initDeepLinks() async {
    // Check initial link if app was opened by one
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        _handleDeepLink(initialUri);
      }
    } catch (e) {
      debugPrint('DeepLink Error: $e');
    }

    // Listen for links while app is running
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(uri);
    }, onError: (err) {
      debugPrint('DeepLink Stream Error: $err');
    });
  }

  /// The (id, type) a link asks for, or null if it isn't a well-formed
  /// `popcorn://details?id=123&type=movie` link.
  @visibleForTesting
  static (String, String)? parse(Uri uri) {
    if (uri.scheme != 'popcorn' || uri.host != 'details') return null;
    final id = uri.queryParameters['id'];
    final type = uri.queryParameters['type'];
    if (id == null || type == null) return null;
    if (!RegExp(r'^\d{1,9}$').hasMatch(id)) return null;
    if (type != 'movie' && type != 'tv') return null;
    return (id, type);
  }

  void _handleDeepLink(Uri uri) {
    debugPrint('Handling Deep Link: $uri');

    final link = parse(uri);
    if (link == null) return;
    if (blocked) return;
    if (!appReady.value) {
      _pending = link;
      return;
    }
    _navigateToDetails(link.$1, link.$2);
  }

  void _openPending() {
    final link = _pending;
    if (link == null || !appReady.value) return;
    _pending = null;
    _navigateToDetails(link.$1, link.$2);
  }

  Future<void> _navigateToDetails(String id, String type) async {
    if (_navigatorKey == null || _navigatorKey!.currentState == null) return;

    // Show a loading dialog or indicator if needed
    // Fetch full details first to ensure we have a valid Movie object
    try {
      final movieDetails = await TMDBService().getDetails(id, type: type);
      if (movieDetails == null) return;
      // The app may have gone to maintenance while this was loading.
      if (blocked) return;

      _navigatorKey!.currentState!.push(
        MaterialPageRoute(
          builder: (context) => DetailsScreen(
            movie: movieDetails,
            fromDeepLink: true,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Error fetching deep link details: $e');
    }
  }

  void dispose() {
    _linkSubscription?.cancel();
    appReady.removeListener(_openPending);
  }
}
