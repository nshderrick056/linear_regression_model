import 'package:flutter_test/flutter_test.dart';
import 'package:crop_price_app/main.dart';

void main() {
  testWidgets('page has 8 fields and a Predict button', (tester) async {
    await tester.pumpWidget(const CropPriceApp());
    expect(find.text('Predict'), findsOneWidget);
    expect(find.text('Commodity'), findsOneWidget);
    expect(find.text('Month'), findsOneWidget);
  });
}
