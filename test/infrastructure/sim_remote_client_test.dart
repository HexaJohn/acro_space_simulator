import 'dart:io';

import 'package:acro_space_simulator/infrastructure/bridge/sim_host.dart';
import 'package:acro_space_simulator/infrastructure/bridge/sim_remote_client.dart';
import 'package:acro_space_simulator/infrastructure/bridge/sim_socket_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote client drives the shared server and sees the result', () async {
    final server = SimSocketServer(
      SimHost.sample(),
      tickInterval: const Duration(milliseconds: 10),
    );
    await server.start();
    addTearDown(server.stop);

    final client = SimRemoteClient(playerId: 'player-1');
    addTearDown(client.dispose);
    await client.connect(InternetAddress.loopbackIPv4.address, server.port);

    // Drive the demo vessel to full throttle, then watch it come back in a frame.
    client.setThrottle('demo-1', 1.0);

    final frame = await client.frames
        .firstWhere((w) => w.vessels['demo-1']?.throttle == 1.0)
        .timeout(const Duration(seconds: 5));

    expect(frame.vessels['demo-1']!.throttle, 1.0);
    // The same frame carries the orbit + bodies the renderer uses.
    expect(frame.bodies.keys, contains('earth'));
    expect(frame.vessels['demo-1']!.periapsis, greaterThan(0));
  });
}
