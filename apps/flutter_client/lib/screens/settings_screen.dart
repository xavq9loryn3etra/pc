import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../widgets/app_message.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
import '../services/torrent/torrent_storage_service.dart';
import '../services/torrent/torrent_download_registry.dart';
import '../services/movie_tab_service.dart';
import '../services/visual_effects_service.dart';
import '../services/torrent/download_ahead_settings.dart';
import '../theme/app_theme.dart';
import '../main.dart';

/// Best available figure for how much of [entry] has actually downloaded:
/// the space it really takes on disk where that can be measured (Android —
/// see CachedTorrentEntry.diskBytes); else the registry's `totalDone`
/// figure, persisted while streaming (see PlayerScreen._subscribeToTorrent)
/// but stale whenever the torrent downloaded more after the last save;
/// else, for legacy entries, the raw file size — which overstates it, as
/// libtorrent sparse-allocates files to their full size the moment
/// streaming starts.
int _downloadedBytesFor(CachedTorrentEntry entry, Map<String, TorrentDownloadInfo> registry) {
  final info = registry[entry.infoHash.toLowerCase()];
  return entry.diskBytes ?? info?.downloadedBytes ?? entry.sizeBytes;
}

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
            final showStorage =
                AppModeService().currentMode.value == AppMode.movies &&
                    !FeatureFlagsService().hidePlayback.value;

            // Grouped like Apple's settings: each section's rows on one
            // card, a short note under it, ordered by how often they're
            // likely to be used.
            return ListView(
              padding: padding.copyWith(top: 100),
              children: [
                const _SectionLabel('SWITCH MODE', topPadding: 8),
                const ModeSwitchRow(),
                if (showStorage) ...[
                  const _SectionLabel('PLAYBACK'),
                  const _SettingsGroup(
                    footnote: 'Gets a head start of about 6 MB on what '
                        "you'll likely play, so it starts sooner. On Wi-Fi "
                        'it always does.',
                    children: [_DownloadAheadRow()],
                  ),
                  const _SectionLabel('DOWNLOADS'),
                  const _StorageSection(),
                ],
                const _SectionLabel('APPEARANCE'),
                const _SettingsGroup(
                  footnote: 'A plain tint instead of the frosted blur behind '
                      'bars and buttons. Smoother on slower phones.',
                  children: [_ReduceGlassRow()],
                ),
                const _SectionLabel('BACKUP'),
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
  Navigator.of(context).pop(); // dismiss the loading dialog
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
    showAppMessage(context, 'Backup imported. Reloading the app…');
    // Restart app by navigating to main
    Future.delayed(const Duration(seconds: 1), () {
      if (context.mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const MyApp()),
          (route) => false,
        );
      }
    });
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
      // In line with the rows' content, inside their card.
      padding: EdgeInsets.fromLTRB(32, topPadding, 16, 8),
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
      padding: const EdgeInsets.symmetric(horizontal: 16),
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

class _StorageSection extends StatefulWidget {
  const _StorageSection();

