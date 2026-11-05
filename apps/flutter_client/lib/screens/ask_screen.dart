import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

import '../models/movie.dart';
import '../services/ai_service.dart';
import '../theme/iridescent.dart';
import '../widgets/ask_orb.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../widgets/glass_blur.dart';
import '../widgets/movie_poster.dart';
import '../widgets/screen_scaffold.dart';
import 'details_screen.dart';

/// One question asked on [AskScreen], and its answer once it's in.
class _Turn {
  final String request;
  // Its bubble, to bring into view once it's answered.
  final bubbleKey = GlobalKey();
  AiAnswer? answer;
  String? error;
  // Whether a slow model's answering (see AiService.slowFrom).
  bool slow = false;
  DateTime? answeredAt;

  _Turn(this.request);

  bool get waiting => answer == null && error == null;

  /// Whether its answer is just in, and should make its entrance — the
  /// words one by one, then the posters. Not when scrolled back to later,
  /// its posters rebuilt as they come back into view.
  bool get entering =>
      answeredAt != null &&
      DateTime.now().difference(answeredAt!) < const Duration(seconds: 4);

  /// How long its line about the picks takes to appear, word by word.
  Duration get revealTime {
    final words = answer?.message.split(RegExp(r'\s+')).length ?? 0;
    return _WordReveal.perWord * math.min(words, 45);
  }
}

/// Ask: describe what you're in the mood for, get movies and shows that
/// fit (see AiService), as a chat — each request a bubble, under it a line
/// or two about the picks and their posters, each opening its page.
/// Follow-ups ("something lighter") carry on from the questions before.
class AskScreen extends StatefulWidget {
  const AskScreen({super.key});

  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  final List<_Turn> _turns = [];

  bool get _asking => _turns.isNotEmpty && _turns.last.waiting;

  static const _examples = [
    'A feel-good movie for a rainy Sunday',
    'A short, mind-bending sci-fi series',
    'A Malayalam thriller with a big twist',
    'Something like Money Heist',
  ];

  // How far down the screen the content starts, under the title.
  static const _top = 100.0;

  // The newest question, held just under the title while it's answered:
  // its answer then comes in below it. And the room left under the
  // conversation for it to get there, when there's too little below it.
  _Turn? _pinned;
  double _room = 0;

  // No new question till the last answer's in and has made its entrance
  // (the words, then the posters); then [_unlock] rebuilds.
  DateTime _lockedUntil = DateTime(0);
  Timer? _unlock;
  bool get _locked => _asking || DateTime.now().isBefore(_lockedUntil);

  // As the keyboard opens or closes, the conversation keeps its place
  // from the bottom: what was just above the field stays just above it,
  // as in a chat app, rather than going behind the keyboard. Taken from
  // where it was as the keyboard starts to move — wherever it had been
  // scrolled to. While a question's held at the top, it stays there.
  double? _fromBottom;
  double _lastKeyboard = 0;
  DateTime _keyboardMovedAt = DateTime(0);

  void _keepFromBottom(double keyboard) {
    if (keyboard == _lastKeyboard) return;
    _lastKeyboard = keyboard;
    if (_pinned != null) {
      _afterLayout(() => _hold(animate: false));
      return;
    }
    final now = DateTime.now();
    // The first frame of a move: the list is still where it was, as the
    // layout for the new keyboard height hasn't happened yet.
    final starting =
        now.difference(_keyboardMovedAt) > const Duration(milliseconds: 400);
    _keyboardMovedAt = now;
    if (starting && _scroll.hasClients) {
      final position = _scroll.position;
      _fromBottom = position.maxScrollExtent - position.pixels;
    }
    final fromBottom = _fromBottom;
    if (fromBottom == null) return;
    _afterLayout(() {
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo((max - fromBottom).clamp(0.0, max));
    });
  }

  /// Where the list is scrolled with [turn]'s question just under the
  /// title, or null before it's laid out.
  double? _topOf(_Turn turn) {
    final bubble = turn.bubbleKey.currentContext?.findRenderObject();
    if (bubble == null) return null;
    final viewport = RenderAbstractViewport.maybeOf(bubble);
    if (viewport == null) return null;
    return viewport.getOffsetToReveal(bubble, 0).offset - _top;
  }

