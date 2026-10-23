import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;
import '../widgets/status_screen.dart';

class UpdateOverlay extends StatelessWidget {
  final String message;
  final String url;

  const UpdateOverlay({super.key, required this.message, required this.url});

  @override
  Widget build(BuildContext context) {
    return StatusScreen(
      title: 'A New Version',
      highlight: 'Is Ready.',
      message: message,
      footer: StatusPrimaryButton(
        label: 'Download Update',
        onPressed: () => launchUrl(Uri.parse(url)),
      ),
    );
  }
}
