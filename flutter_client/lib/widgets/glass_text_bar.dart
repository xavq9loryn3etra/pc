import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import '../services/movie_tab_service.dart';
import '../services/tv_device.dart';
import 'floating_bottom_nav_bar.dart' show BottomNavTab;
import 'glass_blur.dart';
import 'tv_focus.dart';

/// The text bar at the foot of Ask and Search (at the top on a TV): one
/// piece of frosted glass — a round button as tall as the field at one
/// line ([leadingIcon]: Ask's new chat, Search's clear), joined to the
/// field's rounded box by a thin neck, as the details page's back button
/// is to its title — with the field and [trailing] (send, search) in it.
///
/// The first time its [tab] is opened after the app starts, a line of
/// [traceColors] runs once round its edge; never again that session.
/// Each time the tab is opened, the field is selected, ready to type into:
/// a phone's keyboard comes up, a computer's typing goes straight in, and
/// on a TV the remote goes into the bar with the on-screen keyboard up
/// (Back closes it; the arrows then leave the field — see TvTextField).
class GlassTextBar extends StatefulWidget {
  const GlassTextBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.barFocus,
    required this.hintText,
    required this.leadingIcon,
    required this.leadingTooltip,
    required this.trailing,
    required this.traceColors,
    this.onLeadingPressed,
    this.showLeading = true,
    this.enabled = true,
    this.maxLines = 1,
    this.maxLength,
    this.textInputAction = TextInputAction.done,
    this.onChanged,
    this.onSubmitted,
    this.tab,
    this.mode,
    this.traceDelay = const Duration(milliseconds: 150),
  });

  final TextEditingController controller;

  /// The TextField's.
  final FocusNode focusNode;

  /// On a TV, the bar round the field: what the remote selects (see
  /// TvTextField). The screen selects it after a search or a send.
  final FocusNode barFocus;

  final String hintText;

  /// The round button's icon and name.
  final IconData leadingIcon;
  final String leadingTooltip;

  /// Null: the button's faded and can't be pressed (Ask's new chat while
  /// the chat's already new).
  final VoidCallback? onLeadingPressed;

  /// False: no round button, the bar a plain pill; it grows out of the
  /// bar's left end when it's shown (Search's clear, once there's text).
  final bool showLeading;

  /// At the right of the field, in a box one line tall (it stays level
  /// with the last line as the field grows).
  final Widget trailing;

  /// The line run round the bar, head to tail.
  final List<Color> traceColors;

  /// False while the field can't be typed into (Ask with no Gemini key).
  final bool enabled;

  final int maxLines;
  final int? maxLength;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// The tab the bar is on: opening it selects the field, and the first
  /// time, runs the line round it. Null: neither.
  final BottomNavTab? tab;

  /// The mode the bar's screen is in (Popcorn or Ramen): only the shown
  /// mode's bar reacts to its tab opening — the other's may still be on
  /// its way out as the mode changes.
  final AppMode? mode;

  /// How long after the tab opens the line starts: after Ask's entrance.
  final Duration traceDelay;

  // Tabs whose line has run this session (the app's process).
  static final _traced = <BottomNavTab>{};

  /// Whether [tab]'s line is still to run this session; true only once.
  static bool takeFirstOpen(BottomNavTab tab) => _traced.add(tab);

  /// A new session, as when the app starts: each tab's line runs again.
  @visibleForTesting
  static void resetSession() => _traced.clear();

  /// The bar's height at one line.
  static const double height = 52;

  @override
  State<GlassTextBar> createState() => _GlassTextBarState();
}

