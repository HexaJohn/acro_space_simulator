import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/surface_placement.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/terrain_heights.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const place = SurfacePlacement();

  void expectVec(Vector3 a, Vector3 b, [double tol = 1e-9]) {
    expect(a.x, closeTo(b.x, tol));
    expect(a.y, closeTo(b.y, tol));
    expect(a.z, closeTo(b.z, tol));
  }

  group('SurfacePlacement', () {
    test('places a point on the sphere at lat/lon with a radial-up frame', () {
      final r = place.place(radius: 1000, lat: 0, lon: 0);
      // lat=lon=0 -> outward is +X.
      expectVec(r.position, Vector3(1000, 0, 0));
      // local +Z (up) -> radial +X; +Y (north) -> +Z; +X (east) -> +Y.
      expectVec(r.orientation.rotate(Vector3.unitZ), Vector3(1, 0, 0), 1e-9);
      expectVec(r.orientation.rotate(Vector3.unitY), Vector3(0, 0, 1), 1e-9);
      expectVec(r.orientation.rotate(Vector3.unitX), Vector3(0, 1, 0), 1e-9);
    });

    test('north pole sits on +Z and up points along +Z', () {
      final r = place.place(radius: 500, lat: math.pi / 2, lon: 0);
      expectVec(r.position, Vector3(0, 0, 500), 1e-9);
      expectVec(r.orientation.rotate(Vector3.unitZ), Vector3(0, 0, 1), 1e-9);
    });

    test('elevation lifts the point radially', () {
      final base = place.place(radius: 1000, lat: 0.3, lon: 1.1);
      final lifted =
          place.place(radius: 1000, lat: 0.3, lon: 1.1, elevation: 50);
      expect(lifted.position.length, closeTo(base.position.length + 50, 1e-6));
      // Same direction, just farther out.
      expectVec(lifted.position.normalized, base.position.normalized, 1e-9);
    });

    test('building offsets east/north by grid cell and stays orthonormal', () {
      final r = place.building(
        radius: 6.371e6,
        lat: 0,
        lon: 0,
        gridX: 0,
        gridY: 0,
      );
      // (0,0) cell centre is 0.5 cell east + 0.5 cell north of the anchor.
      // east at lat0/lon0 is +Y, north is +Z; radius dominates +X.
      expect(r.position.x, closeTo(6.371e6, 1.0));
      expect(r.position.y, closeTo(0.5 * kCityCellMetres, 1e-6)); // east
      expect(r.position.z, closeTo(0.5 * kCityCellMetres, 1e-6)); // north
      // Orientation is a unit quaternion.
      final q = r.orientation;
      expect(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z, closeTo(1, 1e-9));
    });
  });

  group('TerrainHeights', () {
    test('defaults to a smooth sphere (0) and stores reported heights', () {
      final t = TerrainHeights();
      const body = BodyId('earth');
      expect(t.isEmpty, isTrue);
      expect(t.heightAt(body, 0.5, 1.0), 0);
      t.report(body, 0.5, 1.0, 123.0);
      expect(t.heightAt(body, 0.5, 1.0), 123.0);
      // A nearby lookup within a cell resolves to the same bucket.
      expect(t.heightAt(body, 0.500001, 1.000001), 123.0);
      // A different body is independent.
      expect(t.heightAt(const BodyId('moon'), 0.5, 1.0), 0);
    });
  });
}
