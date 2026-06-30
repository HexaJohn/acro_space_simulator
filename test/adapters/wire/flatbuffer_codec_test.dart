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
        system: SampleWorld.realSystem(),
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

    // The real system has many bodies; assert the two we care about survived.
    expect(back.bodies.keys, contains('earth'));
    expect(back.bodies.keys, contains('moon'));
    final am = snap.bodies['moon']!, bm = back.bodies['moon']!;
    expect(bm.px, closeTo(am.px, 1e-6));
    expect(bm.qw, closeTo(am.qw, 1e-12));
    expect(bm.radius, am.radius);

    // Body orbit rings survive the wire: the Moon (a child) carries a closed
    // ring of x,y,z triples; the Sun (system root) carries none. The ring sits
    // ~the Moon's orbit radius from Earth (root-relative, same frame as pos).
    expect(am.orbit, isNotEmpty);
    expect(am.orbit.length % 3, 0);
    expect(bm.orbit.length, am.orbit.length);
    expect(bm.orbit.first, closeTo(am.orbit.first, 1e-6));
    expect(back.bodies['sun']!.orbit, isEmpty);

    // Colony buildings survive, body-fixed near the planet radius.
    expect(back.buildings, isNotEmpty);
    final refinery = back.buildings['colony-1/refinery-1']!;
    expect(refinery.type, 'refinery');
    expect(refinery.body, 'earth');
    expect(refinery.colonyId, 'colony-1');
    final original = snap.buildings['colony-1/refinery-1']!;
    expect(refinery.px, closeTo(original.px, 1e-6));
    expect(refinery.lat, closeTo(original.lat, 1e-12));

    // Telemetry survives: mass + aggregated resource gauge.
    expect(b.mass, closeTo(a.mass, 1e-6));
    expect(b.mass, greaterThan(0));
    final fuel = b.resources.firstWhere((r) => r.type == 'liquidFuel');
    expect(fuel.capacity, 400);

    // Orbit + trajectory: demo-1 is in a ~circular low orbit (~200 km up).
    expect(a.periapsis, greaterThan(6.371e6)); // above Earth's surface radius
    expect(a.apoapsis, closeTo(a.periapsis, a.periapsis * 0.05)); // near-circular
    expect(a.eccentricity, lessThan(0.05));
    expect(a.trajectory.length, greaterThan(0));
    expect(a.trajectory.length % 3, 0); // flat x,y,z triples
    // ...and they survive the wire.
    expect(b.periapsis, closeTo(a.periapsis, 1e-3));
    expect(b.apoapsis, closeTo(a.apoapsis, 1e-3));
    expect(b.period, closeTo(a.period, 1e-3));
    expect(b.trajectory.length, a.trajectory.length);
    expect(b.connected, a.connected);
    expect(b.commDelay, closeTo(a.commDelay, 1e-9));
  });

  test('body render descriptors round-trip through the codec', () {
    final vessels = InMemoryVesselRepository([SampleWorld.buildVessel()]);
    final snap = WorldSnapshot.capture(7, vessels,
        system: SampleWorld.realSystem(), epoch: const Epoch(0));

    final back = codec.decodeWorld(codec.encodeWorld(snap));

    // A descriptor exists for every body in the frame, joined by id.
    expect(back.descriptors.keys.toSet(), back.bodies.keys.toSet());

    // Classification survives: the star is a star, a planet's satellite a moon,
    // a planet orbiting the star directly is rocky.
    expect(back.descriptors['sun']!.kind, BodyKind.star);
    expect(back.descriptors['moon']!.kind, BodyKind.moon);
    expect(back.descriptors['earth']!.kind, BodyKind.rocky);

    // The descriptor's datum matches the dynamic body's radius (same source).
    final ed = back.descriptors['earth']!;
    expect(ed.referenceRadius, back.bodies['earth']!.radius);

    // Atmosphere physics survive the wire losslessly (whatever Earth's model is).
    final es = snap.descriptors['earth']!;
    expect(ed.atmoPresent, es.atmoPresent);
    expect(ed.atmoScaleHeight, closeTo(es.atmoScaleHeight, 1e-6));
    expect(ed.atmoThickness, closeTo(es.atmoThickness, 1e-6));
    expect(ed.atmoSeaLevelPressure, closeTo(es.atmoSeaLevelPressure, 1e-6));

    // Atmospheric COMPOSITION survives: Earth's mix is nitrogen-dominated, its
    // mean molecular weight sits near air's ~0.029 kg/mol, and the derived
    // composition-blended scatter tint is non-zero — all round-trip exactly.
    expect(ed.atmoGases, isNotEmpty);
    expect(ed.atmoGases.length, es.atmoGases.length);
    expect(ed.atmoMeanMolecularWeight, closeTo(es.atmoMeanMolecularWeight, 1e-12));
    expect(ed.atmoMeanMolecularWeight, closeTo(0.029, 0.003));
    expect(ed.atmoScatterColorArgb, es.atmoScatterColorArgb);
    expect(ed.atmoScatterColorArgb, isNot(0));
    final dominant =
        ed.atmoGases.reduce((a, b) => a.fraction >= b.fraction ? a : b);
    expect(dominant.gas, 0); // AtmosphereGas.nitrogen
    expect(dominant.fraction, greaterThan(0.5));
    final fractionSum =
        ed.atmoGases.fold<double>(0, (s, g) => s + g.fraction);
    expect(fractionSum, closeTo(1.0, 1e-9)); // mole fractions normalise to 1

    // The airless Sun carries no composition.
    expect(back.descriptors['sun']!.atmoGases, isEmpty);
    expect(back.descriptors['sun']!.atmoScatterColorArgb, 0);
  });

  test('body descriptors gate out of the frame for low-frequency publish', () {
    final vessels = InMemoryVesselRepository([SampleWorld.buildVessel()]);
    final system = SampleWorld.realSystem();

    final withDesc = WorldSnapshot.capture(1, vessels, system: system);
    final without = WorldSnapshot.capture(2, vessels,
        system: system, includeDescriptors: false);

    expect(withDesc.descriptors, isNotEmpty);
    expect(without.descriptors, isEmpty);
    // Dynamic bodies still ship every frame — only the static descriptors gate.
    expect(without.bodies, isNotEmpty);
    // A gated frame round-trips with no descriptors (engine keeps its cache).
    expect(codec.decodeWorld(codec.encodeWorld(without)).descriptors, isEmpty);
  });

  test('events round-trip through the codec', () {
    final snap = WorldSnapshot(tick: 5, vessels: const {}, events: const [
      EventSnapshot(
          kind: 'Impact', subject: 'demo-1', target: 'earth', magnitude: 42.0),
      EventSnapshot(kind: 'StageSeparation', subject: 'demo-1', magnitude: 1),
      EventSnapshot(kind: 'CrewLost', subject: 'demo-1', info: 'oxygen'),
    ]);

    final back = codec.decodeWorld(codec.encodeWorld(snap));

    expect(back.events.length, 3);
    expect(back.events[0].kind, 'Impact');
    expect(back.events[0].subject, 'demo-1');
    expect(back.events[0].target, 'earth');
    expect(back.events[0].magnitude, 42.0);
    expect(back.events[1].kind, 'StageSeparation');
    expect(back.events[1].magnitude, 1);
    expect(back.events[2].kind, 'CrewLost');
    expect(back.events[2].info, 'oxygen');
  });

  test('CommandBatch round-trips all four command variants', () {
    const by = PlayerId('alice');
    final batch = CommandBatch(const Epoch(12.5), const [
      SetThrottleCommand(by, 3, 'demo-1', 0.75),
      SeparateStageCommand(by, 4, 'demo-1'),
      SetAttitudeCommand(by, 5, 'demo-1', 0.0, 1.0, 0.0),
      PlaceBuildingCommand(by, 6, 'colony-1', 'hab', 2, 3),
      ReportTerrainHeightCommand(by, 7, 'earth', 0.1, 0.2, 42.0),
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
    expect(r.body, 'earth');
    expect([r.lat, r.lon, r.height], [0.1, 0.2, 42.0]);
  });
}
