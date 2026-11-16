import 'package:flutter/material.dart';
import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/widgets/movie_poster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Movie film(double? progress) => Movie(
        id: '1',
        title: 'A Film',
        year: 2024,
        rating: '7.0',
        voteCount: 10,
        description: '',
        type: 'movie',
        inCinemas: false,
        progress: progress,
      );

  Future<({int taps, int plays})> pump(WidgetTester tester, double? progress,
      {bool withPlay = true, bool tapPlay = false}) async {
    var taps = 0, plays = 0;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: MoviePoster(
          movie: film(progress),
          onTap: () => taps++,
          onPlay: withPlay ? () => plays++ : null,
        ),
      ),
    ));
    if (tapPlay) {
      await tester.tap(find.byTooltip('Resume'));
      await tester.pump();
    }
    return (taps: taps, plays: plays);
  }

  testWidgets('part-way watched: a play button that plays', (tester) async {
    final r = await pump(tester, 0.4, tapPlay: true);
    expect(r.plays, 1);
    expect(r.taps, 0, reason: "the title's page mustn't open too");
  });

  testWidgets('a finger-sized button, clear of the edges', (tester) async {
    await pump(tester, 0.4);
    final poster = tester.getRect(find.byType(MoviePoster));
    final target = tester.getRect(find.byTooltip('Resume'));
    expect(target.width, 44);
    expect(target.height, 44);
    final circle = tester.getRect(find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).shape == BoxShape.circle));
    expect(circle.width, 28);
    expect(poster.bottom - circle.bottom, 8);
    expect(circle.left - poster.left, 8);
  });

  testWidgets('no play button when not started, watched, or not asked for',
      (tester) async {
    await pump(tester, null);
    expect(find.byTooltip('Resume'), findsNothing);
    await pump(tester, 0.97);
    expect(find.byTooltip('Resume'), findsNothing);
    await pump(tester, 0.4, withPlay: false);
    expect(find.byTooltip('Resume'), findsNothing);
  });
}