class _GlassTextBarState extends State<GlassTextBar>
    with SingleTickerProviderStateMixin {
  final _group = GlobalKey<TvGroupState>();
  final _groupFocus = FocusNode(debugLabel: 'Text bar');

  // The line round the edge (see _TracePainter), from somewhere new.
  late final _trace = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  double _traceStart = 0;
  Timer? _traceTimer;

  @override
  void initState() {
    super.initState();
    if (widget.tab != null) {
      MovieTabService().currentTab.addListener(_onTab);
      // Built with its tab already open (Search carried over from the
      // other mode): as if just opened.
      WidgetsBinding.instance.addPostFrameCallback((_) => _onTab());
    }
  }

  @override
  void dispose() {
    MovieTabService().currentTab.removeListener(_onTab);
    _traceTimer?.cancel();
    _trace.dispose();
    _groupFocus.dispose();
    super.dispose();
  }

  bool get _modeShown {
    final mode = widget.mode;
    final current = AppModeService().currentMode.value;
    return mode == null || !current.isVideo || current == mode;
  }

  void _onTab() {
    final tab = widget.tab;
    if (!mounted || tab == null) return;
    if (MovieTabService().currentTab.value != tab) {
      // Left: a phone's keyboard closes, a computer's typing stops coming.
      widget.focusNode.unfocus();
      return;
    }
    if (!_modeShown) return;
    // After the frame: until then the tab is still out of focus's reach
    // while hidden (see MovieTabShell).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && MovieTabService().currentTab.value == tab) _select();
    });
    if (GlassTextBar.takeFirstOpen(tab)) {
      _traceTimer?.cancel();
      _traceTimer = Timer(widget.traceDelay, () {
        if (!mounted) return;
        _traceStart = math.Random().nextDouble();
        _trace.forward(from: 0);
      });
    }
  }

  /// Selects the field, its keyboard up. On a TV, into the bar (see
  /// TvGroup) and on to the field — or, while it can't be typed into, the
  /// bar as one item.
  void _select() {
    if (TvDevice.isTv) {
      if (widget.enabled) {
        _group.currentState?.enter();
      } else {
        _groupFocus.requestFocus();
      }
    } else if (widget.enabled) {
      widget.focusNode.requestFocus();
    }
  }

  // The box's height at one line — its least — which the round button
  // matches.
  final _boxKey = GlobalKey();
  double? _lineHeight;

  void _measure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _boxKey.currentContext?.size?.height;
      if (box != null && box < (_lineHeight ?? double.infinity) - 0.5) {
        setState(() => _lineHeight = box);
      }
    });
  }

  // Tapping the cursor shows Cut, Copy and Paste, as in the phone's own
  // apps — Flutter does on Android only for a long press or a tap on the
  // handle under it: a tap on the field, already focused, that leaves
  // the cursor where it was.
  final _textKey = GlobalKey();
  TextSelection? _selectionAtTap;

  void _onFieldTap() {
    final before = _selectionAtTap;
    _selectionAtTap = null;
    if (before == null ||
        !before.isCollapsed ||
        widget.controller.selection != before) {
      return;
    }
    _editableText()?.showToolbar();
  }

  // The field's EditableText, which TextField doesn't hand out.
  EditableTextState? _editableText() {
    EditableTextState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        found = element.state as EditableTextState;
        return;
      }
      element.visitChildren(visit);
    }

    (_textKey.currentContext as Element?)?.visitChildren(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) {
    _measure();
    final d = math.max(GlassTextBar.height, _lineHeight ?? GlassTextBar.height);
    final gap = d * 0.15;
    // On a TV the remote first selects it all as one; OK goes in, to the
    // field with its keyboard open, and the arrows then move between the
    // round button, the field and the trailing button (see TvGroup).
    return TvGroup(
      key: _group,
      focusNode: _groupFocus,
      borderRadius: d / 2,
      enterOn: () => widget.enabled ? widget.focusNode : null,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: widget.showLeading ? 1 : 0),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        builder: (context, shown, _) => _bar(d, gap, shown),
      ),
    );
  }

  Widget _bar(double d, double gap, double shown) {
    final shape = JoinedBarShape(diameter: d, gap: gap, shown: shown);
    final faded = widget.onLeadingPressed == null;
    return Stack(
      // The trace's glow spills a little past the glass.
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: ClipPath(
            clipper: shape,
            child: GlassBlur(
              grouped: true,
              // Near solid without the blur (slower phones, battery
              // saver): the posters showed through sharp under the text.
              reducedTint: kGlassFieldBase,
              child: CustomPaint(
                painter: _EdgePainter(shape),
                child: ColoredBox(color: glassFieldTint(context)),
              ),
            ),
          ),
        ),
        Row(
          // Level with the field's bottom line as it grows.
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Hidden: out of reach of taps and the remote.
            IgnorePointer(
              ignoring: !widget.showLeading,
              child: ExcludeFocus(
                excluding: !widget.showLeading,
                child: SizedBox(
                  width: d * shown,
                  height: d,
                  child: shown <= 0
                      ? null
                      : Tooltip(
                          message: widget.leadingTooltip,
                          child: Material(
                            type: MaterialType.transparency,
                            child: InkWell(
                              mouseCursor: WidgetStateMouseCursor.clickable,
                              customBorder: const CircleBorder(),
                              onTap: widget.onLeadingPressed,
                              child: AnimatedOpacity(
                                opacity: faded ? 0.3 : 1,
                                duration: const Duration(milliseconds: 250),
                                child: Transform.scale(
                                  scale: shown,
                                  child: Icon(
                                    widget.leadingIcon,
                                    color: Colors.white,
                                    size: 26,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
            SizedBox(width: gap * shown),
            Expanded(
              child: Padding(
                key: _boxKey,
                padding: const EdgeInsets.fromLTRB(18, 7, 7, 7),
                child: _fieldRow(),
              ),
            ),
          ],
        ),
        // Over it all, on the glass's edge.
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                foregroundPainter: _TracePainter(
                    _trace, () => _traceStart, shape, widget.traceColors),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fieldRow() {
    return Row(
      // The trailing button stays at the bottom as the text grows.
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          // On a TV: the remote selects the field's bar and opens the
          // keyboard from it, never stuck in the field (see TvTextField).
          child: TvTextField(
            field: widget.focusNode,
            barFocus: widget.barFocus,
            enabled: widget.enabled,
            borderRadius: 19,
            // The field scrolls its own lines: not the page scrolling, for
            // the title's island (see ScreenScaffold).
            child: NotificationListener<ScrollNotification>(
              onNotification: (_) => true,
              child: Listener(
                onPointerDown: (_) => _selectionAtTap = widget.focusNode.hasFocus
                    ? widget.controller.selection
                    : null,
                child: TextField(
                  key: _textKey,
                  enabled: widget.enabled,
                  onTap: _onFieldTap,
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  minLines: 1,
                  maxLines: widget.maxLines,
                  maxLength: widget.maxLength,
                  textInputAction: widget.textInputAction,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: InputDecoration(
                    // One line, however narrow the phone: the bar stays its
                    // usual height (three lines made it tall and lumpy).
                    hintText: widget.hintText,
                    hintMaxLines: 1,
                    hintStyle: const TextStyle(color: Colors.white38),
                    border: InputBorder.none,
                    counterText: '',
                    isDense: true,
                    // The text sat low in this field (measured on a phone:
                    // 2.8 below the middle): 3 up, it's centred, and the
                    // bar is 52 high at one line.
                    contentPadding:
                        const EdgeInsets.only(top: 4.5, bottom: 10.5),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Centred in a box one line tall: in the middle of the field at
        // one line, by its last line as it grows.
        SizedBox(
          height: math.max(38, (_lineHeight ?? 0) - 14),
          child: Center(child: widget.trailing),
        ),
      ],
    );
  }
}

/// A line of [colors] running once round [shape]'s outline, from [start]
/// (a share of the way round), as [progress] goes 0 to 1: its tail growing
/// out behind its head, then fading as it finishes the lap. Drawn in short
/// pieces, each its own colour and strength, with a soft glow under them;
/// nothing at all outside the run.
class _TracePainter extends CustomPainter {
  final Animation<double> progress;
  final double Function() start;
  final JoinedBarShape shape;
  final List<Color> colors;

  _TracePainter(this.progress, this.start, this.shape, this.colors)
      : super(repaint: progress);

  Size? _size;
  List<ui.PathMetric> _metrics = const [];
  double _total = 0;

  // How much of the way round the line reaches, head to tail.
  static const _length = 0.35;
  // Short enough that its colour and strength change smoothly along it.
  static const _pieces = 60;
  static const _glowEvery = 10;

  Color _colorAt(double k) {
    if (colors.length == 1) return colors.first;
    final x = k * (colors.length - 1);
    final i = x.floor().clamp(0, colors.length - 2);
    return Color.lerp(colors[i], colors[i + 1], x - i)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0 || t >= 1 || colors.isEmpty) return;
    // The outline worked out once for the run, not every frame of it.
    if (size != _size) {
      _size = size;
      _metrics = shape.getClip(size).computeMetrics().toList();
      _total = _metrics.fold(0.0, (sum, m) => sum + m.length);
    }
    final metrics = _metrics, total = _total;
    if (total <= 0) return;

    // Once round, gently easing in and out. The tail grows out behind the
    // head, and at the end catches it up — the line drawing itself into
    // its tip as it fades, rather than stopping and fading where it was.
    final head = start() + Curves.easeInOutSine.transform(t);
    final grow = Curves.easeOut.transform(math.min(1.0, t / 0.25));
    final shrink =
        t < 0.6 ? 1.0 : 1 - Curves.easeInOutCubic.transform((t - 0.6) / 0.4);
    final fade = t < 0.7 ? 1.0 : 1 - Curves.easeIn.transform((t - 0.7) / 0.3);
    final length = _length * grow * shrink;
    if (length <= 0) return;

    // Square ends, the pieces meeting edge to edge: round ends overlapped,
    // and the overlaps showed as brighter dots along the line.
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    // The glow in a few longer stretches: blurred, their joins don't show.
    for (var i = 0; i < _pieces; i += _glowEvery) {
      final k = (i + _glowEvery / 2) / _pieces;
      canvas.drawPath(
        _piece(metrics, total, head - length * (i + _glowEvery) / _pieces,
            head - length * i / _pieces),
        glow..color = _colorAt(k).withValues(alpha: 0.4 * (1 - k) * fade),
      );
    }
    for (var i = 0; i < _pieces; i++) {
      final k = i / _pieces; // 0 at the head
      canvas.drawPath(
        _piece(metrics, total, head - length * (i + 1) / _pieces,
            head - length * i / _pieces),
        line..color = _colorAt(k).withValues(alpha: (1 - k) * fade),
      );
    }
  }

  // The outline from [from] to [to], shares of the way round (any number
  // of laps on), across its contours.
  static Path _piece(
      List<ui.PathMetric> metrics, double total, double from, double to) {
    final path = Path();
    final a = (from % 1) * total;
    final b = a + (to - from) * total;
    // Round past the end: on from the start again.
    for (final (s, e)
        in b <= total ? [(a, b)] : [(a, total), (0.0, b - total)]) {
      var offset = 0.0;
      for (final m in metrics) {
        final lo = math.max(s, offset), hi = math.min(e, offset + m.length);
        if (hi > lo) {
          path.addPath(m.extractPath(lo - offset, hi - offset), Offset.zero);
        }
        offset += m.length;
      }
    }
    return path;
  }

  @override
  bool shouldRepaint(_TracePainter old) =>
      old.progress != progress ||
      old.shape.shouldReclip(shape) ||
      !listEquals(old.colors, colors);
}

/// The round button, [diameter] across at the bottom left, and the field's
/// rounded box [gap] to its right, joined by a thin, concave neck level
/// with the circle's middle — GlassBubbleBar's shape, the box growing
/// upwards as the field does. [shown] (0 to 1) grows the button out of the
/// box's left end: at 0 the bar is the box alone, as wide as it all.
class JoinedBarShape extends CustomClipper<Path> {
  final double diameter;
  final double gap;
  final double shown;

  const JoinedBarShape({
    required this.diameter,
    required this.gap,
    this.shown = 1,
  });

  // As GlassBubbleBar's: the neck's half-thickness at its narrowest, for
  // the circle's radius, and where it meets each side, from level.
  static const _neck = 0.225;
  static const _attach = 38 * math.pi / 180;

  @override
  Path getClip(Size size) {
    final r = diameter / 2;
    final cy = size.height - r;
    final left = (diameter + gap) * shown;
    final box = Path()
      ..addRRect(RRect.fromLTRBR(
          left, 0, size.width, size.height, Radius.circular(r)));
    if (shown <= 0) return box;

    // The circle, as big as it's shown, at the left.
    final rc = r * shown;
    final circle = Path()
      ..addOval(Rect.fromCircle(center: Offset(rc, cy), radius: rc));

    final sinA = math.sin(_attach), cosA = math.cos(_attach);
    final p1 = Offset(rc + rc * cosA, cy - rc * sinA); // circle, upper
    final p2 = Offset(rc + rc * cosA, cy + rc * sinA); // circle, lower
    final q1 = Offset(left + r - r * cosA, cy - r * sinA); // box, upper
    final q2 = Offset(left + r - r * cosA, cy + r * sinA); // box, lower
    final midX = (p1.dx + q1.dx) / 2;
    final neck = rc * _neck;
    // Control points putting each curve's middle at cy ∓ neck.
    final c1y = (4 * (cy - neck) - p1.dy - q1.dy) / 2;
    final c2y = (4 * (cy + neck) - p2.dy - q2.dy) / 2;
    final bridge = Path()
      ..moveTo(p1.dx, p1.dy)
      ..quadraticBezierTo(midX, c1y, q1.dx, q1.dy)
      ..lineTo(q2.dx, q2.dy)
      ..quadraticBezierTo(midX, c2y, p2.dx, p2.dy)
      ..close();

    return Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, circle, box),
      bridge,
    );
  }

  @override
  bool shouldReclip(JoinedBarShape old) =>
      old.diameter != diameter || old.gap != gap || old.shown != shown;
}

/// The glass's faint edge, round [shape]: drawn 2px wide on its outline,
/// of which the inner 1px shows inside the clip.
class _EdgePainter extends CustomPainter {
  final JoinedBarShape shape;

  const _EdgePainter(this.shape);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      shape.getClip(size),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = kGlassEdge,
    );
  }

  @override
  bool shouldRepaint(_EdgePainter old) => shape.shouldReclip(old.shape);
}
