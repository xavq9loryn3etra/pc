import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/app_mode_service.dart';
import '../services/feature_flags_service.dart';
import '../services/gemini_key_service.dart';
import '../services/sync/sync_service.dart';
import '../services/torrent/download_ahead_settings.dart';
import '../services/tv_device.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../widgets/glass_blur.dart' show GlassSwitch;
import '../widgets/mode_switch_row.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/screen_shade.dart';
import '../widgets/settings_parts.dart';
import 'gemini_key_screen.dart';
import 'sync_settings_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: const Text('Settings'),
      bottomNavTab: BottomNavTab.settings,
      glow: TabGlow.settings,
      actions: const [_AppVersionLabel()],
      body: (context, isDesktop, padding) {
        return ListenableBuilder(
          listenable: Listenable.merge([
            AppModeService().currentMode,
            FeatureFlagsService().hidePlayback,
          ]),
          builder: (context, _) {
            // Playback's one setting is about mobile data: phones and
            // tablets only — a computer or a TV is on Wi-Fi or a cable,
            // where the head start always downloads.
            final showStorage =
                AppModeService().currentMode.value.isVideo &&
                    !FeatureFlagsService().hidePlayback.value &&
                    !isComputer &&
                    !TvDevice.isTv;
            final showSync = SyncService().available;

            // Grouped like Apple's settings: each section's rows on one
            // card, a short note under it, ordered by how often they're
            // likely to be used. Sync and the Gemini key open pages of
            // their own (SettingsPage), as Apple's do.
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
                      const SettingsSectionLabel('SWITCH MODE', topPadding: 8),
                      // On a frosted panel, as on the start screen.
                      const SettingsCard(
                        radius: 24,
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: ModeSwitchRow(),
                      ),
                    ],
                    if (showStorage) ...[
                      SettingsSectionLabel(
                        'PLAYBACK',
                        topPadding: AppModeService.canSwitchMode ? 24 : 8,
                      ),
                      const SettingsGroup(
                        footnote: 'Gets a head start of about 6 MB on what '
                            "you'll likely play, so it starts sooner. On Wi-Fi "
                            'it always does.',
                        children: [_DownloadAheadRow()],
                      ),
                    ],
                    SettingsSectionLabel(
                      'GOOGLE',
                      topPadding:
                          AppModeService.canSwitchMode || showStorage ? 24 : 8,
                    ),
                    SettingsGroup(
                      children: [
                        // Only where this build can sign in to Google.
                        if (showSync) const _SyncRow(),
                        const _GeminiKeyRow(),
                      ],
                    ),
                    const SettingsSectionLabel('PRIVACY'),
                    const SettingsGroup(
                      footnote: 'When something goes wrong, Popcorn sends a '
                          'short report so it can be fixed. It never includes '
                          'your Google account or keys.',
                      children: [_CrashReportsRow()],
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

/// "Sync": on or off (red when it needs attention); opens its page.
class _SyncRow extends StatelessWidget {
  const _SyncRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SyncStatus>(
      valueListenable: SyncService().status,
      builder: (context, s, _) => SettingsRow(
        icon: Icons.sync_rounded,
        title: 'Sync',
        onTap: () => openSettingsPage(context, const SyncSettingsScreen()),
        trailing: SettingsChevron(
          value: s.on ? (s.asking != null ? 'Waiting' : 'On') : 'Off',
          valueColor: s.on && syncShowsProblem(s)
              ? const Color(0xFFFF8A80)
              : Colors.white54,
        ),
      ),
    );
  }
}

/// "Gemini key": added or not; opens its page.
class _GeminiKeyRow extends StatelessWidget {
  const _GeminiKeyRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: GeminiKeyService().key,
      builder: (context, key, _) => SettingsRow(
        icon: Icons.key_rounded,
        title: 'Gemini key',
        onTap: () => openSettingsPage(context, const GeminiKeyScreen()),
        trailing: SettingsChevron(value: key == null ? 'Add' : 'Added'),
      ),
    );
  }
}

/// "Send crash reports": always on (CrashReports), so the switch shows on,
/// greyed out, and can't be flipped (owner, 24 Nov 2026).
class _CrashReportsRow extends StatelessWidget {
  const _CrashReportsRow();

  @override
  Widget build(BuildContext context) {
    return const SettingsRow(
      icon: Icons.bug_report_outlined,
      title: 'Send crash reports',
      trailing: GlassSwitch(value: true, onChanged: null),
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

/// "Download ahead on mobile data": lets the head start download a few MB
/// of what's likely to be played next on mobile data too (see
/// DownloadAheadSettings) — on Wi-Fi it always does.
class _DownloadAheadRow extends StatelessWidget {
  const _DownloadAheadRow();

  @override
  Widget build(BuildContext context) {
    return SettingsSwitchRow(
      icon: Icons.downloading_rounded,
      title: 'Download ahead on mobile data',
      value: DownloadAheadSettings().onMobileData,
      onChanged: DownloadAheadSettings().setOnMobileData,
    );
  }
}
