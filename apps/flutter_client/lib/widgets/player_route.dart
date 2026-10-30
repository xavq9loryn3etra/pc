import 'package:flutter/material.dart';

/// The route a full-screen player or reader opens in: a quick fade, and no
/// swipe back. The app's other screens slide in and go back on a swipe from
/// the left edge (see AppTheme's page transitions) — which in a player would
/// fight its own swipe controls (seeking, brightness), and in the book
/// reader its page turns.
class PlayerRoute<T> extends PageRouteBuilder<T> {
  PlayerRoute({required WidgetBuilder builder})
      : super(
          pageBuilder: (context, _, __) => builder(context),
          transitionsBuilder: (_, animation, __, child) =>
              FadeTransition(opacity: animation, child: child),
          transitionDuration: const Duration(milliseconds: 220),
          reverseTransitionDuration: const Duration(milliseconds: 180),
        );
}
