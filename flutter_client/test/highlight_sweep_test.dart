import 'package:flutter/material.dart';
import 'package:flutter_client/widgets/highlight_sweep.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget at(int trigger) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            height: 150,
            child: HighlightSweep(
              trigger: trigger,
              radius: 16,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

  Finder sweep() => find.descendant(
        of: find.byType(HighlightSweep),
        matching: find.byType(CustomPaint),
      );

  testWidgets('sweeps only when triggered, then goes', (tester) async {
    await tester.pumpWidget(at(0));
    expect(sweep(), findsNothing);

    await tester.pumpWidget(at(1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(sweep(), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(sweep(), findsNothing);
  });
}
