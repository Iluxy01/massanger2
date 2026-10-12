import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil/app.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/theme/palette.dart';

void main() {
  testWidgets('онбординг → профиль → главный экран', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState();
    await tester.pumpWidget(VeilApp(state: state));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Пропустить'), findsOneWidget);

    state.createProfile(name: 'Тест', emoji: '🦊', colors: avatarGradients[0]);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Veil'), findsWidgets);
    expect(find.text('Алиса'), findsWidgets);

    // Открываем чат и вкладку профиля.
    await tester.tap(find.text('Алиса').first);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Сообщение'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'привет');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('привет'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
