import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/gemini_key_service.dart';
import 'glass_dialog.dart';

/// Where a Gemini API key is made.
const _aiStudio = 'https://aistudio.google.com/app/apikey';

/// Adding, changing or removing the viewer's Gemini key (see
/// GeminiKeyService), with the steps to get one — a key is checked
/// before it's kept.
Future<void> showGeminiKeyDialog(BuildContext context) =>
    showGlassDialog<void>(context, builder: (_) => const _GeminiKeyDialog());

class _GeminiKeyDialog extends StatefulWidget {
  const _GeminiKeyDialog();

  @override
  State<_GeminiKeyDialog> createState() => _GeminiKeyDialogState();
}

class _GeminiKeyDialogState extends State<_GeminiKeyDialog> {
  late final _field =
      TextEditingController(text: GeminiKeyService().key.value ?? '');
  bool _checking = false;
  String? _problem;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      setState(() {
        _field.text = text;
        _problem = null;
      });
    }
  }

  Future<void> _save() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _problem = null;
    });
    final problem = await GeminiKeyService.test(_field.text);
    if (!mounted) return;
    if (problem != null) {
      setState(() {
        _checking = false;
        _problem = problem;
      });
      return;
    }
    await GeminiKeyService().save(_field.text);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _remove() async {
    await GeminiKeyService().remove();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    const body = TextStyle(color: Colors.white70, fontSize: 14, height: 1.4);
    Widget step(String n, InlineSpan text) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 20, child: Text(n, style: body)),
              Expanded(child: Text.rich(text, style: body)),
            ],
          ),
        );
    const bold = TextStyle(color: Colors.white, fontWeight: FontWeight.w600);
    final hasKey = GeminiKeyService().hasKey;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your Gemini key',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Free from Google, with any Google account. No paid plan needed.',
            style: body,
          ),
          const SizedBox(height: 6),
          step(
            '1.',
            TextSpan(children: [
              const TextSpan(text: 'Open '),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: GestureDetector(
                  onTap: () => launchUrl(Uri.parse(_aiStudio),
                      mode: LaunchMode.externalApplication),
                  child: const MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Text(
                      'aistudio.google.com',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        decoration: TextDecoration.underline,
                        decorationColor: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              const TextSpan(text: ' and sign in.'),
            ]),
          ),
          step(
            '2.',
            const TextSpan(children: [
              TextSpan(text: 'Tap '),
              TextSpan(text: 'Get API key', style: bold),
              TextSpan(text: ', then '),
              TextSpan(text: 'Create API key', style: bold),
              TextSpan(text: '.'),
            ]),
          ),
          step('3.', const TextSpan(text: 'Copy the key and paste it here.')),
          const SizedBox(height: 14),
          TextField(
            controller: _field,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            onChanged: (_) {
              if (_problem != null) setState(() => _problem = null);
            },
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              hintText: 'Paste your key',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.08),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              suffixIcon: IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste_rounded,
                    color: Colors.white60, size: 20),
                onPressed: _paste,
              ),
            ),
          ),
          if (_problem != null) ...[
            const SizedBox(height: 8),
            Text(
              _problem!,
              style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 13),
            ),
          ],
          const SizedBox(height: 10),
          const Text(
            'Used for Sinhala subtitles and Popcorn Ask, and kept only on '
            'this device. On the free plan, Google may use what\'s sent '
            '(subtitle lines and your questions) to improve its services.',
            style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: GlassDialogButton(
                  label: hasKey ? 'Remove' : 'Cancel',
                  destructive: hasKey,
                  onTap: hasKey ? _remove : () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GlassDialogButton(
                  label: _checking ? 'Checking…' : 'Save',
                  primary: true,
                  onTap: _save,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
