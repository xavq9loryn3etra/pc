import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/app_mode_service.dart';
import '../services/app_update_service.dart';
import '../services/feature_flags_service.dart';
import '../services/gemini_key_service.dart';
import '../services/sync/sync_service.dart';
import '../services/torrent/download_ahead_settings.dart';
import '../services/tv_device.dart';
import '../services/visual_effects_service.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../widgets/glass_blur.dart' show GlassSwitch, kGlassEdge;
import '../widgets/mode_switch_row.dart';
import '../widgets/poster_wall.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/screen_shade.dart';
import '../widgets/settings_parts.dart';
import 'gemini_key_screen.dart';
import 'sync_settings_screen.dart';
import 'update_overlay.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: const Text('Settings'),
      bottomNavTab: BottomNavTab.settings,
      glow: TabGlow.forMode,
      actions: const [_AppVersionLabel()],
      body: (context, isDesktop, padding) {
        return ListenableBuilder(
          listenable: Listenable.merge([
            AppModeService().currentMode,
            FeatureFlagsService().hidePlayback,
            AppUpdateService().waiting,
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
            final update = AppUpdateService().waiting.value;

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
                // In the side column: 16 above the first heading (8 here,
                // and its own 8), as at the sides and the foot.
                top: SideColumnScope.inColumn(context)
                    ? 8
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
                    // A small update waiting: first, in the update
                    // screen's look.
                    if (update != null) _UpdateCard(update),
                    // No modes in the desktop app (see AppModeService).
                    if (AppModeService.canSwitchMode) ...[
                      SettingsSectionLabel('SWITCH MODE',
                          topPadding: update == null ? 8 : 24),
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
                        topPadding: AppModeService.canSwitchMode ||
                                update != null
                            ? 24
                            : 8,
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
                      topPadding: AppModeService.canSwitchMode ||
                              showStorage ||
                              update != null
                          ? 24
                          : 8,
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
                            padding: EdgeInsets.only(top: 24, bottom: 16),
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

/// A small update waiting (AppUpdateService): a compact card at the top of
/// Settings in the update screen's look — the poster wall moving behind it
/// under frost (as on the update and welcome screens), "A New Version Is
/// Ready." on one line, and a white button that opens the update's page, with what's new and "Update
/// Now". (A taller card with everything centred was too big: owner, 24 Nov
/// 2026.)
class _UpdateCard extends StatelessWidget {
  final AppUpdate update;

  const _UpdateCard(this.update);

  static const _radius = 20.0;

  @override
  Widget build(BuildContext context) {
    void open() => UpdateOverlay.openSmall(context, update);
    return Padding(
      // A phone's margins, as the other cards (SettingsCard).
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
          side: BorderSide(color: kGlassEdge),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // The artwork scrolling by under frost, as the update screen's
            // (owner, 24 Nov 2026). Where the app's glass is turned down
            // (slow, saving power, a TV): no blur, just darker.
            Positioned.fill(
              child: IgnorePointer(
                child: ValueListenableBuilder<bool>(
                  valueListenable: VisualEffectsService().reduceGlass,
                  builder: (context, reduced, wall) => reduced
                      ? wall!
                      : ImageFiltered(
                          imageFilter:
                              ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                          child: wall,
                        ),
                  child: const PosterWall(scale: 0.42),
                ),
              ),
            ),
            // Darker behind the words, lighter towards the button.
            Positioned.fill(
              child: IgnorePointer(
                child: ValueListenableBuilder<bool>(
                  valueListenable: VisualEffectsService().reduceGlass,
                  builder: (context, reduced, _) => DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.black.withValues(alpha: reduced ? 0.9 : 0.6),
                          Colors.black.withValues(alpha: reduced ? 0.7 : 0.35),
                          Colors.black.withValues(alpha: reduced ? 0.55 : 0.2),
                        ],
                        stops: const [0, 0.55, 1],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
              onTap: open,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // One line, in the app's usual font (owner, 24
                          // Nov 2026).
                          const Text(
                            'A New Version Is Ready.',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: -0.3,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Popcorn ${update.version}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.white.withValues(alpha: 0.65),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: open,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        elevation: 0,
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        "What's New",
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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
