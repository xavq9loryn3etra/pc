import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../services/tv_device.dart';

/// TV remote support, part 1: the selection ring.
///
/// On a TV there's no touch or mouse: the remote's arrows move a selection
/// from one thing to the next (Flutter's focus), and OK presses it. This
/// draws one bright ring around whatever is selected, above the whole app,
/// sliding from item to item and following it as rows scroll — so every
/// button, poster and card shows it the same way, built-in or not.
///
/// It does nothing off a TV. On one, it only redraws while something is
/// moving (a new selection, a scroll, a page opening), never steadily, so
/// it costs nothing during a film.
class TvFocusRing extends StatefulWidget {
  const TvFocusRing({super.key, required this.child});

  final Widget child;

  static final _radii = Expando<double>('tvFocusRadius');
  static final _standIns = Expando<FocusNode>('tvFocusStandIn');

  /// The ring's corner radius around [node] (see TvFocusable).
  static void setRadius(FocusNode node, double radius) =>
      _radii[node] = radius;

  static VoidCallback? _follow;

  /// Has the ring follow the selected item for a moment, as it changes
  /// size or place by itself (a description opening out on OK).
  static void follow() => _follow?.call();

  /// While [node] is selected, rings [shown] instead: a text field typed
  /// into is ringed as its bar, not as the bare text inside it.
  static void setStandIn(FocusNode node, FocusNode shown) =>
      _standIns[node] = shown;

  @override
  State<TvFocusRing> createState() => _TvFocusRingState();
}

class _TvFocusRingState extends State<TvFocusRing>
    with SingleTickerProviderStateMixin {
  final _box = GlobalKey();
  late final Ticker _ticker = createTicker(_tick);
  final _ring = ValueNotifier<_Ring?>(null);

  FocusNode? _node;
  _Ring? _from; // where the current slide started
  bool _newNode = false;
  bool _poked = false;
  Duration _slideStart = Duration.zero;
  Duration _lastPoke = Duration.zero;

  static const _slide = Duration(milliseconds: 180);
  // How long it keeps following after the last movement: covers a page
  // opening or a row finishing its scroll.
  static const _settle = Duration(milliseconds: 700);

  @override
  void initState() {
    super.initState();
    if (TvDevice.isTv) {
      FocusManager.instance.addListener(_wake);
      TvFocusRing._follow = _wake;
    }
  }

  @override
  void dispose() {
    if (TvFocusRing._follow == _wake) TvFocusRing._follow = null;
    FocusManager.instance.removeListener(_wake);
    _ticker.dispose();
    _ring.dispose();
    super.dispose();
  }

  void _wake() {
    final node = FocusManager.instance.primaryFocus;
    if (!identical(node, _node)) {
      _node = node;
      _from = _ring.value;
      _newNode = true;
    }
    _poked = true;
    if (!_ticker.isActive) _ticker.start();
  }

  void _tick(Duration elapsed) {
    if (_newNode) {
      _slideStart = elapsed;
      _newNode = false;
    }
    if (_poked) {
      _lastPoke = elapsed;
      _poked = false;
    }

    final target = _target();
    if (target == null) {
      _ring.value = null;
      _from = null;
    } else {
      final t = ((elapsed - _slideStart).inMicroseconds / _slide.inMicroseconds)
          .clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(t);
      final from = _from;
      _ring.value = from == null
          // Appearing: fades in where it is.
          ? _Ring(target.rect, target.radius, eased)
          : _Ring(
              Rect.lerp(from.rect, target.rect, eased)!,
              from.radius + (target.radius - from.radius) * eased,
              1,
            );
    }

    if (elapsed - _lastPoke > _settle) _ticker.stop();
  }

  /// The selected item's outline in this widget's coordinates, or null when
  /// there's nothing to ring: no selection, or one that's a whole page
  /// (a screen listening for keys) rather than an item.
  _Ring? _target() {
    final selected = _node;
    if (selected == null || selected is FocusScopeNode) return null;
    final node = TvFocusRing._standIns[selected] ?? selected;
    final context = node.context;
    if (context == null || !context.mounted) return null;
    final box = _box.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final Rect global;
    try {
      global = node.rect;
    } catch (_) {
      return null; // Not laid out (yet, or any more).
    }
    final rect = box.globalToLocal(global.topLeft) & global.size;
    final screen = Offset.zero & box.size;
    if (rect.isEmpty || !rect.overlaps(screen)) return null;
    if (rect.width * rect.height > screen.width * screen.height * 0.5) {
      return null;
    }
    // Unless the item says (TvFocusable): small, short ones are mostly the
    // app's round and pill-shaped buttons; bigger ones cards, and long thin
    // ones list rows.
    final pill = rect.shortestSide <= 64 && rect.longestSide <= rect.shortestSide * 7;
    final radius = TvFocusRing._radii[node] ??
        context.findAncestorWidgetOfExactType<TvRingRadius>()?.radius ??
        (pill ? rect.shortestSide / 2 : 12.0);
    return _Ring(rect, radius, 1);
  }

  @override
  Widget build(BuildContext context) {
    if (!TvDevice.isTv) return widget.child;
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        _wake();
        return false;
      },
      child: Stack(
        key: _box,
        fit: StackFit.expand,
        children: [
          // The arrows' TV rules (see TvTraversalPolicy) for the whole app.
          FocusTraversalGroup(
            policy: TvTraversalPolicy(),
            child: widget.child,
          ),
          IgnorePointer(
            child: CustomPaint(painter: _RingPainter(_ring)),
          ),
        ],
      ),
    );
  }
}

