import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/parts/vessel_assembler.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = PartCatalog.standard();
  const assembler = VesselAssembler();

  PlacedPart place(String id, String inst, Vector3 pos, {int stage = 0}) =>
      PlacedPart(def: catalog.byId(id)!, instanceId: inst, position: pos, stage: stage);

  test('baked vessel total mass equals the sum of part masses', () {
    final parts = [
      place('mk1-capsule', 'pod', Vector3.zero),
      place('fl-t400', 'tank', const Vector3(0, 0, -2)),
      place('merlin-1d', 'eng', const Vector3(0, 0, -4)),
    ];
    final v = assembler.assemble(
      id: 'rocket-1',
      name: 'Test Rocket',
      ownerId: 'p',
      parts: parts,
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    final expected = parts.fold(0.0, (s, p) => s + p.def.dryMass) +
        catalog.byId('fl-t400')!.resources.fold(0.0, (s, r) => s + r.mass);
    expect(v.mass, closeTo(expected, 1.0));
  });

  test('baked into a SINGLE rigid body — one stage collapses to one part list', () {
    final parts = [
      place('mk1-capsule', 'pod', Vector3.zero),
      place('fl-t400', 'tank', const Vector3(0, 0, -2)),
    ];
    final v = assembler.assemble(
      id: 'r',
      name: 'r',
      ownerId: 'p',
      parts: parts,
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    // All same-stage parts end up in one stage.
    expect(v.stages.length, 1);
  });

  test('centre of mass is the mass-weighted average of part positions', () {
    // Two equal-mass structural parts at +Z=1 and -Z=1 -> CoM at z=0.
    final parts = [
      place('tr-18a-decoupler', 'a', const Vector3(0, 0, 1)),
      place('tr-18a-decoupler', 'b', const Vector3(0, 0, -1)),
    ];
    final v = assembler.assemble(
      id: 'r',
      name: 'r',
      ownerId: 'p',
      parts: parts,
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    expect(v.massProperties.centerOfMass.z, closeTo(0, 1e-6));
  });

  test('a crewed pod gives the vessel crew', () {
    final v = assembler.assemble(
      id: 'r',
      name: 'r',
      ownerId: 'p',
      parts: [place('mk1-capsule', 'pod', Vector3.zero)],
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    expect(v.crew, isNotNull);
    expect(v.crew!.count, 1);
  });

  test('an aircraft with wings + jet assembles with lift area and a jet engine', () {
    final v = assembler.assemble(
      id: 'plane',
      name: 'Plane',
      ownerId: 'p',
      parts: [
        place('cockpit-mk1', 'cockpit', Vector3.zero),
        place('swept-wing', 'wingL', const Vector3(-2, 0, 0)),
        place('swept-wing', 'wingR', const Vector3(2, 0, 0)),
        place('ram-intake', 'intake', const Vector3(0, 0, 1)),
        place('turbojet-j85', 'jet', const Vector3(0, 0, -2)),
        place('jet-fuel-tank', 'tank', const Vector3(0, 0, -1)),
      ],
      state: const StateVector(position: Vector3(6771000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    // Aggregated lift area from the two wings.
    expect(v.totalWingArea, closeTo(24.0, 1e-6));
    // Has an air-breathing engine and intake air.
    expect(v.hasJetEngine, isTrue);
    expect(v.totalIntakeArea, greaterThan(0));
  });

  test('staging groups become ordered stages', () {
    final parts = [
      place('mk1-capsule', 'pod', Vector3.zero, stage: 2),
      place('merlin-1d', 'upper', const Vector3(0, 0, -4), stage: 1),
      place('merlin-1d', 'booster', const Vector3(0, 0, -8), stage: 0),
    ];
    final v = assembler.assemble(
      id: 'r',
      name: 'r',
      ownerId: 'p',
      parts: parts,
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    expect(v.stages.length, 3);
    // Active stage = the last one fired (highest index in this model).
    expect(v.activeStage, isNotNull);
  });
}
