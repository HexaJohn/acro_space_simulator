// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/parts/lem_parts.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

/// The art-placement values on the LM parts, as GEOMETRY rather than as
/// literals: which authored axis each correction sends where, and what the mesh
/// is allowed to be moved by.
///
/// These were settled by putting each export on screen against the body-frame
/// metre ruler and photographing it — see `docs/plans/lem_part_calibration.md`
/// for the images and the measurements each number came from. A quaternion
/// literal cannot say which way a mesh ends up facing, so the assertions below
/// rotate basis vectors and check where they land: a future edit that changes
/// the literal without changing the pose passes, and one that changes the pose
/// fails, which is the only distinction that matters to a renderer.
void main() {
  final catalog = PartCatalog.standard();

  PartDef def(String id) {
    final d = catalog.byId(id);
    expect(d, isNotNull, reason: '$id is not in the standard catalog');
    return d!;
  }

  /// Where [q] sends [axis], as a unit vector.
  Vector3 sends(Quaternion q, Vector3 axis) => q.rotate(axis).normalized;

  void expectAxis(Vector3 got, Vector3 want, {required String reason}) {
    expect(got.x, closeTo(want.x, 1e-9), reason: reason);
    expect(got.y, closeTo(want.y, 1e-9), reason: reason);
    expect(got.z, closeTo(want.z, 1e-9), reason: reason);
  }

  group('the exports that are authored a turn out of the part frame', () {
    test('the landing leg is an axis CYCLE, not a quarter turn', () {
      // Uncorrected the leg reaches UP and along -Y: the footpad photographs
      // roughly 2 m above the part origin instead of below it. The correction
      // is the 120-degree rotation about (1,1,1) that permutes all three axes
      // at once, which no single quarter turn can do.
      final q = def('eagle-legs').modelRotation;
      expectAxis(sends(q, Vector3.unitX), Vector3.unitY,
          reason: 'the strut span (2.37 m across) belongs on body Y');
      expectAxis(sends(q, Vector3.unitY), Vector3.unitZ,
          reason: 'the outrigger-to-footpad reach (3.22 m) belongs on body Z');
      expectAxis(sends(q, Vector3.unitZ), Vector3.unitX,
          reason: 'the radial reach (2.54 m) belongs on body X, out from hull');
    });

    test('the RCS quad is a quarter turn about X', () {
      // The up/down thruster pair photographs 1.01 m apart along the part's
      // own Y — the catalog declares that pair as size.z and the local frame
      // as "+Z along the up/down thruster pair", so Y has to become Z.
      final q = def('eagle-rcs-block').modelRotation;
      expectAxis(sends(q, Vector3.unitY), Vector3.unitZ,
          reason: 'the 1.00 m thruster pair belongs on body Z');
      expectAxis(sends(q, Vector3.unitX), Vector3.unitX,
          reason: 'the hull standoff axis must not move');
    });

    test('the other five are authored in the part frame already', () {
      // Each was photographed against the ruler and needed nothing: the pod's
      // tunnel, the descent stage's deck, the DPS bell mouth, the R-4D's exit
      // and the deflector's truss all land where the part frame wants them
      // under the renderer's standard glTF Y-up fix alone.
      for (final id in const [
        'eagle-command-pod',
        'eagle-fuel-tank',
        'eagle-thruster',
        'eagle-rcs-solo',
        'eagle-rcs-blast-flute',
      ]) {
        final q = def(id).modelRotation;
        expect(q.w, closeTo(1.0, 1e-12), reason: id);
        expect(q.x, closeTo(0.0, 1e-12), reason: id);
        expect(q.y, closeTo(0.0, 1e-12), reason: id);
        expect(q.z, closeTo(0.0, 1e-12), reason: id);
      }
    });

    test('every correction is a rotation and nothing else', () {
      // A quaternion off the unit sphere scales the mesh as well as turning
      // it, which would silently fight [PartDef.modelScale] and show up as a
      // part that is the wrong size only when it is also the wrong way up.
      for (final d in catalog.lem) {
        final q = d.modelRotation;
        final norm = q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z;
        expect(norm, closeTo(1.0, 1e-9), reason: d.id);
      }
    });
  });

  group('the mesh is seated back on the part origin', () {
    test('every export is authored off its origin except the deflector', () {
      // Six of the seven photograph clear of the part origin — five high, the
      // descent engine low. Zero here would mean the seating pass was lost.
      for (final id in const [
        'eagle-command-pod',
        'eagle-fuel-tank',
        'eagle-thruster',
        'eagle-legs',
        'eagle-rcs-solo',
      ]) {
        expect(def(id).modelOffset.length, greaterThan(0.05), reason: id);
      }
    });

    test('a seat never exceeds the part it seats', () {
      // The offset moves a mesh ONTO its origin; it is not a placement. One
      // longer than the part's own longest side means the number was measured
      // against the wrong frame, not that the art really sits that far out.
      for (final d in catalog.lem) {
        final longest = [d.size.x, d.size.y, d.size.z].reduce((a, b) => a > b ? a : b);
        expect(d.modelOffset.length, lessThanOrEqualTo(longest), reason: d.id);
      }
    });

    test('the descent engine is the one that hangs LOW', () {
      // Its bell photographs entirely below the origin, so its seat is the
      // only positive Z of the family. A sign flip here buries the bell in the
      // descent stage instead of hanging it under one.
      expect(def('eagle-thruster').modelOffset.z, greaterThan(0));
      for (final id in const [
        'eagle-command-pod',
        'eagle-fuel-tank',
        'eagle-rcs-solo',
      ]) {
        expect(def(id).modelOffset.z, lessThan(0), reason: id);
      }
    });

    test('seating the art never moves the hardware', () {
      // ART ONLY: mass, inertia, attach nodes and docking ports are anchored
      // to the part origin and must not absorb a millimetre of the seat. The
      // pod is the sharpest case — it carries both a 1.4 m seat and the tunnel
      // the CSM docks to.
      final pod = def('eagle-command-pod');
      expect(pod.modelOffset.z, isNot(0));
      expect(pod.dockingPort!.position.z, 1.73);
      final dockTop =
          pod.attachNodes.firstWhere((n) => n.name == 'dock-top');
      expect(dockTop.position.z, 1.73);
      final stageBottom =
          pod.attachNodes.firstWhere((n) => n.name == 'stage-bottom');
      expect(stageBottom.position.z, -1.73);
    });
  });

  test('the documented sweep reproduces the values that were committed', () {
    // [LemParts]' class doc prints the exact `ext.acro.camera` calls that
    // settled the landing gear, so a reader can re-run the measurement. That
    // only holds while the calls still compose to what is in the file — and a
    // stale recipe is worse than none, because it looks authoritative and
    // quietly re-derives a different part.
    //
    // MIRRORS `_eulerDeg` in lib/main_part_calibration_dev.dart (and the
    // identical one in main_scene_dev.dart): partRotDeg is degrees about the
    // FIXED X, then Y, then Z, i.e. Rz * Ry * Rx. Change the convention there
    // and this fails, which is the point — the doc quotes those handlers.
    Quaternion eulerDeg(double x, double y, double z) {
      const k = 3.141592653589793 / 180;
      return Quaternion.axisAngle(Vector3.unitZ, z * k) *
          Quaternion.axisAngle(Vector3.unitY, y * k) *
          Quaternion.axisAngle(Vector3.unitX, x * k);
    }

    // `ext.acro.camera?part=eagle-legs&partRotDeg=90,0,90`
    final swept = eulerDeg(90, 0, 90);
    final shipped = def('eagle-legs').modelRotation;
    expect(swept.w, closeTo(shipped.w, 1e-12));
    expect(swept.x, closeTo(shipped.x, 1e-12));
    expect(swept.y, closeTo(shipped.y, 1e-12));
    expect(swept.z, closeTo(shipped.z, 1e-12));

    // `ext.acro.camera?part=eagle-legs&partOffsetM=-1.26,0,0.59`
    expect(def('eagle-legs').modelOffset, const Vector3(-1.26, 0, 0.59));
    // `ext.acro.camera?part=eagle-legs&partScale=2.4`
    expect(def('eagle-legs').modelScale, 2.4);
  });

  test('the family still shares one model-unit scale', () {
    // The ruler confirmed it twice over: the DPS bell measures 1.49 m across
    // against a published 1.50 m exit diameter, and a landing leg's drawn box
    // is 2.68 x 2.34 x 3.29 m against the 2.54 x 2.37 x 3.22 m declared. A
    // per-part literal appearing here means one export disagreed with the
    // other six and the reason belongs next to it.
    for (final d in catalog.lem) {
      expect(d.modelScale, LemParts.modelUnitToMetres, reason: d.id);
    }
  });
}