class _Ring {
  const _Ring(this.rect, this.radius, this.opacity);

  final Rect rect;
  final double radius;
  final double opacity;
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.ring) : super(repaint: ring);

  final ValueNotifier<_Ring?> ring;

  static const _gap = 4.0; // between the item and the ring

  @override
  void paint(Canvas canvas, Size size) {
    final r = ring.value;
    if (r == null || r.opacity <= 0) return;
    final rrect = RRect.fromRectAndRadius(
      r.rect.inflate(_gap),
      Radius.circular(r.radius + _gap),
    );
    // A soft glow, then the ring itself.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = Colors.white.withValues(alpha: 0.35 * r.opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white.withValues(alpha: r.opacity),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.ring != ring;
}

/// TV remote support, part 3: where the arrows go, as TV apps do it.
///
/// Flutter's own rule is made for desktop forms: pressing down picked
/// whatever lined up under the selection, so from the top bar it skipped
/// the hero's buttons for a poster halfway along the row below, and the
/// page scrolled the new row only just into view, half cut off.
///
/// Here, down and up go to the nearest row below or above, to the item in
/// it closest to where the selection was; left and right only move along
/// the same row (and stay put at its end). The selected item's row is
/// scrolled to the middle of the screen, and along its own row only as far
/// as it takes to show it.
class TvTraversalPolicy extends ReadingOrderTraversalPolicy {
  TvTraversalPolicy() : super(requestFocusCallback: _reveal);

  static const _scroll = Duration(milliseconds: 260);

