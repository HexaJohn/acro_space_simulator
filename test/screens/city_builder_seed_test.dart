import 'package:acro_space_simulator/infrastructure/flutter/screens/city_builder_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The city builder now seeds a starter town in initState (_seedStarterTown +
/// _recompute). This is a smoke test: opening the screen must not throw while
/// founding that town (placing utils/zones/roads + wiring the economy).
void main() {
  testWidgets('city builder opens with a prebuilt town without crashing',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CityBuilderScreen()));
    await tester.pump(const Duration(milliseconds: 100)); // run an economy tick

    expect(find.byType(CityBuilderScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
