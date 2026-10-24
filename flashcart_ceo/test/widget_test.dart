import 'package:flutter_test/flutter_test.dart';
import 'package:flashcart_ceo/main.dart';

void main() {
  group('FlashCart Founder & CEO App', () {
    test('CEO app widget can be constructed', () {
      const app = FlashCartCeoApp();
      expect(app, isA<FlashCartCeoApp>());
    });
  });
}
