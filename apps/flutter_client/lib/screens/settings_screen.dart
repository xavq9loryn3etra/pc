import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../widgets/mode_switcher_dialog.dart';
import '../widgets/shimmer_loader.dart';
import '../services/backup_service.dart';
import '../services/torrent/torrent_storage_service.dart';
import '../services/torrent/torrent_download_registry.dart';
import '../services/movie_tab_service.dart';
import '../theme/app_theme.dart';
import '../main.dart';

/// Best available estimate of how much of [entry] has actually downloaded.
/// Prefers the registry's real `totalDone`-derived figure (persisted while
/// streaming — see PlayerScreen._subscribeToTorrent); falls back to the raw
/// file size on disk only when no real progress was ever recorded (legacy
/// entries). That fallback can overstate progress for a torrent abandoned
/// early — libtorrent sparse-allocates files to their full final size the
/// moment streaming starts, so file length alone isn't reliable.
int _downloadedBytesFor(CachedTorrentEntry entry, Map<String, TorrentDownloadInfo> registry) {
  final info = registry[entry.infoHash.toLowerCase()];
  return info?.downloadedBytes ?? entry.sizeBytes;
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: const Text('Settings'),
      bottomNavTab: BottomNavTab.settings,
      body: (context, isDesktop, padding) {
        return ListView(
          padding: padding.copyWith(top: 100),
          children: [
            const SizedBox(height: 8),
            _SettingsTile(
              icon: Icons.grid_view,
              label: 'Switch Mode',
              onTap: () => showModeSwitcherDialog(context),
            ),
            _SettingsTile(
              icon: Icons.cloud_sync,
              label: 'Backup & Restore',
              onTap: () => _showBackupRestoreDialog(context),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(
                'STORAGE',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ),
            const _StorageSection(),
          ],
        );
      },
    );
  }

  void _showBackupRestoreDialog(BuildContext rootContext) {
    showDialog(
      context: rootContext,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.grey[900],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.cloud_sync, color: AppTheme.primaryColor),
            SizedBox(width: 12),
            Text('Backup & Restore', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: const Text(
          'Export your favorites and history to a file, or import them from a previously saved backup.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('CANCEL', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              final success = await _runWithLoadingDialog(
                rootContext,
                message: 'Exporting backup...',
                action: () => BackupService().exportData(),
              );
              if (success != null && rootContext.mounted) {
                ScaffoldMessenger.of(rootContext).showSnackBar(
                  SnackBar(
                    content: Text(success
                        ? 'Backup exported successfully!'
                        : 'Failed to export backup.'),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ),
                );
              }
            },
            child: const Text('EXPORT',
                style: TextStyle(color: AppTheme.primaryColor)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              final success = await _runWithLoadingDialog(
                rootContext,
                message: 'Importing backup...',
                action: () => BackupService().importData(),
              );
              if (success == null || !rootContext.mounted) return;
              if (success) {
                ScaffoldMessenger.of(rootContext).showSnackBar(
                  const SnackBar(
                    content: Text('Backup imported! Reloading app...'),
                    backgroundColor: Colors.green,
                  ),
                );
                // Restart app by navigating to main
                Future.delayed(const Duration(seconds: 1), () {
                  if (rootContext.mounted) {
                    Navigator.pushAndRemoveUntil(
                      rootContext,
                      MaterialPageRoute(builder: (_) => const MyApp()),
                      (route) => false,
                    );
                  }
                });
              } else {
                ScaffoldMessenger.of(rootContext).showSnackBar(
                  const SnackBar(
                    content: Text('Failed to import backup.'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            child: const Text('IMPORT',
                style: TextStyle(color: AppTheme.primaryColor)),
          ),
        ],
      ),
    );
  }

  /// Shows a blocking loading dialog for the duration of [action] (backup
  /// export/import previously gave no feedback at all between tapping the
  /// button and a SnackBar appearing seconds later — this fills that gap).
  /// Returns [action]'s result, or null if `context` was unmounted by the
  /// time it finished.
  Future<bool?> _runWithLoadingDialog(
    BuildContext context, {
    required String message,
    required Future<bool> Function() action,
  }) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BackupLoadingDialog(message: message),
    );
    final success = await action();
    if (!context.mounted) return null;
    Navigator.of(context).pop(); // dismiss the loading dialog
    return success;
  }
}

class _BackupLoadingDialog extends StatelessWidget {
  final String message;

  const _BackupLoadingDialog({required this.message});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: Colors.grey[900],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Row(
          children: [
            const ShimmerLoader(size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Text(message, style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
      onTap: onTap,
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
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          'Nothing cached right now. Movies and episodes you watch stay '
          'downloaded here so resuming them later is instant.',
          style: TextStyle(color: Colors.white38, fontSize: 13),
        ),
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${entries.length} cached',
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
              Text(TorrentStorageService.formatBytes(totalBytes),
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        ),
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
        child: const Icon(Icons.movie_outlined, color: Colors.white38, size: 20),
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
          child: const Icon(Icons.movie_outlined, color: Colors.white38, size: 20),
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
        downloadedBytes: info?.downloadedBytes ?? entry.sizeBytes,
        totalBytes: info?.totalBytes,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, color: Colors.white38),
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
                downloadedBytes: infos[i].downloadedBytes ?? entries[i].sizeBytes,
                totalBytes: infos[i].totalBytes,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white38),
                onPressed: () => onDelete(entries[i]),
              ),
            ),
        ],
      ),
    );
  }
}
