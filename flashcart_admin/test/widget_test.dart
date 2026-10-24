import 'package:flutter_test/flutter_test.dart';
import 'package:flashcart_admin/main.dart';

void main() {
  testWidgets('FlashCart Admin app loads', (WidgetTester tester) async {
    await tester.pumpWidget(const FlashCartAdminApp());

    expect(find.text('FlashCart'), findsOneWidget);
  });
}
