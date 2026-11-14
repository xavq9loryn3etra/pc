import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/phone_key_server.dart';
import 'glass_dialog.dart';

/// The Gemini key form on a TV (see GeminiKeyForm): typing a key that long
/// with a remote is a chore, so it's pasted on the viewer's phone instead.
/// A code to scan opens a page the TV serves on the home network (see
/// PhoneKeyServer) with the same steps and a paste box; the key sent from
/// it is checked, saved, and this closes by itself ([onDone]).
class GeminiKeyFromPhone extends StatefulWidget {
  final VoidCallback onDone;

  const GeminiKeyFromPhone({super.key, required this.onDone});

  @override
  State<GeminiKeyFromPhone> createState() => _GeminiKeyFromPhoneState();
}

class _GeminiKeyFromPhoneState extends State<GeminiKeyFromPhone> {
  late final PhoneKeyServer _server = PhoneKeyServer(
    onKey: () {
      if (mounted) widget.onDone();
    },
    onOpened: () => _say("Your phone's connected. Paste your key there."),
    onChecking: () => _say('Checking your key…'),
    onProblem: (problem) => _say(problem, problem: true),
  );

  bool _starting = true;
  String? _address;
  String _status = 'Waiting for your phone…';
  bool _problem = false;

  @override
  void initState() {
    super.initState();
    _server.start().then((address) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _address = address;
      });
    }, onError: (_) {
      if (mounted) setState(() => _starting = false);
    });
  }

  @override
  void dispose() {
    _server.stop();
    super.dispose();
  }

  void _say(String status, {bool problem = false}) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _problem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    const body = TextStyle(color: Colors.white70, fontSize: 14, height: 1.4);
    const small = TextStyle(color: Colors.white38, fontSize: 12, height: 1.35);
    final address = _address;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'A free code from Google that lets Popcorn answer your questions '
            'in Ask and make Sinhala subtitles. Typing it with the remote is '
            'slow, so add it from your phone: scan this with its camera.',
            style: body,
          ),
          const SizedBox(height: 16),
          Center(
            child: SizedBox(
              width: 184,
              height: 184,
              child: address != null
                  // Dark on white, with a quiet margin, so phone cameras
                  // read it at a glance from across the room.
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: QrImageView(
                          data: address,
                          padding: EdgeInsets.zero,
                          backgroundColor: Colors.white,
                        ),
                      ),
                    )
                  : Center(
                      child: _starting
                          ? const CircularProgressIndicator(
                              color: Colors.white54, strokeWidth: 2)
                          : const Text(
                              'This TV isn\'t on a network. Connect it to '
                              'Wi-Fi or a cable, then try again.',
                              textAlign: TextAlign.center,
                              style: body,
                            ),
                    ),
            ),
          ),
          if (address != null) ...[
            const SizedBox(height: 12),
            // For a phone that won't scan: the address to type instead.
            Center(
              child: Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'Or open  '),
                  TextSpan(
                    text: address.replaceFirst('http://', ''),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  const TextSpan(text: '  on your phone.'),
                ]),
                textAlign: TextAlign.center,
                style: body,
              ),
            ),
            const SizedBox(height: 4),
            const Center(
              child: Text(
                'Your phone needs to be on the same Wi-Fi as this TV.',
                textAlign: TextAlign.center,
                style: small,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!_problem) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        color: Colors.white54, strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _problem
                          ? const Color(0xFFFF8A80)
                          : Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          const Text(
            'Used for Sinhala subtitles and Popcorn Ask, and kept only on '
            'this device. On the free plan, Google may use what\'s sent '
            '(subtitle lines and your questions) to improve its services.',
            style: small,
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: GlassDialogButton(label: 'Cancel', onTap: widget.onDone),
          ),
        ],
      ),
    );
  }
}
