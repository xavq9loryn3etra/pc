import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/feature_flags_service.dart';

/// What's new in an update, on the update pages (StatusScreen.notes): the
/// releases' notes as short lines on a soft panel, as wide as the button
/// under it. Longer than the room it's given, it scrolls inside the panel
/// (fading at the edge with more to see) while the page stays put. A TV
/// remote can come up to it from the button and scroll it with up/down.
class ReleaseNotesBox extends StatefulWidget {
  /// Newest first. With more than one, each gets its version above it.
  final List<ReleaseNotes> releases;

  /// Bigger text, as the page's own on a wide window or a tablet.
  final bool large;

  const ReleaseNotesBox({
    super.key,
    required this.releases,
    this.large = false,
  });

  @override
  State<ReleaseNotesBox> createState() => _ReleaseNotesBoxState();
}

class _ReleaseNotesBoxState extends State<ReleaseNotesBox> {
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'Release notes');
  bool _scrollable = false;
  bool _atStart = true;
  bool _atEnd = true;
  bool _focused = false;

  static const _radius = 16.0;
  static const _fade = 28.0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _onMetrics(ScrollMetrics m) {
    final scrollable = m.maxScrollExtent > 0;
    final atStart = m.pixels <= m.minScrollExtent + 1;
    final atEnd = m.pixels >= m.maxScrollExtent - 1;
    if (scrollable != _scrollable || atStart != _atStart || atEnd != _atEnd) {
      // Not during layout: after this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _scrollable = scrollable;
          _atStart = atStart;
          _atEnd = atEnd;
        });
      });
    }
    return false;
  }

  /// The remote's up/down scroll the notes; at their end, up/down move on
  /// (to the button, say) as usual.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_scroll.hasClients) return KeyEventResult.ignored;
    final p = _scroll.position;
    final step = widget.large ? 120.0 : 80.0;
    double? to;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
        p.pixels < p.maxScrollExtent - 1) {
      to = (p.pixels + step).clamp(0.0, p.maxScrollExtent);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
        p.pixels > p.minScrollExtent + 1) {
      to = (p.pixels - step).clamp(0.0, p.maxScrollExtent);
    }
    if (to == null) return KeyEventResult.ignored;
    _scroll.animateTo(to,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final large = widget.large;
    final text = TextStyle(
      fontSize: large ? 16 : 14,
      height: 1.4,
      color: Colors.white.withValues(alpha: 0.85),
    );
    final heading = TextStyle(
      fontSize: large ? 14 : 12.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
      color: Colors.white.withValues(alpha: 0.55),
    );
    final several = widget.releases.length > 1;

    final content = Padding(
      padding: EdgeInsets.fromLTRB(16, large ? 16 : 14, 16, large ? 16 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var r = 0; r < widget.releases.length; r++) ...[
            if (several)
              Padding(
                padding: EdgeInsets.only(top: r == 0 ? 0 : 14, bottom: 6),
                child: Text('Popcorn ${widget.releases[r].version}',
                    style: heading),
              ),
            for (final note in widget.releases[r].notes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•  ', style: text),
                    Expanded(child: Text(note, style: text)),
                  ],
                ),
              ),
          ],
        ],
      ),
    );

    Widget scroller = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _onMetrics(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _onMetrics(n.metrics),
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: _scrollable,
          radius: const Radius.circular(4),
          child: SingleChildScrollView(
            controller: _scroll,
            child: content,
          ),
        ),
      ),
    );

    // More above or below: that edge fades out.
    if (_scrollable) {
      scroller = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _atStart ? Colors.black : Colors.transparent,
            Colors.black,
            Colors.black,
            _atEnd ? Colors.black : Colors.transparent,
          ],
          stops: [
            0,
            (_fade / rect.height).clamp(0.0, 0.5),
            (1 - _fade / rect.height).clamp(0.5, 1.0),
            1,
          ],
        ).createShader(rect),
        child: scroller,
      );
    }

    return ConstrainedBox(
      // As wide as the button under it (StatusPrimaryButton).
      constraints: const BoxConstraints(maxWidth: 400),
      child: Focus(
        focusNode: _focus,
        // Only worth landing on when there's more to scroll to.
        canRequestFocus: _scrollable,
        skipTraversal: !_scrollable,
        onKeyEvent: _onKey,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(
              color: Colors.white.withValues(alpha: _focused ? 0.7 : 0.1),
              width: _focused ? 2 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius),
            child: scroller,
          ),
        ),
      ),
    );
  }
}