  @override
  State<_StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends State<_StorageSection> {
  List<CachedTorrentEntry>? _entries;
  Map<String, TorrentDownloadInfo>? _registry;

  @override
  void initState() {
    super.initState();
    _load();
    // Settings stays mounted (offscreen) as one of MovieTabShell's tabs
    // instead of being recreated on every visit, so without this the list
    // would only ever reflect whatever was cached the first time Settings
    // was opened this session. Reload whenever the user switches back to
    // this tab instead of requiring a full app restart to see anything new.
    MovieTabService().currentTab.addListener(_onActiveTabChanged);
  }

  void _onActiveTabChanged() {
    if (MovieTabService().currentTab.value == BottomNavTab.settings) {
      _load();
    }
  }

  @override
  void dispose() {
    MovieTabService().currentTab.removeListener(_onActiveTabChanged);
    super.dispose();
  }

  Future<void> _load() async {
    final entries = await TorrentStorageService.listCached();
    final registry = await TorrentDownloadRegistry.loadAll();
    if (mounted) {
      setState(() {
        _entries = entries;
        _registry = registry;
      });
    }
  }

  Future<void> _delete(CachedTorrentEntry entry) async {
    await TorrentStorageService.delete(entry);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final registry = _registry;
    if (entries == null || registry == null) {
      return const _SettingsGroup(
        children: [
          SizedBox(
            height: 52,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ],
      );
    }

    if (entries.isEmpty) {
      return const _SettingsGroup(
        footnote: 'Movies and episodes you watch stay downloaded here, up '
            'to 2 GB, so picking them up later is instant.',
        children: [
          _SettingsRow(
            icon: Icons.download_done_rounded,
            title: 'Nothing downloaded right now',
          ),
        ],
      );
    }

    final totalBytes = entries.fold<int>(
        0, (sum, e) => sum + _downloadedBytesFor(e, registry));

    // Episodes get bundled under their show; movies (and any legacy entry
    // with no recorded identity) list individually.
    final standalone = <CachedTorrentEntry>[];
    final showGroups = <String, List<CachedTorrentEntry>>{};
    for (final entry in entries) {
      final info = registry[entry.infoHash.toLowerCase()];
      if (info != null && info.isEpisode) {
        showGroups.putIfAbsent(info.showKey, () => []).add(entry);
      } else {
        standalone.add(entry);
      }
    }
    for (final group in showGroups.values) {
      group.sort((a, b) {
        final ia = registry[a.infoHash.toLowerCase()]!;
        final ib = registry[b.infoHash.toLowerCase()]!;
        if (ia.season != ib.season) return ia.season!.compareTo(ib.season!);
        return ia.episode!.compareTo(ib.episode!);
      });
    }

    final titles = standalone.length + showGroups.length;
    return _SettingsGroup(
      footnote: '$titles title${titles == 1 ? '' : 's'} · '
          '${TorrentStorageService.formatBytes(totalBytes)} of '
          '${TorrentStorageService.formatBytes(TorrentStorageService.limitBytes)}. '
          'Past that, what you watched longest ago makes room.',
      children: [
        for (final entry in standalone)
          _DownloadTile(
            entry: entry,
            info: registry[entry.infoHash.toLowerCase()],
            onDelete: () => _delete(entry),
          ),
        for (final group in showGroups.values)
          _ShowGroupTile(
            entries: group,
            registry: registry,
            onDelete: _delete,
          ),
      ],
    );
  }
}

/// Small poster thumbnail shown next to a download/episode row. Falls back
/// to a plain icon when there's no known artwork (e.g. legacy entries
/// cached before download identity was tracked).
class _Poster extends StatelessWidget {
  final String? image;

  const _Poster({required this.image});

  @override
  Widget build(BuildContext context) {
    final url = image;
    if (url == null) {
      return Container(
        width: 40,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Icon(Icons.movie_rounded, color: Colors.white38, size: 20),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: url,
        width: 40,
        height: 56,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => Container(
          color: Colors.white10,
          child: const Icon(Icons.movie_rounded, color: Colors.white38, size: 20),
        ),
      ),
    );
  }
}

/// "X of Y downloaded · Z%" with a thin progress bar when the torrent's
/// total size is known; just the downloaded size otherwise (legacy entries,
/// or Torrentio didn't report a parseable size for that stream).
class _ProgressLine extends StatelessWidget {
  final int downloadedBytes;
  final int? totalBytes;

  const _ProgressLine({required this.downloadedBytes, required this.totalBytes});

  @override
  Widget build(BuildContext context) {
    final total = totalBytes;
    // A stored total smaller than what's actually downloaded means the
    // total is stale/wrong (see TorrentDownloadRegistry.updateProgress) —
    // showing a clamped "100%" against it would lie, so treat it the same
    // as an unknown total and just show the downloaded size.
    if (total == null || total <= 0 || downloadedBytes > total) {
      return Text(
        TorrentStorageService.formatBytes(downloadedBytes),
        style: const TextStyle(color: Colors.white38, fontSize: 12),
      );
    }

    final fraction = (downloadedBytes / total).clamp(0.0, 1.0);
    final percent = (fraction * 100).round();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${TorrentStorageService.formatBytes(downloadedBytes)} of '
            '${TorrentStorageService.formatBytes(total)} · $percent%',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 3,
              backgroundColor: Colors.white10,
              valueColor: const AlwaysStoppedAnimation(AppTheme.primaryColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final CachedTorrentEntry entry;
  final TorrentDownloadInfo? info;
  final VoidCallback onDelete;

  const _DownloadTile({
    required this.entry,
    required this.info,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final title = info?.title ??
        'Unknown download (${entry.infoHash.substring(0, 8)}…)';
    return ListTile(
      leading: _Poster(image: info?.image),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      subtitle: _ProgressLine(
        downloadedBytes: entry.diskBytes ?? info?.downloadedBytes ?? entry.sizeBytes,
        totalBytes: info?.totalBytes,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline_rounded, color: Colors.white38),
        onPressed: onDelete,
      ),
    );
  }
}

/// Bundles every cached episode of the same show under one expandable row,
/// instead of listing each episode's raw infoHash as its own top-level item.
class _ShowGroupTile extends StatelessWidget {
  final List<CachedTorrentEntry> entries;
  final Map<String, TorrentDownloadInfo> registry;
  final void Function(CachedTorrentEntry) onDelete;

  const _ShowGroupTile({
    required this.entries,
    required this.registry,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final infos =
        entries.map((e) => registry[e.infoHash.toLowerCase()]!).toList();
    final title = infos.first.title;
    final totalDownloaded = entries.fold<int>(
        0, (sum, e) => sum + _downloadedBytesFor(e, registry));

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        // No lines of its own when open: its card divides the rows.
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: EdgeInsets.zero,
        iconColor: Colors.white54,
        collapsedIconColor: Colors.white54,
        leading: _Poster(image: infos.first.image),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: Text(
          '${entries.length} episode${entries.length == 1 ? '' : 's'} · '
          '${TorrentStorageService.formatBytes(totalDownloaded)}',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
        children: [
          for (var i = 0; i < entries.length; i++)
            ListTile(
              contentPadding: const EdgeInsets.only(left: 32, right: 16),
              title: Text(
                'S${infos[i].season} E${infos[i].episode}',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              subtitle: _ProgressLine(
                downloadedBytes: _downloadedBytesFor(entries[i], registry),
                totalBytes: infos[i].totalBytes,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: Colors.white38),
                onPressed: () => onDelete(entries[i]),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Reduce glass effects": swaps the live frosted-glass blur for a plain
/// tint (see GlassBlur), for phones that stutter while scrolling.
class _ReduceGlassRow extends StatelessWidget {
  const _ReduceGlassRow();

  @override
  Widget build(BuildContext context) {
    return _SwitchRow(
      icon: Icons.blur_on_rounded,
      title: 'Reduce glass effects',
      value: VisualEffectsService().reduceGlass,
      onChanged: VisualEffectsService().setReduceGlass,
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
