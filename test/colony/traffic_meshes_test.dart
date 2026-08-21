// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/vehicle_meshes.dart';
import 'package:flutter_test/flutter_test.dart';

/// Placeholder road traffic.
///
/// Cosmetic by construction: derived from the frame's roads and epoch, with no
/// state in the sim and nothing on the wire. What these pin is the part that
/// would be silently wrong — that every kind builds real geometry, that the
/// two families are kept apart, and that a vehicle stands ON the road rather
/// than through it.
void main() {
  ({int verts, double minUp, double maxUp}) build(VehicleKind kind) {
    final body = MeshBuilder();
    final glass = MeshBuilder();
    // A patch of ground 1000 m "up" the +X axis, driving along +Y.
    final up = Vector3(1, 0, 0);
    final along = Vector3(0, 1, 0);
    final at = up * 1000.0;
    VehicleMeshes.emit(body, glass, kind, at, along, up, u: 0.5);
    final mesh = body.build();
    final g = glass.build();
    var lo = double.infinity, hi = -double.infinity;
    // BOTH builders: the cabin glazing is where a car's roof actually is, so
    // measuring the body alone would say a coupe is waist high.
    for (final part in [mesh, g]) {
      for (var i = 0; i + 2 < part.positions.length; i += 3) {
        // Height above the ground plane, in metres (mesh is in scene units).
        final h = part.positions[i] / 0.001 - 1000.0;
        if (h < lo) lo = h;
        if (h > hi) hi = h;
      }
    }
    return (
      verts: mesh.positions.length ~/ 3 + g.positions.length ~/ 3,
      minUp: lo,
      maxUp: hi,
    );
  }

  test('every kind builds real geometry', () {
    for (final k in VehicleKind.values) {
      final r = build(k);
      expect(r.verts, greaterThan(24), reason: '${k.name} is empty');
    }
  });

  test('nothing is buried in the road or hovering over it', () {
    for (final k in VehicleKind.values) {
      final r = build(k);
      expect(r.minUp, greaterThan(-0.01),
          reason: '${k.name} sinks into the carriageway');
      expect(r.minUp, lessThan(0.05),
          reason: '${k.name} floats above it');
    }
  });

  test('each kind stands as tall as it claims', () {
    for (final k in VehicleKind.values) {
      final r = build(k);
      expect(r.maxUp, closeTo(k.heightM, k.heightM * 0.25),
          reason: '${k.name} silhouette does not match its spec');
    }
  });

  test('the airless family is rovers, the breathable one is cars', () {
    expect(VehicleKind.airless, [VehicleKind.rover]);
    expect(VehicleKind.road, isNot(contains(VehicleKind.rover)));
    expect(VehicleKind.road,
        containsAll([VehicleKind.coupe, VehicleKind.sedan,
            VehicleKind.truck, VehicleKind.semi]));
    // Six wheels on the rover, four on a car.
    expect(VehicleKind.rover.axles, 3);
    expect(VehicleKind.coupe.axles, 2);
  });

  test('a semi is articulated-long and a coupe is not', () {
    expect(VehicleKind.semi.lengthM, greaterThan(12));
    expect(VehicleKind.coupe.lengthM, lessThan(5));
    expect(VehicleKind.semi.heightM, greaterThan(VehicleKind.sedan.heightM));
  });

  test('every face is wound the way this engine draws front faces', () {
    // The convention is measured, not reasoned about. BUILDING geometry
    // renders the right way round, and every one of its triangles winds
    // AGAINST its own declared normal — so that is what a front face is here.
    //
    // Deriving it instead from `MeshBuilder.triangle` reversing its arguments
    // gives the opposite answer and is wrong: the world-to-scene mapping is
    // itself a mirror (see coord_convert's chirality note) and the finished
    // image is flipped back. I got this backwards twice before measuring it.
    for (final kind in VehicleKind.values) {
      final body = MeshBuilder();
      final glass = MeshBuilder();
      VehicleMeshes.emit(body, glass, kind, Vector3(1, 0, 0) * 1000.0,
          Vector3(0, 1, 0), Vector3(1, 0, 0),
          u: 0.5);

      for (final part in [body.build(), glass.build()]) {
        final p = part.positions;
        final nrm = part.normals;
        final idx = part.indices;
        var disagree = 0;
        for (var t = 0; t + 2 < idx.length; t += 3) {
          final a = idx[t] * 3, b = idx[t + 1] * 3, c = idx[t + 2] * 3;
          final e1 = [p[b] - p[a], p[b + 1] - p[a + 1], p[b + 2] - p[a + 2]];
          final e2 = [p[c] - p[a], p[c + 1] - p[a + 1], p[c + 2] - p[a + 2]];
          final wx = e1[1] * e2[2] - e1[2] * e2[1];
          final wy = e1[2] * e2[0] - e1[0] * e2[2];
          final wz = e1[0] * e2[1] - e1[1] * e2[0];
          final dot = wx * nrm[a] + wy * nrm[a + 1] + wz * nrm[a + 2];
          if (dot > 0) disagree++;
        }
        expect(disagree, 0,
            reason: '${kind.name}: $disagree triangles wound the wrong way '
                'for this engine — that part renders inside out');
      }
    }
  });

  test('trucks and semis carry their cab at the FRONT', () {
    // +along is the direction of travel. Built the other way round, every
    // truck in the colony drove down the street trailer-first.
    for (final kind in [VehicleKind.truck, VehicleKind.semi]) {
      final body = MeshBuilder();
      final glass = MeshBuilder();
      final up = Vector3(1, 0, 0);
      final along = Vector3(0, 1, 0);
      VehicleMeshes.emit(body, glass, kind, up * 1000.0, along, up, u: 0.5);
      // The CABIN is the glazing. Its centre must sit forward of the origin.
      final g = glass.build();
      var sum = 0.0;
      final n = g.positions.length ~/ 3;
      for (var i = 0; i < n; i++) {
        sum += g.positions[i * 3 + 1]; // the +along axis
      }
      expect(sum / n, greaterThan(0),
          reason: '${kind.name} cab is behind the middle — it faces backwards');
    }
  });

  test('the model form is centred at the origin, +Y forward, +Z up', () {
    // The instancing contract. Geometry is uploaded ONCE per kind and every
    // car afterwards costs a matrix — but only if the model sits where the
    // instance transform expects it: on the ground, at the origin, facing +Y.
    for (final kind in VehicleKind.values) {
      final body = MeshBuilder();
      final glass = MeshBuilder();
      VehicleMeshes.emitModel(body, glass, kind);

      var minZ = double.infinity, maxZ = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      var minX = double.infinity, maxX = -double.infinity;
      for (final part in [body.build(), glass.build()]) {
        final p = part.positions;
        for (var i = 0; i + 2 < p.length; i += 3) {
          final x = p[i] / 0.001, y = p[i + 1] / 0.001, z = p[i + 2] / 0.001;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
          if (z < minZ) minZ = z;
          if (z > maxZ) maxZ = z;
        }
      }
      // Wheels touch the ground plane, nothing below it.
      expect(minZ, closeTo(0, 0.05), reason: '${kind.name} floats or sinks');
      expect(maxZ, closeTo(kind.heightM, kind.heightM * 0.25));
      // Length runs along +/-Y, width across X, both centred.
      expect(maxY - minY, closeTo(kind.lengthM, kind.lengthM * 0.3));
      expect((minY + maxY) / 2, closeTo(0, kind.lengthM * 0.2),
          reason: '${kind.name} is not centred on its origin');
      expect(maxX - minX, closeTo(kind.widthM, kind.widthM * 0.35));
    }
  });

  test('vehicles wind the same way the buildings do', () {
    // The anchor for the convention. Buildings render the right way round, so
    // whatever they do IS correct — asserting vehicles match them cannot
    // encode my own guess about the winding, which was wrong twice.
    double disagreeFraction(List<double> p, List<double> n, List<int> idx) {
      var opposing = 0, total = 0;
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
        if (d < 0) opposing++;
      }
      return total == 0 ? 0 : opposing / total;
    }

    final lot = Parcel(
      id: 'l',
      polygon: [Vec2(-12, 0), Vec2(12, 0), Vec2(12, 30), Vec2(-12, 30)],
      frontage: (Vec2(-12, 0), Vec2(12, 0)),
    );
    final building = const BuildingGenerator()
        .generate(kZoneSpecs['residential']![Density.medium]!, lot, seed: 1);
    final bm = building.model.solid;
    final reference = disagreeFraction(bm.positions, bm.normals, bm.indices);
    expect(reference, closeTo(1.0, 0.05),
        reason: 'the reference geometry changed convention');

    for (final kind in VehicleKind.values) {
      final body = MeshBuilder();
      final glass = MeshBuilder();
      VehicleMeshes.emitModel(body, glass, kind);
      for (final part in [body.build(), glass.build()]) {
        expect(disagreeFraction(part.positions, part.normals, part.indices),
            closeTo(reference, 0.05),
            reason: '${kind.name} does not wind like a building');
      }
    }
  });
}
