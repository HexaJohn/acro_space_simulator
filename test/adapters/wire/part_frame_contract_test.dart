// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/wire/flatbuffer_codec.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/vessel_assembler.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

/// What `PartFrame` in `wire/sim.fbs` promises an out-of-process client, checked
/// against what the codec actually writes.
///
/// The comment in the .fbs is the whole specification for anyone building on the
/// other side of the bridge — they cannot read this repo's Dart to find out what
/// a field means. It has been wrong once already (it described `type` as the
/// part's display name after the sim started sending catalog ids), and nothing
/// failed, because a stale comment compiles. These tests are what make the next
/// drift loud.
void main() {
  const codec = FlatBufferCodec();
  final catalog = PartCatalog.standard();
  const assembler = VesselAssembler();

  /// A descent stage on its four landing legs: the smallest craft that exercises
  /// the case the contract is about — ONE leg part mounted at four yaws.
  Vessel buildLanderBase() {
    final d = CraftDesign(name: 'Eagle')
      ..addPart(def: catalog.byId('eagle-fuel-tank')!, instanceId: 'descent');
    for (var i = 1; i <= 4; i++) {
      d.attachPart(
        def: catalog.byId('eagle-legs')!,
        instanceId: 'leg-$i',
        toInstanceId: 'descent',
        parentNode: 'leg-$i',
        childNode: 'outrigger',
      );
    }
    return assembler.assemble(
      id: 'lm-5',
      name: d.name,
      ownerId: 'crew',
      parts: d.parts,
      state: const StateVector(
          position: Vector3(1837400, 0, 0), velocity: Vector3(0, 1633, 0)),
      dominantBody: const BodyId('moon'),
    );
  }

  WorldSnapshot roundTrip(WorldSnapshot s) =>
      codec.decodeWorld(codec.encodeWorld(s));

  test('PartFrame.type reaches the far side as the catalog id', () {
    final snap = WorldSnapshot(
      tick: 1,
      vessels: {'lm-5': VesselSnapshot.of(buildLanderBase())},
    );

    final types = roundTrip(snap).vessels['lm-5']!.parts.map((p) => p.type);

    // Every key an engine asset table is asked to resolve is a catalog id...
    for (final t in types) {
      expect(catalog.byId(t), isNotNull,
          reason: '$t is not a catalog id, so an asset table keyed by id '
              'resolves nothing and the part draws as an unknown mesh');
    }
    expect(types, contains('eagle-legs'));
    expect(types, contains('eagle-fuel-tank'));
    // ...and never the display name: it is free to change with the copy, and
    // an asset table keyed by it resolves nothing the moment it does.
    expect(types, isNot(contains('Eagle Landing Gear Leg')));
    expect(types, isNot(contains(catalog.byId('eagle-legs')!.name)));
  });

  test('per-part orientation does not survive the wire', () {
    // TRIPWIRE, not an endorsement. `PartFrame` has no quaternion field, so the
    // encoder drops the sim's per-part rotation and the decoder substitutes
    // identity — the GAP recorded in wire/sim.fbs and on FlatBufferCodec. The
    // four legs are ONE mesh mounted a quarter turn apart, so they reach a
    // bridged renderer all facing the same way while the in-process renderer
    // (which never serialises) draws them correctly.
    //
    // When `rot:Quat` lands on `PartFrame`, this test must be INVERTED to assert
    // the rotation round-trips, and both GAP notes deleted with it.
    final sent = VesselSnapshot.of(buildLanderBase());
    final turned = sent.parts.where((p) => !p.isUnrotated).toList();
    expect(turned, isNotEmpty,
        reason: 'the sim really does give the legs their own facings — '
            'without that there is nothing for the wire to lose');

    final back = roundTrip(WorldSnapshot(tick: 1, vessels: {'lm-5': sent}))
        .vessels['lm-5']!;

    // Offsets survive, so the parts are in the right PLACES...
    expect(back.parts.map((p) => p.id), sent.parts.map((p) => p.id));
    for (var i = 0; i < back.parts.length; i++) {
      expect(back.parts[i].ox, closeTo(sent.parts[i].ox, 1e-9));
      expect(back.parts[i].oy, closeTo(sent.parts[i].oy, 1e-9));
    }
    // ...and every one of them arrives unrotated.
    expect(back.parts.every((p) => p.isUnrotated), isTrue,
        reason: 'PartFrame gained an orientation field without the wire '
            'contract notes being updated');
  });
}
