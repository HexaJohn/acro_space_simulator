import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/adapters/wire/flatbuffer_codec.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/multiplayer/command.dart';
import 'package:acro_space_simulator/domain/multiplayer/player.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = FlatBufferCodec();

  test('WorldSnapshot survives a FlatBuffer round-trip', () {
    final vessel = SampleWorld.buildVessel()
      ..state = SampleWorld.buildVessel().state.copyWith(
            attitude: Quaternion.axisAngle(Vector3.unitZ, 0.7),
            angularVelocity: Vector3(0.01, -0.02, 0.03),
          );
    final vessels = InMemoryVesselRepository([vessel]);
    final colonies = InMemoryColonyRepository()..save(SampleWorld.buildColony());
    final snap = WorldSnapshot.capture(99, vessels,
        system: SampleWorld.buildSystem(),
        epoch: const Epoch(321.5),
        colonies: colonies);

    final back = codec.decodeWorld(codec.encodeWorld(snap));

    // Identical determinism fingerprint == the vessel state survived the wire.
    expect(back.fingerprint, snap.fingerprint);
    expect(back.tick, 99);
    expect(back.epoch, 321.5);

    final a = snap.vessels['demo-1']!, b = back.vessels['demo-1']!;
    expect(b.qw, closeTo(a.qw, 1e-12));
    expect(b.qz, closeTo(a.qz, 1e-12));
    expect(b.wy, closeTo(a.wy, 1e-12));
    expect(b.px, closeTo(a.px, 1e-9));
    expect(b.landed, a.landed);

    // Per-part manifest survives the wire.
    expect(b.parts, isNotEmpty);
    expect(b.parts.map((p) => p.type), contains('LV-T45'));
    expect(b.parts.first.id, a.parts.first.id);

    expect(back.bodies.keys.toSet(), {'kerbin', 'mun'});
    final am = snap.bodies['mun']!, bm = back.bodies['mun']!;
    expect(bm.px, closeTo(am.px, 1e-6));
    expect(bm.qw, closeTo(am.qw, 1e-12));
    expect(bm.radius, am.radius);

    // Colony buildings survive, body-fixed near the planet radius.
    expect(back.buildings, isNotEmpty);
    final refinery = back.buildings['colony-1/refinery-1']!;
    expect(refinery.type, 'refinery');
    expect(refinery.body, 'kerbin');
    expect(refinery.colonyId, 'colony-1');
    final original = snap.buildings['colony-1/refinery-1']!;
    expect(refinery.px, closeTo(original.px, 1e-6));
    expect(refinery.lat, closeTo(original.lat, 1e-12));
  });

  test('CommandBatch round-trips all four command variants', () {
    const by = PlayerId('alice');
    final batch = CommandBatch(const Epoch(12.5), const [
      SetThrottleCommand(by, 3, 'demo-1', 0.75),
      SeparateStageCommand(by, 4, 'demo-1'),
      SetAttitudeCommand(by, 5, 'demo-1', 0.0, 1.0, 0.0),
      PlaceBuildingCommand(by, 6, 'colony-1', 'hab', 2, 3),
      ReportTerrainHeightCommand(by, 7, 'kerbin', 0.1, 0.2, 42.0),
    ]);

    final back = codec.decodeCommands(codec.encodeCommands(batch));

    expect(back.at.seconds, 12.5);
    expect(back.commands.length, 5);

    final t = back.commands[0] as SetThrottleCommand;
    expect(t.vesselId, 'demo-1');
    expect(t.throttle, 0.75);
    expect(t.issuedBy, const PlayerId('alice'));
    expect(t.tick, 3);

    expect(back.commands[1], isA<SeparateStageCommand>());

    final a = back.commands[2] as SetAttitudeCommand;
    expect([a.headingX, a.headingY, a.headingZ], [0.0, 1.0, 0.0]);

    final p = back.commands[3] as PlaceBuildingCommand;
    expect(p.colonyId, 'colony-1');
    expect(p.buildingType, 'hab');
    expect([p.gridX, p.gridY], [2, 3]);

    final r = back.commands[4] as ReportTerrainHeightCommand;
    expect(r.body, 'kerbin');
    expect([r.lat, r.lon, r.height], [0.1, 0.2, 42.0]);
  });
}
