import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import '../models/movie.dart';
import '../services/tmdb_service.dart';
import '../screens/details_screen.dart';

class DeepLinkService {
  static final DeepLinkService _instance = DeepLinkService._internal();
  factory DeepLinkService() => _instance;
  DeepLinkService._internal();

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  GlobalKey<NavigatorState>? _navigatorKey;

  void init(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
    _appLinks = AppLinks();
    _initDeepLinks();
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

  void _handleDeepLink(Uri uri) async {
    debugPrint('Handling Deep Link: $uri');

    // Expected format: popcorn://details?id=123&type=movie
    if (uri.scheme == 'popcorn' && uri.host == 'details') {
      final id = uri.queryParameters['id'];
      final type = uri.queryParameters['type'];

      if (id != null && type != null) {
        _navigateToDetails(id, type);
      }
    }
  }

  Future<void> _navigateToDetails(String id, String type) async {
    if (_navigatorKey == null || _navigatorKey!.currentState == null) return;

    // Show a loading dialog or indicator if needed
    // Fetch full details first to ensure we have a valid Movie object
    try {
      final movieDetails = await TMDBService().getDetails(id, type: type);
      if (movieDetails == null) return;
      
      _navigatorKey!.currentState!.push(
        MaterialPageRoute(
          builder: (context) => DetailsScreen(
            movie: movieDetails,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Error fetching deep link details: $e');
    }
  }

  void dispose() {
    _linkSubscription?.cancel();
  }
}
