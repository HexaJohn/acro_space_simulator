// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

/// Terrain brushes have to survive the snapshot intact.
///
/// The physics reads brushes straight from the edit store; the RENDERER
/// rebuilds them from the snapshot. The snapshot predates the levelling
/// brushes and was never widened for them, so a pad arrived at the mesher with
/// a target radius of zero and a graded corridor with no far end at all —
/// which `cutFill` answers by doing nothing. The drawn ground therefore kept
/// its raw relief while every building standing on it was placed at the
/// levelled height: structures floating or buried, roads cut into the hill on
/// one side and hanging off it on the other.
void main() {
  const body = BodyId('moon');

  void expectRoundTrip(TerrainBrush b, {required String what}) {
    for (final back in [
      TerrainEditSnapshot.of(body, b).toBrush(),
      // And through JSON, which the wire and the save both go via.
      TerrainEditSnapshot.fromJson(TerrainEditSnapshot.of(body, b).toJson())
          .toBrush(),
    ]) {
      expect(back.kind, b.kind, reason: what);
      expect(back.radiusM, b.radiusM, reason: what);
      expect(back.datumRadiusM, b.datumRadiusM,
          reason: '$what: the target surface is the whole point of the brush');
      expect(back.datumRadiusEndM, b.datumRadiusEndM, reason: what);
      expect(back.falloffM, b.falloffM, reason: what);
      expect(back.benches, b.benches, reason: what);
      expect(back.depthM, b.depthM, reason: what);
      expect(back.minVoxelM, b.minVoxelM,
          reason: '$what: the voxel floor is how a city stays coarse');
      expect(back.endBF?.x, b.endBF?.x, reason: what);
      expect(back.endBF?.y, b.endBF?.y, reason: what);
      expect(back.endBF?.z, b.endBF?.z, reason: what);
      expect(back.polygonBF.length, b.polygonBF.length,
          reason: '$what: a pad without its outline levels nothing');
      for (var i = 0; i < b.polygonBF.length; i++) {
        expect(back.polygonBF[i].x, b.polygonBF[i].x, reason: what);
        expect(back.polygonBF[i].y, b.polygonBF[i].y, reason: what);
        expect(back.polygonBF[i].z, b.polygonBF[i].z, reason: what);
      }
    }
  }

  test('a coarse city pad keeps its voxel floor, and old saves default it', () {
    expectRoundTrip(
      TerrainBrush.pad(
        centreBF: Vector3(1736500, 120, -90),
        radiusM: 26,
        datumRadiusM: 1736504.967,
        minVoxelM: 15,
      ),
      what: 'coarse pad',
    );
    // A save written before the field existed carries no 'mv' key.
    final old = TerrainEditSnapshot.fromJson({
      'body': 'moon',
      'kind': TerrainBrushKind.pad.index,
      'c': [1736500, 120, -90],
      'a': [1, 0, 0],
      'r': 26,
    });
    expect(old.toBrush().minVoxelM, 0);
  });

  test('a building pad survives with its target surface', () {
    expectRoundTrip(
      TerrainBrush.pad(
        centreBF: Vector3(1736500, 120, -90),
        radiusM: 26,
        datumRadiusM: 1736504.967,
        falloffM: 14,
        maxCutM: 40,
      ),
      what: 'pad',
    );
  });

  test('a graded road corridor survives with BOTH ends', () {
    final b = TerrainBrush.cutFill(
      startBF: Vector3(1736500, 0, 0),
      endBF: Vector3(1736498, 24, 3),
      radiusM: 4,
      datumRadiusM: 1736500.5,
      datumRadiusEndM: 1736498.25,
      falloffM: 6,
    );
    expectRoundTrip(b, what: 'cutFill');
    // Without an end point a corridor levels nothing at all, so this is the
    // field whose loss made roads clip and float.
    expect(TerrainEditSnapshot.of(body, b).toBrush().endBF, isNotNull);
  });

  test('a stepped quarry keeps its benches', () {
    expectRoundTrip(
      TerrainBrush.steppedPit(
        centreBF: Vector3(1736400, 40, 10),
        radiusM: 120,
        datumRadiusM: 1736402.5,
        depthM: 60,
        benches: 7,
        falloffM: 42,
      ),
      what: 'steppedPit',
    );
  });

  test('a crater still round-trips (the kinds that always worked)', () {
    expectRoundTrip(
      TerrainBrush.crater(
        contactBF: Vector3(1736300, 5, 5),
        normalBF: Vector3(1, 0, 0),
        radiusM: 30,
        depthM: 8,
        rimHeightM: 2,
      ),
      what: 'crater',
    );
  });

  test('a polygon pad survives with its outline', () {
    // The shape IS the brush here: a lot is a polygon, and a pad that reaches
    // the mesher without its outline has nothing to level.
    expectRoundTrip(
      TerrainBrush.padPoly(
        centreBF: Vector3(1736500, 0, 0),
        polygonBF: [
          Vector3(1736500, -12, -16),
          Vector3(1736500, 12, -14),
          Vector3(1736500, 10, 18),
          Vector3(1736500, -13, 15),
        ],
        datumRadiusM: 1736500.75,
        falloffM: 0.6,
        maxCutM: 30,
      ),
      what: 'padPoly',
    );
  });
}
