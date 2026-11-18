import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/sync/drive_store.dart';
import '../services/sync/google_link.dart';
import '../services/sync/sync_service.dart';
import '../widgets/glass_dialog.dart' show GlassDialogButton;
import '../widgets/settings_parts.dart';

/// What Settings says about the last sync.
String syncStatusText(SyncStatus s) {
  if (s.asking != null) return 'Waiting for your choice above';
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

/// Whether [s] needs the viewer's attention: a problem they can do
/// something about (pausing from the website isn't one), or a question.
bool syncShowsProblem(SyncStatus s) =>
    s.asking != null ||
    (!s.busy && s.problem != null && s.problem != SyncProblem.pausedRemotely);

const _red = Color(0xFFFF8A80);

/// Settings › Sync: everything on the page, nothing in popups.
///
/// Signed out: "Sign in with Google", and signing in shown here as it
/// happens (Google's own window on a phone, the browser on a computer,
/// the code to enter on a phone on a TV). Then, if this device has titles
/// the account doesn't, the question whether they join it.
///
/// Signed in: the account and how the last sync went (tap to sync now),
/// bringing back what a big removal took, signing out and deleting what's
/// synced — each asked about right here before it happens.
class SyncSettingsScreen extends StatefulWidget {
  const SyncSettingsScreen({super.key});

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

/// Which "are you sure" is open on the page.
enum _Confirm { none, signOut, signOutUnsaved, delete }

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  // "Synced 3 min ago" moves on by itself.
  Timer? _tick;

  bool _signingIn = false;
  Completer<void>? _cancel;
  DeviceCode? _code;
  String? _signInProblem;

  _Confirm _confirm = _Confirm.none;

  /// Signing out, deleting, or answering the question: its row shows it.
  String? _working;

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
      _confirm = _Confirm.none;
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
      final s = SyncService().status.value;
      if (s.asking == null && s.problem == null) {
        _say('Signed in. Your lists are up to date.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _signingIn = false;
        if (cancel.isCompleted) return; // Cancelled here.
        final detail = e is SyncException ? e.detail.toLowerCase() : '';
        if (detail.contains('cancel')) return; // Closed Google's window.
        _signInProblem = detail.contains('expired')
            ? 'The code ran out. Sign in again for a new one.'
            : detail.contains('access_denied')
                ? 'Sign-in was turned down. Try again if you meant to sign in.'
                : "Couldn't sign in to Google. Check the internet and try again.";
      });
    }
  }

  void _cancelSignIn() {
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    setState(() => _signingIn = false);
  }

  Future<void> _syncNow() async {
    final service = SyncService();
    if (service.status.value.busy) return;
    _say(null);
    await service.syncNow(userAsked: true);
  }

  Future<void> _answer({required bool add}) async {
    setState(() => _working = add ? 'Adding…' : 'Removing…');
    var ok = true;
    try {
      if (add) {
        await SyncService().addDeviceLists();
      } else {
        await SyncService().keepAccountListsOnly();
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _working = null);
    if (!ok) {
      _say("Couldn't reach Google. Check the internet and try again.", problem: true);
    } else {
      _say(add
          ? "Added to your account. They'll be on all your devices."
          : 'This device now shows only what your account has.');
    }
  }

  Future<void> _signOut({bool evenIfUnsaved = false}) async {
    setState(() => _working = 'Signing out…');
    final done = await SyncService().signOut(evenIfUnsaved: evenIfUnsaved);
    if (!mounted) return;
    setState(() {
      _working = null;
      _confirm = done ? _Confirm.none : _Confirm.signOutUnsaved;
    });
    if (done) _say('Signed out. Your lists are kept in your Google account.');
  }

  Future<void> _bringBack() async {
    final ok = await SyncService().undoRemoval();
    _say(ok ? "They're back, on all your devices." : "Couldn't bring them back.",
        problem: !ok);
  }

  Future<void> _delete() async {
    setState(() => _working = 'Deleting…');
    var ok = true;
    try {
      await SyncService().deleteSyncedData();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _working = null;
      _confirm = _Confirm.none;
    });
    _say(
      ok
          ? 'Synced data deleted from your account and all your devices.'
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
              if (s.on && s.asking != null) ...[
                _AskPanel(
                  onlyHere: s.asking!,
                  working: _working,
                  onAnswer: (add) => _answer(add: add),
                ),
                const SizedBox(height: 20),
              ],
              if (s.on) _signedIn(s) else _signedOut(),
              if (_signingIn && !s.on) ...[
                const SizedBox(height: 20),
                _SignInPanel(code: _code, onCancel: _cancelSignIn),
              ],
              if (_signInProblem != null) SettingsNote(_signInProblem!, color: _red),
              if (_note != null)
                SettingsNote(_note!, color: _noteIsProblem ? _red : Colors.white70),
            ],
          ),
        ),
      ],
    );
  }

  Widget _signedOut() {
    return SettingsGroup(
      footnote: 'Keeps My List, Continue Watching, your language choices and '
          'your Gemini key the same on every device you sign in on. Popcorn '
          'keeps them in a hidden file in your Google Drive that only Popcorn '
          'can open. Nothing else in your Drive is touched.',
      children: [
        SettingsRow(
          icon: Icons.login_rounded,
          title: 'Sign in with Google',
          onTap: _signingIn ? null : _signIn,
          trailing: const SettingsChevron(),
        ),
      ],
    );
  }

  Widget _signedIn(SyncStatus s) {
    return SettingsGroup(
      footnote: 'Your lists belong to your Google account: signing out takes '
          'them off this device, and signing in again brings them back.',
      children: [
        SettingsRow(
          icon: Icons.account_circle_outlined,
          title: s.email ?? 'Google account',
          subtitle: syncStatusText(s),
          subtitleColor: syncShowsProblem(s) ? _red : null,
          onTap: s.asking == null ? _syncNow : null,
          trailing: s.busy
              ? const _Spinner()
              : s.asking == null
                  ? const Icon(Icons.refresh_rounded, color: Colors.white38, size: 20)
                  : null,
        ),
        if (s.problem == SyncProblem.signInAgain && !_signingIn)
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
        _signOutRow(),
        _deleteRow(),
      ],
    );
  }

  Widget _signOutRow() {
    if (_working == 'Signing out…') {
      return const SettingsRow(
        icon: Icons.logout_rounded,
        title: 'Signing out…',
        trailing: _Spinner(),
      );
    }
    if (_confirm == _Confirm.signOut) {
      return _ConfirmPanel(
        title: 'Sign out on this device?',
        message: 'My List, Continue Watching, your language choices and your '
            'Gemini key will be removed from this device. They stay in your '
            'Google account and come back when you sign in again.',
        cancelLabel: 'Cancel',
        confirmLabel: 'Sign out',
        onCancel: () => setState(() => _confirm = _Confirm.none),
        onConfirm: () => _signOut(),
      );
    }
    if (_confirm == _Confirm.signOutUnsaved) {
      return _ConfirmPanel(
        title: "Your latest changes aren't saved yet",
        message: "They couldn't reach Google Drive (check the internet). If you "
            "sign out now, they'll be lost. Everything else stays in your "
            'Google account.',
        cancelLabel: 'Cancel',
        confirmLabel: 'Sign out anyway',
        onCancel: () => setState(() => _confirm = _Confirm.none),
        onConfirm: () => _signOut(evenIfUnsaved: true),
      );
    }
    return SettingsRow(
      icon: Icons.logout_rounded,
      title: 'Sign out',
      onTap: _working != null
          ? null
          : () => setState(() {
                _confirm = _Confirm.signOut;
                _note = null;
              }),
    );
  }

  /// "Delete synced data", asking right here before it does.
  Widget _deleteRow() {
    if (_working == 'Deleting…') {
      return const SettingsRow(
        icon: Icons.delete_outline_rounded,
        title: 'Deleting…',
        trailing: _Spinner(),
      );
    }
    if (_confirm == _Confirm.delete) {
      return _ConfirmPanel(
        title: 'Delete synced data?',
        message: 'This removes My List, Continue Watching, your language '
            'choices and your Gemini key from your Google account and from '
            'every device signed in to it. Nobody is signed out.',
        cancelLabel: 'Keep it',
        confirmLabel: 'Delete',
        onCancel: () => setState(() => _confirm = _Confirm.none),
        onConfirm: _delete,
      );
    }
    return SettingsRow(
      icon: Icons.delete_outline_rounded,
      title: 'Delete synced data',
      onTap: _working != null
          ? null
          : () => setState(() {
                _confirm = _Confirm.delete;
                _note = null;
              }),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2),
      );
}

