// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Crater-on-a-hillside regression: the rim used to be a solid torus seated on
// the contact plane, and on real DEM relief any hillside (or ground merely
// rough at crater scale) fell away from that plane by more than the rim
// height — the ring hung in the air on the low side. The rim is now a
// CONFORMAL ground lift (see TerrainBrush.apply): it raises whatever surface
// is locally there, so it cannot detach regardless of how the brush is
// seated. The tick additionally seats the brush on the field's true surface
// normal (TerrainField.surfaceNormalAt at the crater's own radius) so the
// BOWL opens out of the hillside rather than out of the sky.
//
// This test hunts a genuinely steep lunar site and pins conformity there for
// both seatings — the slope normal the tick uses, and the worst-case radial
// seating that used to float.

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

// A mid-sized impact: big enough that a hillside's drop across it dwarfs the
// rim height (the bug's regime), small against the DEM's feature scale.
const _radiusM = 15.0, _depthM = 6.0, _rimM = 1.2;

/// The worst crest-above-pre-impact-ground excess around the rim (m), and the
/// best rim lift anywhere on it (to prove a crest still exists).
(double worst, double bestLift) _rimProfile(
  TerrainField pristine,
  TerrainField Function(TerrainEdits) composedOf,
  Vector3 contactBF,
  Vector3 axis,
) {
  final brush = TerrainBrush.crater(
    contactBF: contactBF,
    normalBF: axis,
    radiusM: _radiusM,
    depthM: _depthM,
    rimHeightM: _rimM,
  );
  final composed = composedOf(TerrainEdits()..add(brush));

  final n = axis.normalized;
  final ref = n.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
  final u = ref.cross(n).normalized;
  final v = n.cross(u);
  var worst = double.negativeInfinity;
  var bestLift = double.negativeInfinity;
  for (var i = 0; i < 24; i++) {
    final phi = 2 * math.pi * i / 24;
    final crest =
        contactBF + (u * math.cos(phi) + v * math.sin(phi)) * _radiusM;
    final d = crest.normalized;
    final after = composed.groundRadiusAt(d.x, d.y, d.z);
    final before = pristine.baseGroundRadiusAt(d.x, d.y, d.z);
    final excess = after - before;
    if (excess > worst) worst = excess;
    if (excess > bestLift) bestLift = excess;
  }
  return (worst, bestLift);
}

void main() {
  test('a crater rim on a lunar hillside hugs the slope instead of floating',
      () {
    final moon = SampleWorld.realSystem().require(const BodyId('moon'));
    final field = moon.terrainField!;
    TerrainField composedOf(TerrainEdits e) => moon.terrainFieldWith(e)!;

    // Hunt a genuinely steep site: the old torus rim only floated where the
    // ground falls away from the contact plane by more than the rim height.
    Vector3? steepDir;
    for (var latDeg = -55.0; latDeg <= 55.0 && steepDir == null; latDeg += 3) {
      for (var lonDeg = -180.0; lonDeg < 180.0; lonDeg += 3) {
        final lat = latDeg * math.pi / 180, lon = lonDeg * math.pi / 180;
        final dir = Vector3(math.cos(lat) * math.cos(lon),
            math.cos(lat) * math.sin(lon), math.sin(lat));
        final n = field.surfaceNormalAt(dir, stepM: _radiusM);
        if (math.acos(n.dot(dir).clamp(-1.0, 1.0)) > 0.25) {
          steepDir = dir;
          break;
        }
      }
    }
    expect(steepDir, isNotNull,
        reason: 'no >14deg slope found on the Moon at crater scale — the '
            'hunt grid or the DEM regressed');
    final dir = steepDir!;
    final ground = field.baseGroundRadiusAt(dir.x, dir.y, dir.z);
    final contact = dir * ground;

    // The conformal rim must hug the pre-impact ground for ANY seating —
    // radial (the old floating case) and the slope normal the tick records.
    final seatings = {
      'radial': dir,
      'slope': field.surfaceNormalAt(dir, stepM: _radiusM),
    };
    seatings.forEach((name, axis) {
      final (worst, bestLift) = _rimProfile(field, composedOf, contact, axis);
      expect(worst, lessThan(_rimM * 2),
          reason: '$name seating: rim floats ${worst.toStringAsFixed(1)} m '
              'above the pre-impact ground');
      expect(bestLift, greaterThan(_rimM * 0.3),
          reason: '$name seating: no crest raised anywhere on the rim');
    });
  });
}
