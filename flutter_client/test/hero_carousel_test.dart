import 'package:flutter/material.dart';
import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/widgets/hero_carousel.dart';
import 'package:flutter_test/flutter_test.dart';

Movie _movie(String id) => Movie(
      id: id,
      title: 'Title $id',
      year: 2026,
      rating: '0',
      voteCount: 0,
      description: '',
      type: 'movie',
      inCinemas: false,
    );

void main() {
  final movies = [for (final id in ['a', 'b', 'c']) _movie(id)];

  Widget carousel({bool paused = false, List<Movie>? list}) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: HeroCarousel(
              movies: list ?? movies,
              paused: paused,
              precache: (_, __) async {},
              background: (_, movie) =>
                  ColoredBox(color: Colors.blue, child: Text('bg ${movie.id}')),
              content: (_, movie, slide) => Center(
                child: ElevatedButton(
                  focusNode: slide.primaryFocus,
                  onPressed: () {},
                  child: Text(movie.title),
                ),
              ),
              layout: (_, strip, slides, dots) => Stack(
                fit: StackFit.expand,
                children: [
                  strip,
                  slides,
                  Positioned(bottom: 0, left: 0, right: 0, child: Center(child: dots)),
                ],
              ),
            ),
          ),
        ),
      );

  // Steps time on until [title]'s slide has landed (the last one gone),
  // checking that takes a slide's time (7s) — plus, at most, the wait for
  // the next to be ready (its details never load in a test: the longest
  // wait, 3s) and the slide over.
  Future<void> nextSlide(WidgetTester tester, String title) async {
    var elapsed = Duration.zero;
    const step = Duration(milliseconds: 100);
    while (find.textContaining('Title').evaluate().length != 1 ||
        find.text(title).evaluate().isEmpty) {
      await tester.pump(step);
      elapsed += step;
      expect(elapsed, lessThan(const Duration(seconds: 12)));
    }
    expect(elapsed, greaterThanOrEqualTo(const Duration(seconds: 7)));
  }

  testWidgets('moves on by itself and round again after the last',
      (tester) async {
    await tester.pumpWidget(carousel());
    expect(find.text('Title a'), findsOneWidget);
    await nextSlide(tester, 'Title b');
    expect(find.text('Title a'), findsNothing);
    await nextSlide(tester, 'Title c');
    await nextSlide(tester, 'Title a');
    // Only the picture in view is built once a slide's landed.
    expect(find.text('bg a'), findsOneWidget);
    expect(find.text('bg c'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('holds still while touched or paused', (tester) async {
    await tester.pumpWidget(carousel());
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(PageView)));
    await tester.pump(const Duration(seconds: 20));
    expect(find.text('Title a'), findsOneWidget);
    await gesture.up();
    await nextSlide(tester, 'Title b');

    await tester.pumpWidget(carousel(paused: true));
    await tester.pump(const Duration(seconds: 20));
    expect(find.text('Title b'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets(
      'swiping: everything moves with the finger, the pictures slower '
      'within their frames', (tester) async {
    await tester.pumpWidget(carousel());
    final width = tester.getSize(find.byType(PageView)).width;
    final textStart = tester.getCenter(find.text('Title a')).dx;
    final pictureStart = tester.getTopLeft(find.text('bg a')).dx;
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(PageView)));
    await gesture.moveBy(const Offset(-40, 0)); // past the drag slop
    await gesture.moveBy(Offset(-width * 0.2, 0));
    await tester.pump();
    final textMoved = textStart - tester.getCenter(find.text('Title a')).dx;
    final pictureMoved =
        pictureStart - tester.getTopLeft(find.text('bg a')).dx;
    // The picture moves the same way as the text, at half its speed.
    expect(textMoved, greaterThan(0));
    expect(pictureMoved, closeTo(textMoved / 2, 0.5));
    // The frames are joined, their edge where the text says.
    final frames = find.descendant(
        of: find.byType(Stack).at(1), matching: find.byType(ClipRect));
    expect(frames, findsNWidgets(2));
    final edge = tester.getTopRight(frames.first).dx;
    expect(tester.getTopLeft(frames.last).dx, closeTo(edge, 0.01));
    expect(edge, closeTo(width - textMoved, 0.5));
    // On past halfway, to land on the next slide.
    await gesture.moveBy(Offset(-width * 0.4, 0));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('Title b'), findsOneWidget);
    expect(find.text('Title a'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a dot goes to its slide', (tester) async {
    await tester.pumpWidget(carousel());
    // The dots: one per slide; the third's.
    final dots = find.descendant(
        of: find.byType(HeroDots), matching: find.byType(GestureDetector));
    expect(dots, findsNWidgets(3));
    await tester.tap(dots.at(2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text('Title c'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a remote\'s selection follows the slideshow', (tester) async {
    await tester.pumpWidget(carousel());
    final button = find.widgetWithText(ElevatedButton, 'Title a');
    tester.widget<ElevatedButton>(button).focusNode!.requestFocus();
    await tester.pump();
    await nextSlide(tester, 'Title b');
    final next = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Title b'));
    expect(next.focusNode!.hasPrimaryFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('one title: no dots, no moving', (tester) async {
    await tester.pumpWidget(carousel(list: [movies.first]));
    expect(find.byType(HeroDots), findsNothing);
    await tester.pump(const Duration(seconds: 20));
    expect(find.text('Title a'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