  static void _reveal(
    FocusNode node, {
    ScrollPositionAlignmentPolicy? alignmentPolicy,
    double? alignment,
    Duration? duration,
    Curve? curve,
  }) {
    node.requestFocus();
    final context = node.context;
    if (context == null) return;
    // As Scrollable.ensureVisible, every scrolling box it's in from the
    // inside out — but with the page centred on it.
    RenderObject? target;
    BuildContext at = context;
    var scrollable = Scrollable.maybeOf(at);
    while (scrollable != null) {
      final object = at.findRenderObject();
      if (object == null) break;
      final vertical =
          axisDirectionToAxis(scrollable.axisDirection) == Axis.vertical;
      final position = scrollable.position;
      // Near the top of the page (the home's featured title, a page's
      // first buttons): all the way back to the top, rather than centred
      // with the top cut off.
      if (vertical) {
        // What this page scrolls: the item, or the row it sits in.
        final viewport = RenderAbstractViewport.maybeOf(object);
        if (viewport != null && object is RenderBox && object.hasSize) {
          final atTop = viewport.getOffsetToReveal(object, 0.0).offset;
          if (atTop + object.size.height <=
              position.minScrollExtent + position.viewportDimension * 0.85) {
            position.animateTo(
              position.minScrollExtent,
              duration: _scroll,
              curve: Curves.easeOutCubic,
            );
            target ??= object;
            at = scrollable.context;
            scrollable = Scrollable.maybeOf(at);
            continue;
          }
        }
      }
      position.ensureVisible(
        object,
        alignment: vertical ? 0.5 : 0.0,
        alignmentPolicy: vertical
            ? ScrollPositionAlignmentPolicy.explicit
            : (alignmentPolicy ?? ScrollPositionAlignmentPolicy.keepVisibleAtEnd),
        duration: _scroll,
        curve: Curves.easeOutCubic,
        targetRenderObject: target,
      );
      target ??= object;
      at = scrollable.context;
      scrollable = Scrollable.maybeOf(at);
    }
  }

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final scope = currentNode.nearestScope;
    // Nothing selected yet: Flutter's way of picking a first item.
    if (scope == null ||
        currentNode is FocusScopeNode ||
        scope.focusedChild == null) {
      return super.inDirection(currentNode, direction);
    }
    final Rect from;
    try {
      from = currentNode.rect;
    } catch (_) {
      return super.inDirection(currentNode, direction);
    }

