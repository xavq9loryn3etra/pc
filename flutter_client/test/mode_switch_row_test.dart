import 'package:flutter/material.dart';
import 'package:flutter_client/enums/app_mode.dart';
import 'package:flutter_client/services/app_mode_service.dart';
import 'package:flutter_client/widgets/mode_switch_row.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppModeService().currentMode.value = AppMode.movies;
  });

  // The switch in Settings kept on screen across a change (as in a wide
  // window's side column): every switch after the first did nothing.
  testWidgets('switches back and forth, not just once', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SizedBox(width: 400, child: ModeSwitchRow())),
    ));
    final service = AppModeService();
    final wait = ModeOption.resize + const Duration(milliseconds: 200);

    await tester.tap(find.bySemanticsLabel(AppMode.anime.label));
    await tester.pump(wait);
    await tester.pumpAndSettle();
    expect(service.currentMode.value, AppMode.anime);

    await tester.tap(find.bySemanticsLabel(AppMode.movies.label));
    await tester.pump(wait);
    await tester.pumpAndSettle();
    expect(service.currentMode.value, AppMode.movies);

    await tester.tap(find.bySemanticsLabel(AppMode.anime.label));
    await tester.pump(wait);
    await tester.pumpAndSettle();
    expect(service.currentMode.value, AppMode.anime);
  });
}
