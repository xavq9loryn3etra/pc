import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/gemini_key_service.dart';
import 'glass_dialog.dart';

/// Where a Gemini API key is made.
const _aiStudio = 'https://aistudio.google.com/app/apikey';

/// The key's steps and paste box ([GeminiKeyForm]) in a popup headed
/// [title], for where it's needed: the player's Sinhala subtitles, Ask.
/// Done once it's saved, removed or cancelled — GeminiKeyService().hasKey
/// says which.
Future<void> showGeminiKeyDialog(BuildContext context,
        {required String title}) =>
    showGlassDialog<void>(
      context,
      maxWidth: 560,
      builder: (dialogContext) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            GeminiKeyForm(onDone: () => Navigator.pop(dialogContext)),
          ],
        ),
      ),
    );

/// Adding, changing or removing the viewer's Gemini key (see
/// GeminiKeyService), with the steps to get one — a key is checked before
/// it's kept. Opens under Settings' "Gemini API key" row; [onDone] closes
/// it again (saved, removed or cancelled).
class GeminiKeyForm extends StatefulWidget {
  final VoidCallback onDone;

  const GeminiKeyForm({super.key, required this.onDone});

  @override
  State<GeminiKeyForm> createState() => _GeminiKeyFormState();
}

class _GeminiKeyFormState extends State<GeminiKeyForm> {
  late final _field =
      TextEditingController(text: GeminiKeyService().key.value ?? '');
  bool _checking = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    GeminiKeyService().key.addListener(_keyChanged);
  }

  // Added or removed somewhere else (Ask's or the player's popup) while
  // this was open, as Settings' stays: shown here too.
  void _keyChanged() {
    if (!mounted) return;
    setState(() {
      _field.text = GeminiKeyService().key.value ?? '';
      _problem = null;
    });
  }

  @override
  void dispose() {
    GeminiKeyService().key.removeListener(_keyChanged);
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
    if (!mounted) return;
    setState(() => _checking = false);
    widget.onDone();
  }

  Future<void> _remove() async {
    await GeminiKeyService().remove();
    if (!mounted) return;
    _field.clear();
    widget.onDone();
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
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // For people who've never heard of an API key: what it is, in
          // a line, and Google's screens step by step in the words on
          // them (its "choose a project" box stopped people).
          const Text(
            'A free code from Google that lets Popcorn answer your '
            'questions in Ask and make Sinhala subtitles. It costs nothing, '
            'and you only do this once.',
            style: body,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: GlassDialogButton(
              label: 'Get my key',
              primary: true,
              onTap: () => launchUrl(Uri.parse(_aiStudio),
                  mode: LaunchMode.externalApplication),
            ),
          ),
          const SizedBox(height: 8),
          step(
            '1.',
            const TextSpan(children: [
              TextSpan(text: 'Tap '),
              TextSpan(text: 'Get my key', style: bold),
              TextSpan(
                  text: ' above. Google\'s page opens: sign in with your '
                      'Google (Gmail) account if it asks.'),
            ]),
          ),
          step(
            '2.',
            const TextSpan(children: [
              TextSpan(text: 'Tap '),
              TextSpan(text: 'Create API key', style: bold),
              TextSpan(text: '.'),
            ]),
          ),
          step(
            '3.',
            const TextSpan(children: [
              TextSpan(
                  text: 'If it asks you to choose a project, tap that box and '
                      'pick '),
              TextSpan(text: 'Create project', style: bold),
              TextSpan(text: ', give it any name, for example '),
              TextSpan(text: '"Popcorn"', style: bold),
              TextSpan(text: ', and tap '),
              TextSpan(text: 'Create', style: bold),
              TextSpan(text: '. Then tap '),
              TextSpan(text: 'Create key', style: bold),
              TextSpan(text: '.'),
            ]),
          ),
          step(
            '4.',
            const TextSpan(children: [
              TextSpan(text: 'Copy your new key (a long code starting with '),
              TextSpan(text: 'AIza', style: bold),
              TextSpan(
                  text: '), come back here, and tap the paste button '
                      'below.'),
            ]),
          ),
          const SizedBox(height: 14),
          // A key that's added is shown, locked: changing it means Remove,
          // then pasting the new one.
          TextField(
            controller: _field,
            enabled: !hasKey,
            // Saved: hidden behind stars.
            obscureText: hasKey,
            obscuringCharacter: '*',
            autocorrect: false,
            enableSuggestions: false,
            style: TextStyle(
                color: hasKey ? Colors.white54 : Colors.white, fontSize: 14),
            onChanged: (_) => setState(() => _problem = null),
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
                icon: Icon(Icons.content_paste_rounded,
                    color: hasKey ? Colors.white24 : Colors.white60, size: 20),
                onPressed: hasKey ? null : _paste,
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
                  onTap: hasKey ? _remove : widget.onDone,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GlassDialogButton(
                  label: _checking ? 'Checking…' : 'Save',
                  primary: true,
                  // Nothing to save: the key's already added, or none's
                  // pasted yet.
                  onTap: hasKey || _field.text.trim().isEmpty ? null : _save,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
