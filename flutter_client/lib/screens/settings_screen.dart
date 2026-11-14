import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../widgets/app_message.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/glass_blur.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../widgets/shimmer_loader.dart';
import '../widgets/mode_switch_row.dart';
import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import '../services/backup_service.dart';
import '../services/feature_flags_service.dart';
import '../services/gemini_key_service.dart';
import '../services/torrent/download_ahead_settings.dart';
import '../widgets/gemini_key_form.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: const Text('Settings'),
      bottomNavTab: BottomNavTab.settings,
      actions: const [_AppVersionLabel()],
      body: (context, isDesktop, padding) {
        return ListenableBuilder(
          listenable: Listenable.merge([
            AppModeService().currentMode,
            FeatureFlagsService().hidePlayback,
          ]),
          builder: (context, _) {
            // Playback's one setting is about mobile data: phones and
            // tablets only — a computer's on Wi-Fi or a cable, where the
            // head start always downloads.
            final showStorage =
                AppModeService().currentMode.value == AppMode.movies &&
                    !FeatureFlagsService().hidePlayback.value &&
                    !isComputer;

            // Grouped like Apple's settings: each section's rows on one
            // card, a short note under it, ordered by how often they're
            // likely to be used.
            // On a wide window the rows keep to a readable width in the
            // middle, with the scroll bar still at the window's edge.
            final side =
                math.max(0.0, (MediaQuery.sizeOf(context).width - 720) / 2);
            final listPadding = padding.copyWith(
                // None in a wide window's side column.
                top: SideColumnScope.inColumn(context)
                    ? 0
                    : ScreenScaffold.contentTop(context),
                left: side,
                right: side);
            // The settings, then the credit and version at the tab's foot
            // (further down, if the settings are longer than the screen).
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: listPadding.copyWith(bottom: 0),
                  sliver: SliverList.list(children: [
                    // No modes in the desktop app (see AppModeService).
                    if (AppModeService.canSwitchMode) ...[
                      const _SectionLabel('SWITCH MODE', topPadding: 8),
                      const ModeSwitchRow(),
                    ],
                    if (showStorage) ...[
                      _SectionLabel(
                        'PLAYBACK',
                        topPadding: AppModeService.canSwitchMode ? 24 : 8,
                      ),
                      const _SettingsGroup(
                        footnote: 'Gets a head start of about 6 MB on what '
                            "you'll likely play, so it starts sooner. On Wi-Fi "
                            'it always does.',
                        children: [_DownloadAheadRow()],
                      ),
                    ],
                    _SectionLabel(
                      'GEMINI',
                      topPadding:
                          AppModeService.canSwitchMode || showStorage ? 24 : 8,
                    ),
                    const _SettingsGroup(
                      footnote: 'A free code from Google, needed for Popcorn '
                          'Ask and for Sinhala subtitles on anything you '
                          'watch.',
                      children: [_GeminiKeySection()],
                    ),
                    const _SectionLabel(
                      'BACKUP',
                    ),
                    _SettingsGroup(
                      footnote: 'Your favorites and watch history, saved to a '
                          'file you can bring back later.',
                      children: [
                        _SettingsRow(
                          icon: Icons.file_upload_outlined,
                          title: 'Export favorites & history',
                          onTap: () => _exportBackup(context),
                        ),
                        _SettingsRow(
                          icon: Icons.file_download_outlined,
                          title: 'Import from a backup',
                          onTap: () => _importBackup(context),
                        ),
                      ],
                    ),
                  ]),
                ),
                SliverPadding(
                  padding: EdgeInsets.only(
                      left: side, right: side, bottom: listPadding.bottom),
                  sliver: SliverFillRemaining(
                    hasScrollBody: false,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        // Where the films' and series' details and images come
                        // from, as TMDB's terms ask (the website says it too).
                        const Padding(
                          padding: EdgeInsets.fromLTRB(32, 32, 32, 0),
                          child: Text(
                            'Film and series details and images come from TMDB. '
                            'This product uses the TMDB API but is not endorsed or '
                            'certified by TMDB.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white24,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                        // At the foot instead of the app bar's corner, where the
                        // title (and so the app bar) is left out: the side column.
                        if (ScreenScaffold.hidesTitle(context))
                          const Padding(
                            padding: EdgeInsets.only(top: 24, bottom: 8),
                            child: _AppVersionLabel(),
                          )
                        else
                          const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Runs [action] (backup export/import) behind a blocking loading dialog —
/// without it there's no feedback at all between tapping the button and a
/// SnackBar appearing seconds later. Returns [action]'s result, or null if
/// `context` was unmounted by the time it finished.
Future<bool?> _runWithLoadingDialog(
  BuildContext context, {
  required String message,
  required Future<bool> Function() action,
}) async {
  showGlassDialog(
    context,
    dismissible: false,
    builder: (_) => _BackupLoadingDialog(message: message),
  );
  final success = await action();
  if (!context.mounted) return null;
  Navigator.of(context, rootNavigator: true)
      .pop(); // dismiss the loading dialog
  return success;
}

Future<void> _exportBackup(BuildContext context) async {
  final success = await _runWithLoadingDialog(
    context,
    message: 'Exporting backup...',
    action: () => BackupService().exportData(),
  );
  if (success != null && context.mounted) {
    showAppMessage(
      context,
      success ? 'Backup exported.' : "Couldn't export the backup.",
      error: !success,
    );
  }
}

Future<void> _importBackup(BuildContext context) async {
  final success = await _runWithLoadingDialog(
    context,
    message: 'Importing backup...',
    action: () => BackupService().importData(),
  );
  if (success == null || !context.mounted) return;
  if (success) {
    showAppMessage(context, 'Backup imported.');
  } else {
    showAppMessage(context, "Couldn't import the backup.", error: true);
  }
}

class _BackupLoadingDialog extends StatelessWidget {
  final String message;

  const _BackupLoadingDialog({required this.message});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const ShimmerLoader(size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// App version pulled from pubspec.yaml (via package_info_plus, which reads
/// it back out of the built app bundle) — deliberately muted/small so it
/// reads as a footnote, not a piece of the actual settings UI.
class _AppVersionLabel extends StatelessWidget {
  const _AppVersionLabel();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: Center(
        child: FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snapshot) {
            final info = snapshot.data;
            if (info == null) return const SizedBox.shrink();
            return Text(
              'v${info.version}+${info.buildNumber}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final double topPadding;

  const _SectionLabel(this.text, {this.topPadding = 24});

  @override
  Widget build(BuildContext context) {
    return Padding(
      // In line with the rows' content, inside their card (whose own
      // margin is none in a wide window's side column).
      padding: EdgeInsets.fromLTRB(
          SideColumnScope.inColumn(context) ? 16 : 32, topPadding, 16, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// One section's rows on a rounded card, divided by hairlines, with an
/// optional short note under it.
class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  final String? footnote;

  const _SettingsGroup({required this.children, this.footnote});

  // Apple's dark grouped-list grey: lifted just off the black screen.
  static const _cardColor = Color(0xFF1C1C1E);

  @override
  Widget build(BuildContext context) {
    return Padding(
      // None in a wide window's side column (the cards to its edges).
      padding: EdgeInsets.symmetric(
          horizontal: SideColumnScope.inColumn(context) ? 0 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: _cardColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    // From the rows' text, not their icon, as on iOS.
                    Divider(
                      height: 0.5,
                      thickness: 0.5,
                      indent: _SettingsRow.textInset,
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
          if (footnote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                footnote!,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A row on a [_SettingsGroup] card: an icon, a one-line title and,
/// optionally, a control or value at its end.
class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.icon,
    required this.title,
    this.trailing,
    this.onTap,
  });

  /// Where the title starts: the divider between rows lines up with it.
  static const double textInset = 16 + 22 + 14;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              Icon(icon, color: Colors.white70, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The viewer's Gemini key (see GeminiKeyService): added or not. Tapping
/// opens the steps to get one and the field for it right under the row
/// (GeminiKeyForm), and again closes them.
class _GeminiKeySection extends StatefulWidget {
  const _GeminiKeySection();

  @override
  State<_GeminiKeySection> createState() => _GeminiKeySectionState();
}

class _GeminiKeySectionState extends State<_GeminiKeySection> {
  bool _open = false;

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ValueListenableBuilder<String?>(
          valueListenable: GeminiKeyService().key,
          builder: (context, key, _) => _SettingsRow(
            icon: Icons.key_rounded,
            title: 'Gemini key',
            onTap: _toggle,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  key == null ? 'Add' : 'Added',
                  style: const TextStyle(color: Colors.white54, fontSize: 15),
                ),
                AnimatedRotation(
                  turns: _open ? 0.25 : 0,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  child: const Icon(Icons.chevron_right_rounded,
                      color: Colors.white38, size: 20),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? GeminiKeyForm(onDone: () => setState(() => _open = false))
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// "Download ahead on mobile data": lets the head start download a few MB
/// of what's likely to be played next on mobile data too (see
/// DownloadAheadSettings) — on Wi-Fi it always does.
class _DownloadAheadRow extends StatelessWidget {
  const _DownloadAheadRow();

  @override
  Widget build(BuildContext context) {
    return _SwitchRow(
      icon: Icons.downloading_rounded,
      title: 'Download ahead on mobile data',
      value: DownloadAheadSettings().onMobileData,
      onChanged: DownloadAheadSettings().setOnMobileData,
    );
  }
}

/// A setting's row with its on/off switch; tapping anywhere on the row
/// flips it. What it does is said in its group's footnote.
class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final ValueListenable<bool> value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: value,
      builder: (context, on, _) => _SettingsRow(
        icon: icon,
        title: title,
        onTap: () => onChanged(!on),
        trailing: GlassSwitch(value: on, onChanged: onChanged),
      ),
    );
  }
}
