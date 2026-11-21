part of '../player_screen.dart';

extension _PlayerTopBar on _PlayerScreenState {
  Widget _buildTopBar(BuildContext context,
          {required bool wide, required EdgeInsets safe}) =>
      Positioned(
        top: (wide ? 20 : 8) + MediaQuery.of(context).padding.top,
        left: (wide ? 28 : 16) + safe.left,
        right: (wide ? 28 : 16) + safe.right,
        child: Listener(
          onPointerDown: _markControlsPointer,
          child: Row(
            children: [
              // The details screen's back button with
              // the title's logo in a bubble grown out
              // of it (GlassBubbleBar) — out while
              // playing, back in when paused, where the
              // left panel shows the big logo instead.
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: _isPlaying ? 1.0 : 0.0),
                    duration: const Duration(milliseconds: 300),
                    builder: (context, reveal, _) => GlassBubbleBar(
                      reveal: reveal,
                      leading: CircleAvatar(
                        backgroundColor: Colors.transparent,
                        child: IconButton(
                          icon: const Icon(
                            GlassCircleButton.backIcon,
                            color: Colors.white,
                          ),
                          tooltip: MaterialLocalizations.of(context)
                              .backButtonTooltip,
                          onPressed: () => Navigator.maybePop(context),
                          iconSize: wide ? 28 : GlassCircleButton.backIconSize,
                          padding: EdgeInsets.zero,
                        ),
                      ),
                      title: MovieTitleLogo(movie: widget.details),
                    ),
                  ),
                ),
              ),
              // Download speed — a quiet line of meta
              // text, in its own ValueListenableBuilder
              // so the ~1/sec libtorrent update only
              // rebuilds this, not the whole screen.
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ValueListenableBuilder<double>(
                  valueListenable: _downloadSpeedNotifier,
                  builder: (context, speed, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.arrow_downward_rounded,
                          color: Colors.white38, size: wide ? 15 : 12),
                      const SizedBox(width: 4),
                      Text(
                        '${speed.toStringAsFixed(1)} MB/s',
                        style: TextStyle(
                            color: Colors.white54,
                            fontWeight: FontWeight.w500,
                            fontSize: wide ? 13.5 : 11),
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