  /// Makes just the room needed under the conversation for the [_pinned]
  /// question to reach the top, then — unless [scroll] is false — takes it
  /// there.
  void _hold({required bool animate, bool scroll = true}) {
    final turn = _pinned;
    if (turn == null) return;
    final top = _topOf(turn);
    if (top == null) return;
    final position = _scroll.position;
    final room = math.max(0.0, top - (position.maxScrollExtent - _room));
    if ((room - _room).abs() > 1) {
      setState(() => _room = room);
      _afterLayout(() => _hold(animate: animate, scroll: scroll));
      return;
    }
    if (!scroll) return;
    final to = top.clamp(0.0, position.maxScrollExtent);
    animate
        ? _scroll.animateTo(
            to,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutCubic,
          )
        : _scroll.jumpTo(to);
  }

  @override
  void dispose() {
    _unlock?.cancel();
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ask([String? text]) async {
    final request = (text ?? _controller.text).trim();
    if (request.isEmpty || _locked) return;
    // Earlier questions that got an answer, for follow-ups.
    final history = [
      for (final t in _turns)
        if (t.answer != null) (t.request, t.answer!),
    ];
    final turn = _Turn(request);
    _controller.clear();
    _focus.unfocus();
    setState(() {
      _turns.add(turn);
      _pinned = turn;
    });
    // Up to the top, "Finding something you'll love…" under it.
    _afterLayout(() => _hold(animate: true));

    try {
      final answer = await AiService().suggest(
        request,
        history: history,
        onModel: (model) {
          if (mounted && model >= AiService.slowFrom && !turn.slow) {
            setState(() => turn.slow = true);
          }
        },
      );
      turn.answer = answer;
      if (!answer.offTopic && answer.titles.isEmpty) {
        turn.error = answer.service != null && answer.leftOut > 0
            ? "None of these are on ${answer.service} in your region right "
                'now. Try asking another way.'
            : "Couldn't find those titles. Try describing it another way.";
      }
    } on AiUnavailable catch (e) {
      turn.error = e.message;
    } catch (_) {
      turn.error =
          "Couldn't reach the AI. Check your connection and try again.";
    }
    // Gone if a new chat was started meanwhile: its answer goes too.
    if (!mounted || !_turns.contains(turn)) return;
    final entrance = turn.revealTime +
        Duration(
            milliseconds: (turn.answer?.titles.length ?? 0) * 50 +
                80 +
                _Appear.duration.inMilliseconds);
    _lockedUntil = DateTime.now().add(entrance);
    _unlock?.cancel();
    _unlock = Timer(entrance, () {
      if (mounted) setState(() {});
    });
    setState(() => turn.answeredAt = DateTime.now());
    // The answer comes in below the question, where it is; the room under
    // it shrinks to what's still needed. Then it's let go of.
    _afterLayout(() {
      _hold(animate: false, scroll: false);
      _pinned = null;
    });
  }

  /// Starts over: the conversation cleared, and with it what follow-ups
  /// would carry on from (see AiService.suggest's history). An answer
  /// still on its way is dropped when it comes.
  void _newChat() {
    _unlock?.cancel();
    _controller.clear();
    _focus.unfocus();
    setState(() {
      _turns.clear();
      _pinned = null;
      _room = 0;
      _lockedUntil = DateTime(0);
      _fromBottom = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _afterLayout(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) action();
    });
  }

  void _open(Movie movie) => Navigator.push(
        context,
        CupertinoPageRoute(builder: (_) => DetailsScreen(movie: movie)),
      );

  // The field's height, measured after each layout (it grows with longer
  // requests), so the content below the posters always clears it.
  final _fieldKey = GlobalKey();
  double _fieldHeight = 48;

  // The box's height at one line — its least — which New chat matches.
  final _boxKey = GlobalKey();
  double? _lineHeight;

  void _measureField() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final height = _fieldKey.currentContext?.size?.height;
      if (height != null && (height - _fieldHeight).abs() > 0.5) {
        setState(() => _fieldHeight = height);
      }
      final box = _boxKey.currentContext?.size?.height;
      if (box != null && box < (_lineHeight ?? double.infinity) - 0.5) {
        setState(() => _lineHeight = box);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // The keyboard covers the bottom nav bar, which isn't moved up with
    // this tab's content; the field then sits just above the keyboard.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final keyboardOpen = keyboard > 0;
    _keepFromBottom(keyboard);
    _measureField();
    return ScreenScaffold(
      bottomNavTab: BottomNavTab.ai,
      // The app's icon in its iridescent finish, as on the splash screen,
      // and its name.
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Iridescent(
            child: Image.asset(
              'assets/icon-transparent.png',
              width: 28,
              height: 28,
            ),
          ),
          const SizedBox(width: 10),
          const Text('Ask', semanticsLabel: 'Popcorn Ask'),
        ],
      ),
      body: (context, isDesktop, padding) {
        final side = isDesktop ? 60.0 : 16.0;
        // Just above the bottom nav bar's buttons: padding.bottom keeps clear
        // of its whole fade, taller than the buttons themselves.
        final fieldBottom = keyboardOpen ? 8.0 : padding.bottom - 34;
        // Room for the field, and a gap so a poster's title isn't right
        // against it.
        final contentBottom = fieldBottom + _fieldHeight + 24;
        return Stack(
          children: [
            // The glow across the top, behind everything.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.sizeOf(context).height * 0.55,
              child: IgnorePointer(child: _Glow(thinking: _asking)),
            ),
            Positioned.fill(child: _content(side, isDesktop, contentBottom)),
            Positioned(
              left: side,
              right: side,
              bottom: fieldBottom,
              child: KeyedSubtree(key: _fieldKey, child: _field()),
            ),
          ],
        );
      },
    );
  }

  Widget _content(double side, bool isDesktop, double bottom) {
    final grid = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: isDesktop ? 200 : 150,
      childAspectRatio: isDesktop ? (200 / 340) : 0.58,
      crossAxisSpacing: isDesktop ? 16 : 12,
      mainAxisSpacing: isDesktop ? 16 : 12,
    );
    return GestureDetector(
      onTap: _focus.unfocus,
      behavior: HitTestBehavior.translucent,
      child: CustomScrollView(
        controller: _scroll,
        // Scrolling leaves the keyboard open, so earlier answers can be
        // looked back over while typing.
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: _top)),
          if (_turns.isEmpty)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: side),
              sliver: SliverToBoxAdapter(child: _intro()),
            ),
          for (final turn in _turns) ...[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 8, side, 14),
              sliver: SliverToBoxAdapter(child: _Appear(child: _bubble(turn))),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 0, side, 16),
              sliver: SliverToBoxAdapter(
                // Anew when the answer replaces "Finding picks…".
                child: _Appear(
                  key: ValueKey(turn.waiting),
                  child: _reply(turn),
                ),
              ),
            ),
            if (turn.answer?.titles.isNotEmpty ?? false)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(side, 0, side, 28),
                sliver: SliverGrid.builder(
                  gridDelegate: grid,
                  itemCount: turn.answer!.titles.length,
                  itemBuilder: (context, i) {
                    final movie = turn.answer!.titles[i];
                    // One after another, after the line about them.
                    return _Appear(
                      animate: turn.entering,
                      delay:
                          turn.revealTime + Duration(milliseconds: 80 + 50 * i),
                      child: MoviePoster(
                        movie: movie,
                        showTitle: true,
                        width: double.infinity,
                        height: double.infinity,
                        onTap: () => _open(movie),
                      ),
                    );
                  },
                ),
              ),
          ],
          // Under the latest answer, once it's in.
          if (_turns.isNotEmpty && !_turns.last.waiting)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 0, side, 8),
              sliver: SliverToBoxAdapter(
                child: _Appear(
                  key: ValueKey(_turns.length),
                  animate: _turns.last.entering,
                  delay: _turns.last.revealTime +
                      Duration(
                          milliseconds: 200 +
                              50 * (_turns.last.answer?.titles.length ?? 0)),
                  child: _disclaimer(),
                ),
              ),
            ),
          SliverToBoxAdapter(child: SizedBox(height: bottom + _room)),
        ],
      ),
    );
  }

  // A quiet word that answers can be wrong, after Ask's name on a little
  // badge of the app icon's colours.
  Widget _disclaimer() {
    const silver = Color(0xFFE3E5EA);
    return Row(
      children: [
        CustomPaint(
          painter: const _BadgePainter(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 3, 9, 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/icon-transparent.png',
                  width: 13,
                  height: 13,
                  color: silver,
                ),
                const SizedBox(width: 4),
                const Text(
                  'Ask',
                  style: TextStyle(
                    color: silver,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        const Flexible(
          child: Text(
            'is AI and can make mistakes.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      ],
    );
  }

  // The request, as a chat bubble on the right.
  Widget _bubble(_Turn turn) {
    return Align(
      key: turn.bubbleKey,
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.75,
        ),
        // A soft pill, its light tint letting the glow show through.
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.11),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Text(
              turn.request,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                height: 1.35,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // What came back for [turn]: still looking, the AI's line about its
  // picks, or what went wrong.
  Widget _reply(_Turn turn) {
    if (turn.waiting) return _status(turn.slow);
    if (turn.error != null) return _note(turn.error!);
    final answer = turn.answer!;
    final leftOut = answer.leftOut;
    // As the user typed it, "netflix" maybe: capitalised.
    final named = answer.service ?? '';
    final service =
        named.isEmpty ? named : named[0].toUpperCase() + named.substring(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (answer.message.isNotEmpty)
          _WordReveal(
            text: answer.message,
            animate: turn.entering,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              height: 1.4,
            ),
          ),
        if (leftOut > 0 || answer.noneOnService) ...[
          const SizedBox(height: 6),
          Text(
            answer.noneOnService
                ? "These aren't on $service in your country right now, but "
                    'you can still watch them here.'
                : leftOut == 1
                    ? "I found 1 more, but it isn't on $service in your "
                        "country right now, so I've left it out."
                    : "I found $leftOut more, but they aren't on $service in "
                        "your country right now, so I've left them out.",
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ],
    );
  }

  // New chat and the field, one piece of frosted glass: a circle as tall
  // as the field at one line, joined to it by a thin neck, as the details
  // page's back button is to its title. The posters blur softly through
  // it as they scroll under. Grouped with the nav bar's glass, which it
  // never overlaps.
  Widget _field() {
    final d = _lineHeight ?? 52;
    final gap = d * 0.15;
    final shape = _JoinedShape(diameter: d, gap: gap);
    final enabled = _turns.isNotEmpty;
    return Stack(
      children: [
        Positioned.fill(
          child: ClipPath(
            clipper: shape,
            child: GlassBlur(
              grouped: true,
              // Near solid without the blur (slower phones, battery
              // saver): the posters showed through sharp under the text.
              reducedTint: const Color(0xEB141416),
              child: CustomPaint(
                painter: _EdgePainter(shape),
                child: const ColoredBox(color: kGlassTint),
              ),
            ),
          ),
        ),
        Row(
          // Level with the field's bottom line as it grows.
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Faded and untappable while the chat's already new.
            Tooltip(
              message: 'New chat',
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: enabled ? _newChat : null,
                  child: SizedBox.square(
                    dimension: d,
                    child: AnimatedOpacity(
                      opacity: enabled ? 1 : 0.3,
                      duration: const Duration(milliseconds: 250),
                      child: const Icon(
                        Icons.add_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(width: gap),
            Expanded(
              child: Padding(
                key: _boxKey,
                padding: const EdgeInsets.fromLTRB(16, 5, 5, 5),
                child: _fieldRow(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _fieldRow() {
    return Row(
      // Send stays at the bottom as the text grows.
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          // The field scrolls its own lines: not the page scrolling, for
          // the title's island (see ScreenScaffold).
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) => true,
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              minLines: 1,
              maxLines: 4,
              maxLength: 300,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _ask(),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                hintText: "What's up?",
                hintStyle: TextStyle(color: Colors.white38),
                border: InputBorder.none,
                counterText: '',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: _locked ? null : _ask,
          icon: const Icon(Icons.arrow_upward_rounded, size: 20),
          style: IconButton.styleFrom(
            fixedSize: const Size(36, 36),
            minimumSize: const Size(36, 36),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            disabledBackgroundColor: Colors.white24,
          ),
        ),
      ],
    );
  }

  Widget _intro() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'What are we watching?',
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          "Tell me the vibe, the occasion or a show you loved, and I'll "
          'find you something great.',
          style: TextStyle(color: Colors.white60, fontSize: 15, height: 1.4),
        ),
        const SizedBox(height: 22),
        Wrap(
          spacing: 8,
          runSpacing: 10,
          children: [
            for (final (i, example) in _examples.indexed)
              _Appear(
                delay: Duration(milliseconds: 60 * i),
                child: _ExamplePill(text: example, onTap: () => _ask(example)),
              ),
          ],
        ),
      ],
    );
  }

  Widget _status(bool slow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: _Thinking(),
        ),
        if (slow)
          const Text(
            'Still looking. This can take up to a minute right now…',
            style: TextStyle(color: Colors.white54, fontSize: 14),
          ),
      ],
    );
  }

  Widget _note(String text, {bool strong = false}) {
    return Text(
      text,
      style: TextStyle(
        color: strong ? Colors.white : Colors.white70,
        fontSize: 15,
        height: 1.4,
      ),
    );
  }
}

/// [child] fading in and rising a little into place, after [delay] — once,
/// when it's first built.
class _Appear extends StatelessWidget {
  final Widget child;
  final Duration delay;

  /// Whether to make the entrance at all, rather than just show [child].
  final bool animate;

  const _Appear({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.animate = true,
  });

  static const duration = Duration(milliseconds: 380);

  @override
  Widget build(BuildContext context) {
    if (!animate) return child;
    final total = delay + duration;
    final start = delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 14),
          child: child,
        ),
      ),
    );
  }
}

/// The disclaimer's badge: a pill of the app icon's colours (see
/// AppIridescence), faint enough for its silver text, with a brighter edge.
class _BadgePainter extends CustomPainter {
  const _BadgePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final pill = RRect.fromRectAndRadius(rect, Radius.circular(size.height));
    canvas.drawRRect(
      pill,
      Paint()..shader = AppIridescence.sweep(rect, opacity: 0.22),
    );
    canvas.drawRRect(
      pill.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..shader = AppIridescence.sweep(rect, opacity: 0.6),
    );
  }

  @override
  bool shouldRepaint(_BadgePainter old) => false;
}

/// New chat's circle, [diameter] across at the bottom left, and the
/// field's rounded box [gap] to its right, joined by a thin, concave neck
/// level with the circle's middle — GlassBubbleBar's shape, the box
/// growing upwards as the field does.
class _JoinedShape extends CustomClipper<Path> {
  final double diameter;
  final double gap;

  const _JoinedShape({required this.diameter, required this.gap});

  // As GlassBubbleBar's: the neck's half-thickness at its narrowest, for
  // the circle's radius, and where it meets each side, from level.
  static const _neck = 0.225;
  static const _attach = 38 * math.pi / 180;

  @override
  Path getClip(Size size) {
    final r = diameter / 2;
    final cy = size.height - r;
    final circle = Path()
      ..addOval(Rect.fromCircle(center: Offset(r, cy), radius: r));
    final left = diameter + gap;
    final box = Path()
      ..addRRect(RRect.fromLTRBR(
          left, 0, size.width, size.height, Radius.circular(r)));

    final sinA = math.sin(_attach), cosA = math.cos(_attach);
    final p1 = Offset(r + r * cosA, cy - r * sinA); // circle, upper
    final p2 = Offset(r + r * cosA, cy + r * sinA); // circle, lower
    final q1 = Offset(left + r - r * cosA, cy - r * sinA); // box, upper
    final q2 = Offset(left + r - r * cosA, cy + r * sinA); // box, lower
    final midX = (p1.dx + q1.dx) / 2;
    final neck = r * _neck;
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
  bool shouldReclip(_JoinedShape old) =>
      old.diameter != diameter || old.gap != gap;
}

/// The glass's faint edge, round [shape]: drawn 2px wide on its outline,
/// of which the inner 1px shows inside the clip.
class _EdgePainter extends CustomPainter {
  final _JoinedShape shape;

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

// The app's colours, as on Ask's button (see FloatingBottomNavBar):
// Popcorn's cream, Library's tan and Groovy's pink.
const _cream = Color(0xFFFDEDAD);
const _tan = Color(0xFFD4A574);
const _pink = Color(0xFFE91E63);

/// The soft glow across the top of Ask, after Gemini's: the app's
/// colours fading down into black, drifting slowly about (on AskClock,
/// with the orbs), and breathing while [thinking]. Plain gradients, drawn
/// straight — no layers.
class _Glow extends StatefulWidget {
  final bool thinking;

  const _Glow({required this.thinking});

  @override
  State<_Glow> createState() => _GlowState();
}

class _GlowState extends State<_Glow> with SingleTickerProviderStateMixin {
  late final _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  final _clock = AskClockSubscription();

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clock.update(context);
  }

  @override
  void didUpdateWidget(_Glow old) {
    super.didUpdateWidget(old);
    if (old.thinking != widget.thinking) _follow();
  }

  void _follow() {
    if (widget.thinking) {
      _breath.repeat(reverse: true);
    } else {
      _breath.animateBack(0, duration: const Duration(milliseconds: 600));
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
      painter: _GlowPainter(_breath, AskClock.time), size: Size.infinite);
}

class _GlowPainter extends CustomPainter {
  final Animation<double> breath;
  final ValueListenable<double> time;

  _GlowPainter(this.breath, this.time)
      : super(repaint: Listenable.merge([breath, time]));

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final t = Curves.easeInOut.transform(breath.value);
    // Brighter, and reaching a little further, on each breath in.
    final strength = 0.75 + 0.35 * t;
    final seconds = time.value;
    for (final (i, (color, alpha, x, reach)) in [
      (_pink, 0.30, 0.15, 0.95),
      (_tan, 0.30, 0.6, 1.0),
      (_cream, 0.16, 0.95, 0.85),
    ].indexed) {
      // Each drifting slowly side to side and swelling a little, on its
      // own pace (a sway every 20–30 seconds).
      final a = seconds * 2 * math.pi / (20 + 5 * i) + i * 2.1;
      final centre = Offset(
          w * (x + 0.12 * math.sin(a)), -h * (0.12 + 0.04 * math.cos(a)));
      final radius = h * reach * (1 + 0.08 * t + 0.06 * math.sin(a * 0.8));
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [
            color.withValues(alpha: alpha * strength),
            color.withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: centre, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.breath != breath;
}

/// "Finding something you'll love…", with a soft band of the app's
/// colours sweeping slowly across it: the AI thinking. Painted straight
/// into the letters (a shader on the text's paint) — no layer.
class _Thinking extends StatefulWidget {
  const _Thinking();

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking>
    with SingleTickerProviderStateMixin {
  late final _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(constraints.maxWidth, 280.0);
        return AnimatedBuilder(
          animation: _sweep,
          builder: (context, _) {
            // The band crossing from just off the left to just off the
            // right, eased so it lingers less at the ends.
            final x =
                -width + 2 * width * Curves.easeInOut.transform(_sweep.value);
            return Text(
              "Finding something you'll love…",
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                foreground: Paint()
                  ..shader = const LinearGradient(
                    colors: [
                      Colors.white38,
                      _cream,
                      _pink,
                      _tan,
                      Colors.white38,
                    ],
                    stops: [0.1, 0.35, 0.5, 0.65, 0.9],
                  ).createShader(Rect.fromLTWH(x, 0, width, 20)),
              ),
            );
          },
        );
      },
    );
  }
}

/// [text] appearing a word at a time, each fading in, as replies do in
/// chat apps. The whole text is laid out from the start, unseen words
/// clear, so lines don't reflow as it fills in.
class _WordReveal extends StatefulWidget {
  final String text;
  final TextStyle style;
  final bool animate;

  const _WordReveal({
    required this.text,
    required this.style,
    this.animate = true,
  });

  static const perWord = Duration(milliseconds: 38);

  @override
  State<_WordReveal> createState() => _WordRevealState();
}

class _WordRevealState extends State<_WordReveal>
    with SingleTickerProviderStateMixin {
  late final List<String> _words =
      widget.text.split(RegExp(r'(?<=\s)')); // Each keeps its space.
  late final _shown = AnimationController(
    vsync: this,
    // Each word takes [perWord]; a few more' time to fade in the last.
    duration: _WordReveal.perWord * (_words.length + 4),
  );

  @override
  void initState() {
    super.initState();
    widget.animate ? _shown.forward() : _shown.value = 1;
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.style.color ?? Colors.white;
    return AnimatedBuilder(
      animation: _shown,
      builder: (context, _) {
        // How many words are in, the last of them partly faded in.
        final shown = _shown.value * (_words.length + 4) - 1;
        return Text.rich(
          TextSpan(
            style: widget.style,
            children: [
              for (final (i, word) in _words.indexed)
                TextSpan(
                  text: word,
                  style: TextStyle(
                    color: color.withValues(
                        alpha: color.a * ((shown - i) / 4).clamp(0.0, 1.0)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// An idea to start from on Ask's empty screen: a pill of the app's
/// frosted glass (as the bottom nav bar's buttons), the glow behind
/// showing softly through. Grouped with the other glass: none overlap.
class _ExamplePill extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const _ExamplePill({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const shape = StadiumBorder();
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(100)),
      child: GlassBlur(
        grouped: true,
        reducedTint: Colors.black.withValues(alpha: 0.45),
        child: Material(
          color: kGlassTint,
          shape: shape.copyWith(side: BorderSide(color: kGlassEdge)),
          child: InkWell(
            onTap: onTap,
            customBorder: shape,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                text,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
