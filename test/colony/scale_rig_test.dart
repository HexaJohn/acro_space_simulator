// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/scale_rig.dart';
import 'package:flutter_test/flutter_test.dart';

/// A metre rule for the city.
///
/// The whole value of this thing is that its dimensions are TRUE — if the mast
/// is not really 100 m, or the bands are not really a metre, it turns a
/// question about scale into a second, more confusing one.
void main() {
  final up = Vector3(1, 0, 0);
  final north = Vector3(0, 1, 0);

  ({double minUp, double maxUp, int verts}) built() {
    final solid = MeshBuilder();
    final glow = MeshBuilder();
    ScaleRig.emit(solid, glow, Vector3.zero, north, up);
    var lo = double.infinity, hi = -double.infinity, n = 0;
    for (final part in [solid.build(), glow.build()]) {
      final p = part.positions;
      n += p.length ~/ 3;
      for (var i = 0; i + 2 < p.length; i += 3) {
        final h = p[i] / 0.001; // scene units back to metres, along `up`
        if (h < lo) lo = h;
        if (h > hi) hi = h;
      }
    }
    return (minUp: lo, maxUp: hi, verts: n);
  }

  test('the mast really is 100 m tall', () {
    final r = built();
    expect(r.maxUp, closeTo(ScaleRig.mastHeightM, 0.5),
        reason: 'a rule that lies is worse than no rule');
    expect(r.verts, greaterThan(200));
  });

  test('nothing sinks below the ground it stands on', () {
    expect(built().minUp, greaterThan(-0.01));
  });

  test('it winds the way the buildings do', () {
    // Same convention check the vehicles get: buildings render correctly, so
    // whatever they do is what a front face is.
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
      return total == 0 ? 0 : against / total;
    }

    final lot = Parcel(
      id: 'l',
      polygon: [Vec2(-12, 0), Vec2(12, 0), Vec2(12, 30), Vec2(-12, 30)],
      frontage: (Vec2(-12, 0), Vec2(12, 0)),
    );
    final b = const BuildingGenerator()
        .generate(kZoneSpecs['residential']![Density.medium]!, lot, seed: 1)
        .model
        .solid;
    final reference = opposing(b.positions, b.normals, b.indices);

    final solid = MeshBuilder();
    final glow = MeshBuilder();
    ScaleRig.emit(solid, glow, Vector3.zero, north, up);
    final m = solid.build();
    expect(opposing(m.positions, m.normals, m.indices),
        closeTo(reference, 0.05),
        reason: 'the rig renders inside out');
  });
}