/// An "are you sure", in place of the row it's for.
class _ConfirmPanel extends StatelessWidget {
  final String title;
  final String message;
  final String cancelLabel;
  final String confirmLabel;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _ConfirmPanel({
    required this.title,
    required this.message,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.4),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: GlassDialogButton(label: cancelLabel, onTap: onCancel)),
              const SizedBox(width: 10),
              Expanded(
                child: GlassDialogButton(
                  label: confirmLabel,
                  primary: true,
                  destructive: true,
                  onTap: onConfirm,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Just signed in, and this device has titles the account doesn't: do
/// they join the account, or go?
class _AskPanel extends StatelessWidget {
  final OnlyHere onlyHere;
  final String? working;
  final ValueChanged<bool> onAnswer;

  const _AskPanel({
    required this.onlyHere,
    required this.working,
    required this.onAnswer,
  });

  static String _titles(int n) => n == 1 ? '1 title' : '$n titles';

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (onlyHere.list > 0) '${_titles(onlyHere.list)} in My List',
      if (onlyHere.history > 0) '${_titles(onlyHere.history)} in Continue Watching',
    ];
    final one = onlyHere.list + onlyHere.history == 1;
    final it = one ? 'it' : 'them';
    return SettingsCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            one
                ? "This device has a title your account doesn't"
                : "This device has titles your account doesn't",
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '${parts.join(' and ')}. Add $it to your account to have $it on '
            'all your devices, or remove $it from this device to see only '
            'what your account has.',
            style: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.4),
          ),
          const SizedBox(height: 14),
          if (working != null)
            Row(
              children: [
                const _Spinner(),
                const SizedBox(width: 10),
                Text(working!, style: const TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            )
          else ...[
            // One above the other: side by side, the labels don't fit a
            // phone's width.
            SizedBox(
              width: double.infinity,
              child: GlassDialogButton(
                label: 'Add to my account',
                primary: true,
                onTap: () => onAnswer(true),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: GlassDialogButton(
                label: 'Remove from this device',
                onTap: () => onAnswer(false),
              ),
            ),
          ],
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