    var best = _best(_items(scope, currentNode), from, direction);
    // Nothing that way in a side column's page (its own navigator's, so
    // its own scope): on to what's beside the column — the nav bar above
    // it, the home to its left. Not out of a popup (a dialog, a sheet, a
    // menu): those keep the remote in them.
    if (best == null && _canLeave(scope)) {
      var outer = scope.enclosingScope;
      while (outer != null && _inPassThrough(outer)) {
        outer = outer.enclosingScope;
      }
      // Not what's under the column: the home's posters scroll beneath it.
      // And up or down, only what's over or under the column itself (the
      // nav bar): from the top of Search's empty page, up went to the
      // home's buttons beside it.
      final column = _navigatorRect(scope);
      final vertical = direction == TraversalDirection.up ||
          direction == TraversalDirection.down;
      if (outer != null) {
        best = _best(
          _items(outer, currentNode).where((e) =>
              !_inPassThrough(e.$1) &&
              !(column?.contains(e.$2.center) ?? false) &&
              (!vertical ||
                  column == null ||
                  (e.$2.right > column.left && e.$2.left < column.right))),
          from,
          direction,
        );
      }
    }
    if (best == null) return false;
    _reveal(
      best,
      alignmentPolicy: switch (direction) {
        TraversalDirection.left || TraversalDirection.up =>
          ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        _ => ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      },
    );
    return true;
  }

  // Where [scope]'s navigator (the side column) is on the screen.
  static Rect? _navigatorRect(FocusScopeNode scope) {
    final context = scope.context;
    if (context == null) return null;
    final box = Navigator.maybeOf(context)?.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  static bool _inPassThrough(FocusNode node) =>
      node.context?.findAncestorWidgetOfExactType<TvFocusPassThrough>() !=
      null;

  // A page's own scope (not a popup's, nor a menu's inside the page), in
  // a TvFocusPassThrough.
  static bool _canLeave(FocusScopeNode scope) {
    final context = scope.context;
    if (context == null || !_inPassThrough(scope)) return false;
    final route = ModalRoute.of(context);
    if (route == null || route is PopupRoute) return false;
    // A page's own scope: the one round it is another page's (a menu's
    // scope inside a page has the page's round it).
    final outer = scope.enclosingScope?.context;
    return outer == null || !identical(ModalRoute.of(outer), route);
  }

  // Items only — not the boxes that group them. (A box whose insides the
  // arrows skip, as the search bar round its text field, is an item.)
  static List<(FocusNode, Rect)> _items(
      FocusScopeNode scope, FocusNode currentNode) {
    final items = <(FocusNode, Rect)>[];
    for (final node in scope.traversalDescendants) {
      if (identical(node, currentNode) ||
          node is FocusScopeNode ||
          node.traversalDescendants.isNotEmpty ||
          node.context == null) {
        continue;
      }
      try {
        final rect = node.rect;
        if (!rect.isEmpty) items.add((node, rect));
      } catch (_) {}
    }
    return items;
  }

  static FocusNode? _best(Iterable<(FocusNode, Rect)> items, Rect from,
      TraversalDirection direction) {
    FocusNode? best;
    switch (direction) {
      case TraversalDirection.down:
      case TraversalDirection.up:
        final down = direction == TraversalDirection.down;
        // Strictly beyond the selection, by their middles.
        final beyond = items.where((e) => down
            ? e.$2.center.dy > from.bottom - 1 ||
                e.$2.top >= from.bottom - 1
            : e.$2.center.dy < from.top + 1 || e.$2.bottom <= from.top + 1);
        if (beyond.isEmpty) break;
        // The nearest row: whatever starts (or ends) closest, give or take
        // a little for items not quite aligned.
        double gap((FocusNode, Rect) e) =>
            down ? e.$2.top - from.bottom : from.top - e.$2.bottom;
        final nearest = beyond.map(gap).reduce((a, b) => a < b ? a : b);
        final row = beyond.where((e) => gap(e) <= nearest + 24);
        // In it, one that says it's the one to land on (the open tab), or
        // else the item closest to where the selection was.
        final preferred = row.where((e) =>
            e.$1.context
                ?.findAncestorWidgetOfExactType<TvPreferred>()
                ?.preferred ==
            true);
        if (preferred.isNotEmpty) {
          best = preferred.first.$1;
          break;
        }
        best = row.reduce((a, b) =>
            (a.$2.center.dx - from.center.dx).abs() <=
                    (b.$2.center.dx - from.center.dx).abs()
                ? a
                : b).$1;
      case TraversalDirection.right:
      case TraversalDirection.left:
        final right = direction == TraversalDirection.right;
        // Along the same row: overlapping it top to bottom.
        final along = items.where((e) =>
            e.$2.top < from.bottom - 1 &&
            e.$2.bottom > from.top + 1 &&
            (right
                ? e.$2.center.dx > from.center.dx + 1
                : e.$2.center.dx < from.center.dx - 1));
        if (along.isEmpty) break;
        best = along.reduce((a, b) =>
            (a.$2.center.dx - from.center.dx).abs() <=
                    (b.$2.center.dx - from.center.dx).abs()
                ? a
                : b).$1;
    }
    return best;
  }
}

/// When [preferred], the remote moving up or down to the row this control
/// is in lands on it rather than on the nearest (the nav bar's open tab).
class TvPreferred extends StatelessWidget {
  const TvPreferred({super.key, required this.preferred, required this.child});

