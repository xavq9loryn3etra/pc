import 'package:flutter/material.dart';

import '../widgets/gemini_key_form.dart';
import '../widgets/settings_parts.dart';

/// Settings › Gemini key: the steps to get one and the box to paste it in
/// (GeminiKeyForm) — on a TV, the code to scan and add it from a phone.
/// Saving, removing or cancelling goes back to Settings.
class GeminiKeyScreen extends StatelessWidget {
  const GeminiKeyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Gemini key',
      children: [
        // Straight on the page, no card: the page is its background. In
        // line with the text on Settings' cards (the form brings 16 of
        // its own).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: GeminiKeyForm(onDone: () => Navigator.of(context).maybePop()),
        ),
      ],
    );
  }
}
