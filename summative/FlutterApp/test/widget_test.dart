import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crop_price_app/main.dart';

void main() {
  testWidgets('page has 8 fields and a Predict button', (tester) async {
    await tester.pumpWidget(const CropPriceApp());
    expect(find.text('Commodity'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Predict'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Month'), findsOneWidget);
    expect(find.text('Predict'), findsOneWidget);
  });

  testWidgets('month field opens a drop-down list', (tester) async {
    await tester.pumpWidget(const CropPriceApp());
    await tester.scrollUntilVisible(find.text('Month'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(TextField, 'Month'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
  });
}
