import 'package:flutter/material.dart';
import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/services/tv_device.dart';
import 'package:flutter_client/widgets/movie_poster.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final movie = Movie(
    id: 'x',
    title: 'Part-watched',
    year: 2026,
    rating: '0',
    voteCount: 0,
    description: '',
    type: 'movie',
    inCinemas: false,
    progress: 0.4,
  );

  Future<(int, int)> pumpCard(WidgetTester tester) async {
    var opened = 0, played = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: MoviePoster(
            movie: movie,
            width: 200,
            height: 300,
            onTap: () => opened++,
            onPlay: () => played++,
          ),
        ),
      ),
    ));
    await tester.pump();
    final info = find.byIcon(Icons.info_outline_rounded);
    if (info.evaluate().isNotEmpty) {
      // Left of the play button.
      expect(tester.getCenter(info).dx,
          lessThan(tester.getCenter(find.byIcon(Icons.play_arrow_rounded)).dx));
      await tester.tap(info);
      await tester.pump();
    }
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    return (opened, played);
  }

  tearDown(() => TvDevice.debugIsTv = false);

  testWidgets('on a TV: an info button before play opens the title',
      (tester) async {
    TvDevice.debugIsTv = true;
    expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    final (opened, played) = await pumpCard(tester);
    expect(opened, 1);
    expect(played, 1);
  });

  testWidgets('off a TV: no info button', (tester) async {
    await pumpCard(tester);
    expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });
}
