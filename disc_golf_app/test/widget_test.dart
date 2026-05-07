import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:disc_golf_app/main.dart';

void main() {
  testWidgets('App shows home after onboarding is complete',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'onboarding_complete': true});

    await tester.pumpWidget(const DiscGolfApp());
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Disc Flight School'), findsOneWidget);
  });

  testWidgets('App shows onboarding on first launch',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const DiscGolfApp());
    await tester.pumpAndSettle();

    expect(find.text('Welcome to\nDisc Flight School'), findsOneWidget);
  });
}
