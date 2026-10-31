import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bookoo_brew/main.dart';
import 'package:bookoo_brew/settings.dart';

void main() {
  testWidgets('web configuration mode removes duplicate credential inputs', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings()
      ..supabaseUrl = 'https://old.invalid'
      ..supabaseKey = 'private-fixture-key'
      ..userId = ' exact-user ';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            settings: settings,
            useWebConnection: true,
            webConnectionStatus: '已读取网页配置',
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('web-connection-status')),
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('使用网页配置'), findsOneWidget);
    expect(find.text('已读取网页配置'), findsOneWidget);
    expect(find.byKey(const ValueKey('supabase-url-field')), findsNothing);
    expect(find.byKey(const ValueKey('supabase-key-field')), findsNothing);
    expect(find.byKey(const ValueKey('supabase-user-id-field')), findsNothing);
    final field = find.byKey(const ValueKey('brew-guide-url-field'));
    await tester.enterText(field, 'https://new-web.invalid/');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.brewGuideUrl, 'https://new-web.invalid/');
    expect(settings.supabaseUrl, 'https://old.invalid');
    expect(settings.supabaseKey, 'private-fixture-key');
    expect(settings.userId, ' exact-user ');
  });
}
