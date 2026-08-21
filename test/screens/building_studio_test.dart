// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/building_studio_screen.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/building_preview_nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The building studio: its controls, and the block-face request its preview
/// layer is driven by.
///
/// NOT TESTED HERE: the geometry the preview uploads. Building a scene needs
/// flutter_gpu, which is not available under `flutter test` — what the meshes
/// contain is covered where it is generated, in
/// `test/architecture/architecture_style_test.dart`.
void main() {
  BuildingPreviewRequest request({
    ArchitectureStyle style = ArchitectureStyle.masonryStreet,
    double lotWidthM = 22,
    int lots = 4,
    int seed = 1,
  }) =>
      BuildingPreviewRequest(
        style: style,
        spec: kZoneSpecs['commercial']![Density.medium]!,
        lotWidthM: lotWidthM,
        lotDepthM: 34,
        lots: lots,
        seed: seed,
        detail: BuildingDetail.full,
      );

  group('the preview request', () {
    test('a changed knob is a different request, so the block rebuilds', () {
      // The preview only rebuilds when the request changes, so anything the
      // geometry depends on that is left out of == is a control that silently
      // does nothing — the exact failure that makes a studio useless.
      final base = request();
      expect(base, request(), reason: 'the same inputs are the same block');
      expect(base, isNot(request(style: ArchitectureStyle.utilitarian)));
      expect(base, isNot(request(lotWidthM: 23)));
      expect(base, isNot(request(lots: 5)));
      expect(base, isNot(request(seed: 2)));
    });

    test('equal requests hash equal, or the set-based caches miss', () {
      expect(request().hashCode, request().hashCode);
    });

    test('the block is as wide as its lots put together', () {
      expect(request(lotWidthM: 20, lots: 5).blockWidthM, 100);
    });
  });

  test('copying a building onto its lot preserves the winding', () {
    // The preview flattens every building into one shared mesh. That copy has
    // to hand the indices through UNCHANGED, and MeshBuilder.triangle reverses
    // what it is given — so a straight pass-through flips every face and the
    // whole block renders inside out, which looks exactly like the buildings
    // never having been generated.
    final parcel = Parcel(
      id: 'lot',
      polygon: const [Vec2(-11, 0), Vec2(11, 0), Vec2(11, 34), Vec2(-11, 34)],
      frontage: (const Vec2(-11, 0), const Vec2(11, 0)),
    );
    final built = const BuildingGenerator()
        .withStyle(ArchitectureStyle.masonryStreet)
        .generate(kZoneSpecs['commercial']![Density.medium]!, parcel);
    final src = built.model.solid;

    final into = MeshBuilder();
    BuildingPreviewNodes.appendMesh(into, src, 40, 17);
    final out = into.build();

    expect(out.triangleCount, src.triangleCount);

    double opposing(List<double> p, List<double> n, List<int> idx) {
      var against = 0, total = 0;
      for (var t = 0; t + 2 < idx.length; t += 3) {
        final a = idx[t] * 3, b = idx[t + 1] * 3, c = idx[t + 2] * 3;
        final e1 = [p[b] - p[a], p[b + 1] - p[a + 1], p[b + 2] - p[a + 2]];
        final e2 = [p[c] - p[a], p[c + 1] - p[a + 1], p[c + 2] - p[a + 2]];
        final wx = e1[1] * e2[2] - e1[2] * e2[1];
        final wy = e1[2] * e2[0] - e1[0] * e2[2];
        final wz = e1[0] * e2[1] - e1[1] * e2[0];
        final d = wx * n[a] + wy * n[a + 1] + wz * n[a + 2];
        if (d == 0) continue;
        total++;
        if (d < 0) against++;
      }
      return total == 0 ? -1 : against / total;
    }

    final before = opposing(src.positions, src.normals, src.indices);
    expect(before, isNot(-1));
    expect(opposing(out.positions, out.normals, out.indices), closeTo(before, 1e-9),
        reason: 'the copy turned the building inside out');

    // And it landed where it was put.
    var minX = double.infinity;
    for (var i = 0; i + 2 < out.positions.length; i += 3) {
      minX = out.positions[i] < minX ? out.positions[i] : minX;
    }
    expect(minX, greaterThan(20), reason: 'the lot offset was not applied');
  });

  testWidgets('it opens with controls, before any GPU work', (t) async {
    await t.pumpWidget(const MaterialApp(home: BuildingStudioScreen()));
    await t.pump();
    expect(find.text('KIT'), findsOneWidget);
    expect(find.text('ZONE'), findsOneWidget);
    expect(find.text('LOT'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('the control panel lays out without assertions', (t) async {
    await t.pumpWidget(const MaterialApp(home: BuildingStudioScreen()));
    await t.pump();

    final list = find.byType(ListView);
    expect(list, findsWidgets);

    // Drag to the end, building every tile on the way, and note which
    // switches were seen — a ListView unbuilds what has scrolled off, so
    // counting at the bottom would miss everything above it.
    final seen = <String>{};
    for (var i = 0; i < 22; i++) {
      await t.drag(list.last, const Offset(0, -240));
      await t.pump();
      expect(t.takeException(), isNull,
          reason: 'a widget in the control panel asserted while laying out — '
              'a ListTile inside a coloured box is the usual cause');
      for (final e
          in t.widgetList<SwitchListTile>(find.byType(SwitchListTile))) {
        final title = e.title;
        if (title is Text && title.data != null) seen.add(title.data!);
      }
    }
    expect(
        seen,
        containsAll(<String>[
          'Vary along the row',
          'Corner lots at the ends',
          'Property lines',
          'Scale reference',
        ]));
  });

  testWidgets('every kit is offered, and switching one takes', (t) async {
    await t.pumpWidget(const MaterialApp(home: BuildingStudioScreen()));
    await t.pump();

    // The kit's own note is on screen, which is how the panel says what the
    // current style is FOR.
    expect(find.textContaining('property line'), findsWidgets);

    // pump(), never pumpAndSettle(): the viewport holds a progress spinner
    // until the scene resources land, and they never do under `flutter test`.
    // pumpAndSettle would wait for that animation forever.
    await t.tap(find.byType(DropdownButton<String>).first);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    for (final s in ArchitectureStyle.kits) {
      expect(find.text(s.label), findsWidgets, reason: '${s.id} is not offered');
    }
    await t.tap(find.text(ArchitectureStyle.utilitarian.label).last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Office park'), findsWidgets,
        reason: 'the note did not follow the selection');
    expect(t.takeException(), isNull);
  });
}
