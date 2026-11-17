import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/sync/drive_store.dart';
import '../services/sync/google_link.dart';
import '../services/sync/sync_service.dart';
import '../widgets/glass_blur.dart';
import '../widgets/glass_dialog.dart' show GlassDialogButton;
import '../widgets/settings_parts.dart';

/// What Settings says about the last sync.
String syncStatusText(SyncStatus s) {
  if (s.busy) return 'Syncing…';
  switch (s.problem) {
    case SyncProblem.signInAgain:
      return 'Google needs you to sign in again.';
    case SyncProblem.driveFull:
      return 'Your Google Drive is full, so nothing new can be saved there.';
    case SyncProblem.unreachable:
      return "Couldn't reach Google. Trying again soon.";
    case SyncProblem.needsUpdate:
      return 'Another device has a newer Popcorn. Update this one to keep syncing.';
    case SyncProblem.pausedRemotely:
      return 'Sync is paused for now. Nothing is lost.';
    case SyncProblem.other:
      return 'Something went wrong. Trying again soon.';
    case null:
      break;
  }
  final last = s.lastSynced;
  if (last == null) return 'Not synced yet';
  final ago = DateTime.now().difference(last);
  if (ago.inMinutes < 1) return 'Synced just now';
  if (ago.inMinutes < 60) return 'Synced ${ago.inMinutes} min ago';
  if (ago.inHours < 24) return 'Synced ${ago.inHours} h ago';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return 'Synced on ${last.day} ${months[last.month - 1]}';
}

/// Whether [s] shows a problem in red (pausing from the website isn't one
/// the viewer can do anything about, or needs to).
bool syncShowsProblem(SyncStatus s) =>
    !s.busy && s.problem != null && s.problem != SyncProblem.pausedRemotely;

/// Settings › Sync: everything on the page, nothing in popups. The switch
/// and what syncing does; signing in, shown here as it happens (Google's
/// own window on a phone, the browser on a computer, the code to enter
/// on a phone on a TV); once on, the account and how the last sync went
/// (tap to sync now), bringing back what a big removal took, and deleting
/// what's synced — confirmed right here.
class SyncSettingsScreen extends StatefulWidget {
  const SyncSettingsScreen({super.key});

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  // "Synced 3 min ago" moves on by itself.
  Timer? _tick;

  bool _signingIn = false;
  Completer<void>? _cancel;
  DeviceCode? _code;
  String? _signInProblem;

  bool _confirmingDelete = false;
  bool _deleting = false;

