import 'package:flutter_test/flutter_test.dart';
import 'package:disc_golf_app/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const DiscGolfApp());
    expect(find.text('Welcome to Disc Flight School'), findsOneWidget);
  });
}
