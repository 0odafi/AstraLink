import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:astralink_app/main.dart';

void main() {
  testWidgets('AstraLink app boots', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const AstraMessengerApp());
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.textContaining('AstraLink'), findsWidgets);
  });
}
