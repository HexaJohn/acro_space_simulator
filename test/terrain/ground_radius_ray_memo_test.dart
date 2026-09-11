// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_feature.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

/// A relief that counts how often it is read — the DEM-plus-detail read
/// that costs the most of any term in the composed field.
class _CountingDetail extends TerrainDetail {
  _CountingDetail()
      : super(TerrainDetail.none.features, TerrainDetail.none.control);

  int reads = 0;

  @override
  double heightAt(Vector3 dir) {
    reads++;
    return 25 * math.sin(dir.x * 4000) * math.cos(dir.y * 3000) +
        10 * math.sin(dir.z * 7000);
  }
}

/// An edit store that counts how often its index is asked for the
/// brushes over a direction.
class _CountingEdits extends TerrainEdits {
  int lookups = 0;

  @override
  List<TerrainBrush> at(Vector3 dir) {
    lookups++;
    return super.at(dir);
  }
}

/// The march `groundRadiusAt` has always made, verbatim, over the public
/// [TerrainField.density] — the reference its answers must equal to the
/// bit — with the number of density samples it took.
({double r, int samples}) _marched(TerrainField f, double dx, double dy,
    double dz) {
  var samples = 0;
  double density(double x, double y, double z) {
    samples++;
    return f.density(x, y, z);
  }

  final len = math.sqrt(dx * dx + dy * dy + dz * dz);
  final inv = 1.0 / len;
  final dir = Vector3(dx * inv, dy * inv, dz * inv);
  final base = f.radius + f.heightInDirection(dir.x, dir.y, dir.z);
  final candidates = f.edits!.at(dir);
  var lo = double.infinity, hi = double.negativeInfinity;
  var minFeature = double.infinity;
  for (final b in candidates) {
    final proj = b.centreBF.dot(dir);
    final perp2 = b.centreBF.lengthSquared - proj * proj;
    final rad2 = b.boundingRadiusM * b.boundingRadiusM;
    if (perp2 >= rad2) continue;
    final half = math.sqrt(rad2 - perp2);
    if (proj - half < lo) lo = proj - half;
    if (proj + half > hi) hi = proj + half;
    if (b.radiusM < minFeature) minFeature = b.radiusM;
    if (b.depthM > 0 && b.depthM < minFeature) minFeature = b.depthM;
    if (b.rimHeightM > 0 && b.rimHeightM < minFeature) {
      minFeature = b.rimHeightM;
    }
  }
  if (hi < lo) return (r: base, samples: samples);
  final span = math.max(hi, base) - math.min(lo, base);
  final margin = math.max(span * 0.01, 1e-3);
  final rStart = math.max(hi, base) + margin;
  final rEnd = math.min(lo, base) - margin;
  final step = math.max(minFeature / 6.0, (rStart - rEnd) / 512.0);
  var rOuter = rStart;
  if (density(dir.x * rStart, dir.y * rStart, dir.z * rStart) <= 0) {
    return (r: rStart, samples: samples);
  }
  var r = rStart;
  while (r > rEnd) {
    r = math.max(r - step, rEnd);
    if (density(dir.x * r, dir.y * r, dir.z * r) <= 0) {
      var lo = r, hi = rOuter;
      for (var i = 0; i < 32; i++) {
        final mid = (lo + hi) * 0.5;
        if (density(dir.x * mid, dir.y * mid, dir.z * mid) <= 0) {
          lo = mid;
        } else {
          hi = mid;
        }
        if (hi - lo < 1e-4) break;
      }
      return (r: (lo + hi) * 0.5, samples: samples);
    }
    rOuter = r;
  }
  return (r: base, samples: samples);
}

/// The ground under a colony's new road is found by marching the composed
/// field through every brush the town has laid there — hundreds of density
/// samples along one radial. Each sample read the relief (a DEM plus the
/// eroded detail stack) and asked the edit index for its brushes afresh,
/// though both depend on the sample's DIRECTION alone, and every sample of
/// a march lies on one ray: ~4 ms a query under a settled starter town,
/// and the city shaper asks dozens after every road edit, inside one tick
/// — the UI froze for up to a second and a quarter.
///
/// What is pinned: the answer is the march's, to the bit, and the relief
/// and the index are read once per distinct direction, not once per step.
void main() {
  const radius = 6.371e6;
  final d0 = const Vector3(0.31, -0.42, 0.853).normalized;
  final east = Vector3.unitZ.cross(d0).normalized;
  final north = d0.cross(east);
  Vector3 at(double eastM, double northM) =>
      (d0 + east * (eastM / radius) + north * (northM / radius)).normalized;

  TerrainField fieldWith(TerrainDetail detail, [TerrainEdits? edits]) =>
      TerrainField(
        radius: radius,
        amplitude: 40,
        featureScale: 2000,
        seed: 7,
        detail: detail,
        edits: edits,
      );

  // A corner of a town: a levelled lot, a graded street past it and an
  // old impact crater they were both cut through.
  final pristine = fieldWith(_CountingDetail());
  Vector3 onGround(Vector3 d) => d * pristine.groundRadiusAt(d.x, d.y, d.z);
  final padAt = onGround(at(0, 0));
  final roadA = onGround(at(-60, 18)), roadB = onGround(at(60, 22));
  final edits = _CountingEdits()
    ..add(TerrainBrush.crater(
      contactBF: onGround(at(15, -25)),
      normalBF: at(15, -25),
      radiusM: 30,
      depthM: 8,
      rimHeightM: 2,
    ))
    ..add(TerrainBrush.pad(
      centreBF: padAt,
      radiusM: 14,
      datumRadiusM: padAt.length + 3,
    ))
    ..add(TerrainBrush.cutFill(
      startBF: roadA,
      endBF: roadB,
      radiusM: 4,
      datumRadiusM: roadA.length,
      datumRadiusEndM: roadB.length,
      falloffM: 6,
    ));
  final detail = _CountingDetail();
  final field = fieldWith(detail, edits);

  test('answers what the march always answered, to the bit', () {
    var checked = 0, marched = 0;
    for (var i = -8; i <= 8; i++) {
      for (var j = -8; j <= 8; j++) {
        final d = at(i * 7.5, j * 7.5);
        final ref = _marched(field, d.x, d.y, d.z);
        expect(field.groundRadiusAt(d.x, d.y, d.z), ref.r,
            reason: 'at ($i, $j)');
        checked++;
        if (ref.samples >= 100) marched++;
      }
    }
    expect(checked, 289);
    expect(marched, greaterThan(50),
        reason: 'the brushes cover enough rays to exercise the march');
  });

  test('reads the relief and the index once per direction, not per step', () {
    var queries = 0;
    for (var i = -8; i <= 8; i++) {
      for (var j = -8; j <= 8; j++) {
        final d = at(i * 7.5, j * 7.5);
        final samples = _marched(field, d.x, d.y, d.z).samples;
        if (samples < 100) continue;
        queries++;
        detail.reads = 0;
        edits.lookups = 0;
        field.groundRadiusAt(d.x, d.y, d.z);
        // One read and one lookup up front (the base surface and the
        // candidate list), then one of each per distinct unit direction the
        // march normalises back to — a few dozen at most, however long it
        // marches.
        expect(detail.reads, lessThanOrEqualTo(64),
            reason: '$samples samples, ${detail.reads} relief reads');
        expect(detail.reads, lessThan(samples ~/ 3));
        expect(edits.lookups, lessThanOrEqualTo(64),
            reason: '$samples samples, ${edits.lookups} index lookups');
        expect(edits.lookups, lessThan(samples ~/ 3));
      }
    }
    expect(queries, greaterThan(50));
  });
}
