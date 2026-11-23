import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/services/tv_device.dart';
import 'package:flutter_client/widgets/card_menu.dart';
import 'package:flutter_client/widgets/movie_poster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const anchor = Rect.fromLTWH(40, 100, 120, 180);

  Future<({List<String> chosen})> open(WidgetTester tester) async {
    final chosen = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showCardMenu(
                context,
                anchor: anchor,
                preview: const ColoredBox(
                    key: Key('preview'), color: Colors.red),
                actions: [
                  CardMenuAction(
                    label: 'More Info',
                    icon: Icons.info_outline_rounded,
                    onSelected: () => chosen.add('info'),
                  ),
                  CardMenuAction(
                    label: 'Remove from Continue Watching',
                    icon: Icons.remove_circle_outline_rounded,
                    destructive: true,
                    onSelected: () => chosen.add('remove'),
                  ),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (chosen: chosen);
  }

  testWidgets('opens with both rows, the card lifted where it was',
      (tester) async {
    await open(tester);
    expect(find.text('More Info'), findsOneWidget);
    expect(find.text('Remove from Continue Watching'), findsOneWidget);
    // The preview sits on the card's spot, a touch larger.
    final preview = tester.getRect(find.byKey(const Key('preview')));
    expect(preview.center.dx, closeTo(anchor.center.dx, 0.01));
    expect(preview.center.dy, closeTo(anchor.center.dy, 0.01));
    expect(preview.width, closeTo(anchor.width * 1.05, 0.01));
    // The menu just under it, its left edge in line with the card's.
    final menuTop = tester.getTopLeft(find.text('More Info'));
    expect(menuTop.dy, greaterThan(preview.bottom));
    expect(menuTop.dy, lessThan(preview.bottom + 40));
  });

  testWidgets('Remove closes the menu, then calls back', (tester) async {
    final r = await open(tester);
    await tester.tap(find.text('Remove from Continue Watching'));
    await tester.pumpAndSettle();
    expect(r.chosen, ['remove']);
    expect(find.text('More Info'), findsNothing);
  });

  testWidgets('More Info calls back', (tester) async {
    final r = await open(tester);
    await tester.tap(find.text('More Info'));
    await tester.pumpAndSettle();
    expect(r.chosen, ['info']);
  });

  testWidgets('a tap outside closes it, choosing nothing', (tester) async {
    final r = await open(tester);
    await tester.tapAt(const Offset(700, 560));
    await tester.pumpAndSettle();
    expect(find.text('More Info'), findsNothing);
    expect(r.chosen, isEmpty);
  });

  testWidgets('Esc closes it', (tester) async {
    final r = await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('More Info'), findsNothing);
    expect(r.chosen, isEmpty);
  });

  testWidgets('Back closes it', (tester) async {
    final r = await open(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('More Info'), findsNothing);
    expect(r.chosen, isEmpty);
  });

  group('placement', () {
    const screen = Size(400, 800);

    test('under the card when it fits', () {
      final at = placeMenu(
        screen: screen,
        card: const Rect.fromLTWH(24, 100, 120, 180),
        menu: const Size(240, 100),
      );
      expect(at, const Offset(24, 290));
    });

    test('above the card near the bottom', () {
      final at = placeMenu(
        screen: screen,
        card: const Rect.fromLTWH(24, 560, 120, 180),
        menu: const Size(240, 100),
      );
      expect(at, const Offset(24, 450));
    });

    test('kept on screen at the right edge', () {
      final at = placeMenu(
        screen: screen,
        card: const Rect.fromLTWH(300, 100, 120, 180),
        menu: const Size(240, 100),
      );
      expect(at.dx, 400 - 16 - 240);
    });

    test('beside a card too tall for above or below', () {
      final at = placeMenu(
        screen: const Size(900, 400),
        card: const Rect.fromLTWH(60, 40, 200, 300),
        menu: const Size(260, 100),
      );
      expect(at, const Offset(270, 40));
    });
  });

  group('how a poster opens its menu', () {
    Movie film() => Movie(
          id: '1',
          title: 'A Film',
          year: 2024,
          rating: '7.0',
          voteCount: 10,
          description: '',
          type: 'movie',
          inCinemas: false,
          progress: 0.4,
        );

    Future<List<Rect>> pumpPoster(WidgetTester tester) async {
      final opened = <Rect>[];
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: MoviePoster(
            movie: film(),
            showTitle: true,
            onTap: () {},
            onPlay: () {},
            onMenu: opened.add,
          ),
        ),
      ));
      return opened;
    }

    // On the picture (the card's Column runs on below its title).
    Offset onPicture(WidgetTester tester) =>
        tester.getTopLeft(find.byType(MoviePoster)) + const Offset(60, 60);

    Future<void> longPress(WidgetTester tester) async {
      await tester.longPressAt(onPicture(tester));
      await tester.pump();
    }

    Future<void> rightClick(WidgetTester tester) async {
      await tester.tapAt(onPicture(tester),
          buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pump();
    }

    tearDown(() => TvDevice.debugIsTv = false);

    testWidgets('phone: a long press, with the poster\'s rect',
        (tester) async {
      final opened = await pumpPoster(tester);
      await longPress(tester);
      expect(opened, hasLength(1));
      // The picture's rect, not the title under it.
      expect(opened.single.size, const Size(120, 180));
    });

    testWidgets('Windows: a right-click, not a long press', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final opened = await pumpPoster(tester);
        await longPress(tester);
        expect(opened, isEmpty);
        await rightClick(tester);
        expect(opened, hasLength(1));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('TV: never', (tester) async {
      TvDevice.debugIsTv = true;
      final opened = await pumpPoster(tester);
      await longPress(tester);
      await rightClick(tester);
      expect(opened, isEmpty);
    });
  });
}
