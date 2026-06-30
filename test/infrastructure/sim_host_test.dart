import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/wire/flatbuffer_codec.dart';
import 'package:acro_space_simulator/domain/multiplayer/command.dart';
import 'package:acro_space_simulator/domain/multiplayer/player.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/infrastructure/bridge/sim_host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = FlatBufferCodec();

  test('full bridge loop: command bytes in -> tick -> world bytes out', () {
    final host = SimHost.sample(owner: 'player-1');

    final cmd = codec.encodeCommands(CommandBatch(Epoch.zero, const [
      SetThrottleCommand(PlayerId('player-1'), 0, 'demo-1', 1.0),
    ]));
    host.submit(cmd);
    host.step();

    final frame = codec.decodeWorld(host.frameBytes());
    expect(host.tick, 1);
    expect(frame.vessels['demo-1']!.throttle, 1.0);
    expect(frame.bodies.keys, contains('kerbin'));
  });

  test('an unowned command is rejected at the bridge', () {
    final host = SimHost.sample(owner: 'player-1');
    final cmd = codec.encodeCommands(CommandBatch(Epoch.zero, const [
      SetThrottleCommand(PlayerId('intruder'), 0, 'demo-1', 1.0),
    ]));
    host.submit(cmd);
    host.step();

    final frame = codec.decodeWorld(host.frameBytes());
    expect(frame.vessels['demo-1']!.throttle, 0.0);
  });

  test('the sample frame carries craft parts and colony buildings', () {
    final host = SimHost.sample();
    host.step();
    final frame = codec.decodeWorld(host.frameBytes());

    expect(frame.vessels['demo-1']!.parts.map((p) => p.type), contains('LV-T45'));
    expect(frame.buildings.keys, contains('colony-1/refinery-1'));
    expect(frame.buildings['colony-1/refinery-1']!.body, 'kerbin');
  });

  test('a terrain-height report lifts a building radially (ownership-exempt)', () {
    final host = SimHost.sample(owner: 'player-1');
    host.step();
    final before =
        codec.decodeWorld(host.frameBytes()).buildings['colony-1/refinery-1']!;
    final r0 = _len(before.px, before.py, before.pz);

    // Report a 500 m terrain height at the building's own lat/lon, from an
    // UNOWNED player — terrain reports bypass ownership.
    host.submit(codec.encodeCommands(CommandBatch(Epoch.zero, [
      ReportTerrainHeightCommand(
          const PlayerId('renderer'), 0, before.body, before.lat, before.lon, 500.0),
    ])));
    host.step();

    final after =
        codec.decodeWorld(host.frameBytes()).buildings['colony-1/refinery-1']!;
    final r1 = _len(after.px, after.py, after.pz);
    expect(r1 - r0, closeTo(500.0, 0.5));
  });
}

double _len(double x, double y, double z) =>
    math.sqrt(x * x + y * y + z * z);