  /// A line under the card saying what just happened.
  String? _note;
  bool _noteIsProblem = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
        const Duration(seconds: 30), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    // Leaving the page stops waiting for a sign-in (the TV's code).
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    super.dispose();
  }

  void _say(String? note, {bool problem = false}) {
    if (!mounted) return;
    setState(() {
      _note = note;
      _noteIsProblem = problem;
    });
  }

  Future<void> _signIn() async {
    final cancel = Completer<void>();
    setState(() {
      _signingIn = true;
      _cancel = cancel;
      _code = null;
      _signInProblem = null;
      _note = null;
      _confirmingDelete = false;
    });
    try {
      await SyncService().turnOn(
        cancel: cancel.future,
        onCode: (code) {
          if (mounted) setState(() => _code = code);
        },
      );
      if (!mounted) return;
      setState(() => _signingIn = false);
      if (SyncService().status.value.problem == null) {
        _say('Sync is on. Your lists are up to date.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _signingIn = false;
        if (cancel.isCompleted) return; // Cancelled here.
        final detail = e is SyncException ? e.detail.toLowerCase() : '';
        if (detail.contains('cancel')) return; // Closed Google's window.
        _signInProblem = detail.contains('expired')
            ? 'The code ran out. Turn sync on again for a new one.'
            : detail.contains('access_denied')
                ? 'Sign-in was turned down. Turn sync on again to retry.'
                : "Couldn't sign in to Google. Check the internet and try again.";
      });
    }
  }

  void _cancelSignIn() {
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    setState(() => _signingIn = false);
  }

  Future<void> _toggle(bool on) async {
    if (_signingIn) {
      _cancelSignIn();
      return;
    }
    if (!on) {
      await _signIn();
      return;
    }
    await SyncService().turnOff();
    _say('Sync is off on this device. Your lists stay here.');
  }

  Future<void> _syncNow() async {
    final service = SyncService();
    if (service.status.value.busy) return;
    _say(null);
    await service.syncNow(userAsked: true);
  }

  Future<void> _bringBack() async {
    final ok = await SyncService().undoRemoval();
    _say(ok ? "They're back, on all your devices." : "Couldn't bring them back.",
        problem: !ok);
  }

  Future<void> _delete() async {
    setState(() => _deleting = true);
    var ok = true;
    try {
      await SyncService().deleteSyncedData();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _confirmingDelete = false;
    });
    _say(
      ok
          ? 'Synced data deleted, and sync is off on all your devices. Your '
              'lists stay on each of them.'
          : "Couldn't reach Google to delete it. Try again later.",
      problem: !ok,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Sync',
      children: [
        ValueListenableBuilder<SyncStatus>(
          valueListenable: SyncService().status,
          builder: (context, s, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SettingsGroup(
                footnote: 'Keeps My List, Continue Watching and your language '
                    'choices the same on every device you sign in on. Popcorn '
                    'keeps them in a hidden file in your Google Drive that '
                    'only Popcorn can open. Nothing else in your Drive is '
                    'touched.',
                children: [
                  SettingsRow(
                    icon: Icons.sync_rounded,
                    title: 'Sync with Google Drive',
                    onTap: () => _toggle(s.on),
                    trailing: GlassSwitch(
                      value: s.on || _signingIn,
                      onChanged: (_) => _toggle(s.on),
                    ),
                  ),
                  if (s.on)
                    SettingsRow(
                      icon: Icons.account_circle_outlined,
                      title: s.email ?? 'Google account',
                      subtitle: syncStatusText(s),
                      subtitleColor:
                          syncShowsProblem(s) ? const Color(0xFFFF8A80) : null,
                      onTap: _syncNow,
                      trailing: s.busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  color: Colors.white54, strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded,
                              color: Colors.white38, size: 20),
                    ),
                  if (s.on && s.problem == SyncProblem.signInAgain && !_signingIn)
                    SettingsRow(
                      icon: Icons.login_rounded,
                      title: 'Sign in again',
                      onTap: _signIn,
                    ),
                  if (s.removedCount > 0)
                    SettingsRow(
                      icon: Icons.undo_rounded,
                      title: 'Bring back ${s.removedCount} removed titles',
                      subtitle: 'Removed from another device',
                      onTap: _bringBack,
                    ),
                  if (s.on) _deleteRow(),
                ],
              ),
              if (_signingIn) ...[
                const SizedBox(height: 20),
                _SignInPanel(code: _code, onCancel: _cancelSignIn),
              ],
              if (_signInProblem != null)
                SettingsNote(_signInProblem!, color: const Color(0xFFFF8A80)),
              if (_note != null)
                SettingsNote(
                  _note!,
                  color: _noteIsProblem ? const Color(0xFFFF8A80) : Colors.white70,
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// "Delete synced data", asking right here before it does.
  Widget _deleteRow() {
    if (_deleting) {
      return const SettingsRow(
        icon: Icons.delete_outline_rounded,
        title: 'Deleting…',
        trailing: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2),
        ),
      );
    }
    if (!_confirmingDelete) {
      return SettingsRow(
        icon: Icons.delete_outline_rounded,
        title: 'Delete synced data',
        onTap: () => setState(() {
          _confirmingDelete = true;
          _note = null;
        }),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Delete synced data?',
            style: TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            "Removes Popcorn's hidden file from your Google Drive and turns "
            'sync off on all your devices. The lists on each device stay as '
            'they are.',
            style: TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.4),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: GlassDialogButton(
                  label: 'Keep it',
                  onTap: () => setState(() => _confirmingDelete = false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GlassDialogButton(
                  label: 'Delete',
                  primary: true,
                  destructive: true,
                  onTap: _delete,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// While signing in: what to do, on this device's terms. On a TV, the
/// code to enter at Google's address on a phone (or scan); on a computer,
/// a reminder that the browser has it; on a phone, Google's own window is
/// up and this just says so.
class _SignInPanel extends StatelessWidget {
  final DeviceCode? code;
  final VoidCallback onCancel;

  const _SignInPanel({required this.code, required this.onCancel});

  static const _body = TextStyle(color: Colors.white70, fontSize: 14, height: 1.4);

  @override
  Widget build(BuildContext context) {
    final showsCode = SyncService().signsInWithCode;
    final code = this.code;
    return SettingsCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showsCode && code != null) ...[
            Row(
              children: [
                // Scanning opens Google's page on the phone.
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: QrImageView(
                      data: code.url,
                      size: 120,
                      padding: EdgeInsets.zero,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(children: [
                          const TextSpan(text: 'On your phone, scan this or go to  '),
                          TextSpan(
                            // Easiest typed without "https://www.".
                            text: code.url
                                .replaceFirst(RegExp(r'^https?://(www\.)?'), ''),
                            style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                          const TextSpan(text: ', and enter'),
                        ]),
                        style: _body,
                      ),
                      const SizedBox(height: 10),
                      SelectableText(
                        code.userCode,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
          ],
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  showsCode
                      ? (code == null
                          ? 'Getting a code from Google…'
                          : 'Waiting for you to sign in on your phone…')
                      : Platform.isWindows
                          ? 'Finish signing in in your browser, then come back here.'
                          : 'Signing in…',
                  style: _body,
                ),
              ),
            ],
          ),
          // A phone's sign-in is Google's own window, cancelled there.
          if (showsCode || Platform.isWindows) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: GlassDialogButton(label: 'Cancel', onTap: onCancel),
            ),
          ],
        ],
      ),
    );
  }
}