  final bool preferred;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Marks a nested navigator (the wide layout's side column) whose pages
/// the remote may leave: with nothing further one way on its page, the
/// arrows go on to what's beside it (see TvTraversalPolicy).
class TvFocusPassThrough extends StatelessWidget {
  const TvFocusPassThrough({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// TV remote support, part 4: a text field (Search's, Ask's) on a TV.
///
/// Selecting a field with the remote would open the on-screen keyboard
/// just from passing over it, and once there, the arrows moved the cursor:
/// the remote was stuck in it. Instead the arrows select the bar round the
/// field ([barFocus]) and skip the field itself; OK on the bar opens the
/// keyboard. While the keyboard's open it takes the arrows itself; once it
/// closes (Back, or its search/send key — the screen moves the selection
/// back to [barFocus] then), the arrows leave the field for what's that
/// way, and OK opens the keyboard again.
///
/// Off a TV it's just [child], untouched.
class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    required this.field,
    required this.barFocus,
    required this.child,
    this.enabled = true,
    this.borderRadius = 26,
  });

  /// The TextField's own focus node.
  final FocusNode field;

  /// The bar's: the screen selects it after a search or a send.
  final FocusNode barFocus;

  /// The bar, with the field in it.
  final Widget child;

  /// False while the field can't be typed into (the bar can't be selected).
  final bool enabled;

  final double borderRadius;

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  @override
  void initState() {
    super.initState();
    if (TvDevice.isTv) {
      widget.field.skipTraversal = true;
      // Typing in it, the ring stays round the bar.
      TvFocusRing.setStandIn(widget.field, widget.barFocus);
    }
  }

  // Keys reach the app only while the keyboard's closed (open, it takes
  // them): the field is still selected after Back closed it.
  KeyEventResult _keyboardClosed(FocusNode node, KeyEvent event) {
    if (!widget.field.hasPrimaryFocus) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // OK opens the keyboard again — it used to type a new line instead,
    // so it took a second press.
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyDownEvent) {
        SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      }
      return KeyEventResult.handled;
    }
    final direction = switch (key) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;
    if (event is! KeyUpEvent) {
      // On to what's that way, from the bar (it looks the same selected).
      widget.barFocus.requestFocus();
      widget.barFocus.focusInDirection(direction);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!TvDevice.isTv) return widget.child;
    return TvFocusable(
      focusNode: widget.barFocus,
      borderRadius: widget.borderRadius,
      onPressed: widget.enabled ? widget.field.requestFocus : null,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _keyboardClosed,
        child: widget.child,
      ),
    );
  }
}

/// TV remote support, part 5: on a TV, selects the first thing in [child]
/// the remote can select, as it appears — a menu opening, or one of its
/// pages coming in — unless something in it is selected already (an
/// `autofocus` of its own). Without it, a menu opened over the player
/// left the remote on the button that opened it, outside the menu.
///
/// Off a TV it's just [child].
class TvAutoSelect extends StatefulWidget {
  const TvAutoSelect({super.key, required this.child});

  final Widget child;

  @override
  State<TvAutoSelect> createState() => _TvAutoSelectState();
}

class _TvAutoSelectState extends State<TvAutoSelect> {
  final _group = FocusNode(
    debugLabel: 'TvAutoSelect',
    canRequestFocus: false,
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    if (!TvDevice.isTv) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _group.hasFocus) return;
      final first = _group.traversalDescendants
          .where((node) => node.traversalDescendants.isEmpty)
          .firstOrNull;
      if (first == null) return;
      first.requestFocus();
      // In view, if it's down a list (a subtitle chosen far down it).
      final context = first.context;
      if (context != null && context.mounted) {
        Scrollable.ensureVisible(context, alignment: 0.5);
      }
    });
  }

  @override
  void dispose() {
    _group.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!TvDevice.isTv) return widget.child;
    return Focus(focusNode: _group, child: widget.child);
  }
}

/// The ring's corner radius round the controls in [child] (the nearest
/// one wins), where its guess from their size is wrong: a menu's rows,
/// short enough to be taken for pill-shaped buttons.
class TvRingRadius extends StatelessWidget {
  const TvRingRadius({super.key, required this.radius, required this.child});

  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// TV remote support: Back for what's open on the screen (a TvGroup gone
/// into), before the screen's own Back. The app's Back handler
/// (MainScreen) asks [handle] first.
class TvBack {
  TvBack._();

  static final _handlers = <bool Function()>[];

  /// [handler] is asked about each Back (latest first) until [remove]d; it
  /// returns true if it took it.
  static void add(bool Function() handler) => _handlers.add(handler);
  static void remove(bool Function() handler) => _handlers.remove(handler);

