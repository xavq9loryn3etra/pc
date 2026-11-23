import 'package:flutter/material.dart';
import 'package:flutter_client/screens/search_screen.dart';
import 'package:flutter_client/services/movie_tab_service.dart';
import 'package:flutter_client/services/search_history_service.dart';
import 'package:flutter_client/widgets/floating_bottom_nav_bar.dart';
import 'package:flutter_client/widgets/glass_text_bar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ask's and Search's text bar (GlassTextBar).
void main() {
  final tabs = MovieTabService();

  setUp(() {
    GlassTextBar.resetSession();
    tabs.currentTab.value = BottomNavTab.home;
  });
  tearDown(() => tabs.currentTab.value = BottomNavTab.home);

  Future<(TextEditingController, FocusNode)> pumpBar(WidgetTester tester,
      {BottomNavTab tab = BottomNavTab.search}) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    final bar = FocusNode();
    addTearDown(() {
      controller.dispose();
      focus.dispose();
      bar.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: GlassTextBar(
              controller: controller,
              focusNode: focus,
              barFocus: bar,
              hintText: 'Search',
              leadingIcon: Icons.close_rounded,
              leadingTooltip: 'Clear',
              onLeadingPressed: controller.clear,
              trailing: const SizedBox.square(dimension: 38),
              traceColors: const [Colors.purple],
              tab: tab,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    return (controller, focus);
  }

  Future<void> open(WidgetTester tester, BottomNavTab tab) async {
    tabs.currentTab.value = tab;
    await tester.pump(); // the tab's frame
    await tester.pump(const Duration(milliseconds: 200)); // past the delay
    await tester.pump(); // the line's first frame, if it's started
  }

  // Whether the line round the bar is running (its painter's animation).
  bool tracing(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(find.byWidgetPredicate((w) =>
        w is CustomPaint &&
        w.foregroundPainter.runtimeType.toString() == '_TracePainter'));
    final progress =
        (paint.foregroundPainter as dynamic).progress as Animation<double>;
    return progress.isAnimating;
  }

  // Till the line's lap is over.
  Future<void> lap(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 3));

  testWidgets('the line runs round the bar only on the first opening',
      (tester) async {
    await pumpBar(tester);
    expect(tracing(tester), isFalse,
        reason: 'not while the tab is hidden');

    await open(tester, BottomNavTab.search);
    expect(tracing(tester), isTrue, reason: 'first opening');
    await lap(tester);
    expect(tracing(tester), isFalse);

    await open(tester, BottomNavTab.home);
    await open(tester, BottomNavTab.search);
    expect(tracing(tester), isFalse, reason: 'second opening');

    // Ask's is its own: its first opening still has one.
    expect(GlassTextBar.takeFirstOpen(BottomNavTab.ai), isTrue);
    expect(GlassTextBar.takeFirstOpen(BottomNavTab.ai), isFalse);
  });

  testWidgets('a new session runs it again', (tester) async {
    await pumpBar(tester);
    await open(tester, BottomNavTab.search);
    await lap(tester);
    GlassTextBar.resetSession();
    await open(tester, BottomNavTab.home);
    await open(tester, BottomNavTab.search);
    expect(tracing(tester), isTrue);
    await lap(tester);
  });

  testWidgets('the field is selected each time its tab is opened',
      (tester) async {
    final (_, focus) = await pumpBar(tester);
    expect(focus.hasFocus, isFalse);

    await open(tester, BottomNavTab.search);
    expect(focus.hasFocus, isTrue);

    await open(tester, BottomNavTab.home);
    expect(focus.hasFocus, isFalse, reason: 'let go of on leaving');

    await open(tester, BottomNavTab.search);
    expect(focus.hasFocus, isTrue, reason: 'again on coming back');
    await lap(tester);
  });

  testWidgets("another tab's opening leaves it alone", (tester) async {
    final (_, focus) = await pumpBar(tester, tab: BottomNavTab.ai);
    await open(tester, BottomNavTab.search);
    expect(focus.hasFocus, isFalse);
    expect(tracing(tester), isFalse);
  });

  testWidgets("Search's ✕ shows only with text, and clears it",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await SearchHistoryService().load(force: true);
    await tester.pumpWidget(const MaterialApp(home: SearchScreen()));
    await tester.pump();
    expect(find.byTooltip('Clear'), findsNothing);

    final field = find.byType(EditableText);
    await tester.enterText(field, 'dune');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Clear'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<EditableText>(field).controller.text, isEmpty);
    expect(find.byTooltip('Clear'), findsNothing);
    // Nothing searched: the pause before searching was cut short.
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('Find something to watch'), findsOneWidget);
  });
}
