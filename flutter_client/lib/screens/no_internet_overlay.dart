import 'package:flutter/material.dart';
import '../widgets/status_screen.dart';

class NoInternetOverlay extends StatelessWidget {
  const NoInternetOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return const StatusScreen(
      title: "You're Offline.",
      highlight: 'Hang Tight.',
      message: 'Check your Wi-Fi or mobile data. '
          "We'll pick up right where you left off.",
      // In the welcome screen's button place: plain words, fading in and
      // out, rather than a tag.
      waitingFor: 'Waiting for connection…',
    );
  }
}