  /// True if something took this Back.
  static bool handle() {
    for (final handler in _handlers.reversed.toList()) {
      if (handler()) return true;
    }
    return false;
  }
}

/// TV remote support, part 6: a few controls the remote first selects as
/// one item — Ask's bar (new chat, the field and send) — so the arrows
/// pass it in one step. OK goes in: [enterOn] is selected (the first
/// control in it without one), and the arrows then move between them.
/// Back, or the selection leaving it, makes it one item again.
///
/// Off a TV it's just [child].
class TvGroup extends StatefulWidget {
  const TvGroup({
    super.key,
    required this.child,
    this.enterOn,
    this.borderRadius = 12,
    this.focusNode,
  });

  final Widget child;

  /// The group's own, to select it (as one item) from code.
  final FocusNode? focusNode;

  /// What OK selects in it (null: the first control in it).
  final FocusNode? Function()? enterOn;

  /// The group's outline radius, for the ring round it.
  final double borderRadius;

  @override
  State<TvGroup> createState() => _TvGroupState();
}

class _TvGroupState extends State<TvGroup> {
  FocusNode? _own;
  FocusNode get _node =>
      widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'TvGroup'));
  bool _open = false;

  @override
  void initState() {
    super.initState();
    TvFocusRing.setRadius(_node, widget.borderRadius);
    _node.addListener(_onFocus);
    TvBack._handlers.add(_back);
  }

  @override
  void didUpdateWidget(TvGroup old) {
    super.didUpdateWidget(old);
    TvFocusRing.setRadius(_node, widget.borderRadius);
  }

  @override
  void dispose() {
    TvBack._handlers.remove(_back);
    _node.removeListener(_onFocus);
    _own?.dispose();
    super.dispose();
  }

  // Left it (an arrow out of it, another screen): one item again.
  void _onFocus() {
    if (_open && !_node.hasFocus) setState(() => _open = false);
  }

  void _enter() {
    setState(() => _open = true);
    // Once its controls can be selected (the next frame).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_open) return;
      final target = widget.enterOn?.call() ??
          _node.traversalDescendants
              .where((node) => node.traversalDescendants.isEmpty)
              .firstOrNull;
      if (target == null) {
        setState(() => _open = false); // nothing in it to select
        return;
      }
      target.requestFocus();
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (_open || !_node.hasPrimaryFocus) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (event is KeyDownEvent) _enter();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // Back, inside it: out to the whole group, not the screen's Back. (It
  // can't be caught as a key: Android 13 on turns it into Back first.)
  bool _back() {
    if (!_open) return false;
    _node.requestFocus();
    setState(() => _open = false);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (!TvDevice.isTv) return widget.child;
    return Focus(
      focusNode: _node,
      // Open, it's its controls that are selected, not it.
      skipTraversal: _open,
      onKeyEvent: _onKey,
      child: ExcludeFocus(excluding: !_open, child: widget.child),
    );
  }
}

/// TV remote support, part 2: makes a custom tap area (a poster, a card,
/// anything built on GestureDetector rather than a Material button) one the
/// remote can select with the arrows and press with OK. TvFocusRing shows
/// it's selected.
///
/// Off a TV it's just [child], untouched.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.onPressed,
    required this.child,
    this.borderRadius = 12,
    this.autofocus = false,
    this.onFocusChange,
    this.focusNode,
  });

  final VoidCallback? onPressed;
  final Widget child;

  /// To select it from code; its own otherwise.
  final FocusNode? focusNode;

  /// The item's own corner radius, so the ring follows its shape.
  final double borderRadius;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  FocusNode? _own;
  FocusNode get _node =>
      widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'TvFocusable'));

  @override
  void initState() {
    super.initState();
    TvFocusRing.setRadius(_node, widget.borderRadius);
  }

  @override
  void didUpdateWidget(TvFocusable old) {
    super.didUpdateWidget(old);
    TvFocusRing.setRadius(_node, widget.borderRadius);
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!TvDevice.isTv) return widget.child;
    return FocusableActionDetector(
      focusNode: _node,
      autofocus: widget.autofocus,
      enabled: widget.onPressed != null,
      onFocusChange: widget.onFocusChange,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            // It may grow or move now (a description opening out).
            TvFocusRing.follow();
            return null;
          },
        ),
      },
      child: widget.child,
    );
  }
}
