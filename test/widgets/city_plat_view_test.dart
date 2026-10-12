// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/infrastructure/flutter/screens/city_plat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// The plat in the live view: a click names the colony-local point under it,
/// and the host's overlay is drawn in the plat's frame.
void main() {
  testWidgets('a click is reported in colony metres; the overlay is laid over', (tester) async {
    final city = starterKit();
    final cam = CityPlatCamera(centreE: 100, centreN: -50, metresPerPx: 2);
    (double, double)? got;
    Size? overlaid;
    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: 400,
        height: 300,
        child: CityPlatView(
          sim: city,
          camera: cam,
          onTapLocal: (e, n) => got = (e, n),
          overlay: (c, size) {
            overlaid = size;
            return const SizedBox.shrink(key: Key('plat-overlay'));
          },
        ),
      ),
    ));
    expect(find.byKey(const Key('plat-overlay')), findsOneWidget);
    expect(overlaid, isNotNull);
    final box = tester.getRect(find.byType(CityPlatView));
    // 50 px right of and 25 px above the middle: +100 m east, +50 m north.
    await tester.tapAt(box.center + const Offset(50, -25));
    await tester.pump();
    expect(got, isNotNull);
    expect(got!.$1, closeTo(100 + 50 * 2, 1e-9));
    expect(got!.$2, closeTo(-50 + 25 * 2, 1e-9));
  });
}
