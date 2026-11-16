import 'package:flutter/material.dart';
import 'package:flutter_client/screens/search_screen.dart';
import 'package:flutter_client/services/search_history_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // With recent searches showing, the first letter's search starting hid
  // them, and the field was built anew: the phone's keyboard closed, and a
  // computer stopped taking what was typed.
  testWidgets('the field keeps focus as a search starts', (tester) async {
    SharedPreferences.setMockInitialValues({
      'search_history_v1': ['dune', 'one piece'],
    });
    await SearchHistoryService().load(force: true);
    await tester.pumpWidget(const MaterialApp(home: SearchScreen()));
    await tester.pump();
    expect(find.text('dune'), findsOneWidget); // The recent searches.

    final field = find.byType(EditableText);
    await tester.tap(field);
    await tester.pump();
    final before = tester.state<EditableTextState>(field);
    expect(before.widget.focusNode.hasFocus, isTrue);

    await tester.enterText(field, 'ba');
    // Past the pause before searching: the search starts.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    final after = tester.state<EditableTextState>(field);
    expect(identical(before, after), isTrue,
        reason: 'the field was built anew');
    expect(after.widget.focusNode.hasFocus, isTrue);
    expect(after.widget.controller.text, 'ba');
    // Let the (failing, offline) search finish.
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });

  testWidgets('nothing shows before a search', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await SearchHistoryService().load(force: true);
    await tester.pumpWidget(const MaterialApp(home: SearchScreen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('TRENDING'), findsNothing);
    expect(find.byType(Image), findsNothing);
  });
}
