import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:acro_space_simulator/adapters/wire/flatbuffer_codec.dart';
import 'package:acro_space_simulator/domain/multiplayer/command.dart';
import 'package:acro_space_simulator/domain/multiplayer/player.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/infrastructure/bridge/frame_protocol.dart';
import 'package:acro_space_simulator/infrastructure/bridge/sim_host.dart';
import 'package:acro_space_simulator/infrastructure/bridge/sim_socket_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = FlatBufferCodec();

  test('a client drives the sim over a TCP socket and sees the result', () async {
    final server = SimSocketServer(
      SimHost.sample(),
      tickInterval: const Duration(milliseconds: 10),
    );
    await server.start();
    addTearDown(server.stop);

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    addTearDown(socket.destroy);

    // Throttle the demo vessel to full.
    final cmd = codec.encodeCommands(CommandBatch(Epoch.zero, const [
      SetThrottleCommand(PlayerId('player-1'), 0, 'demo-1', 1.0),
    ]));
    socket.add(frameMessage(cmd));
    await socket.flush();

    // Read broadcast WorldFrames until the throttle change appears.
    final parser = FrameParser();
    final seen = Completer<double>();
    final sub = socket.listen((chunk) {
      for (final payload in parser.addChunk(chunk)) {
        final v = codec.decodeWorld(payload).vessels['demo-1'];
        if (v != null && v.throttle == 1.0 && !seen.isCompleted) {
          seen.complete(v.throttle);
        }
      }
    });
    addTearDown(sub.cancel);

    expect(await seen.future.timeout(const Duration(seconds: 5)), 1.0);
  });

  test('a malformed command frame does not crash the server', () async {
    final server = SimSocketServer(
      SimHost.sample(),
      tickInterval: const Duration(milliseconds: 10),
    );
    await server.start();
    addTearDown(server.stop);

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    addTearDown(socket.destroy);

    // Garbage payload (not a valid CommandFrame), then a real command. The
    // server must swallow the bad frame and still apply the good one.
    socket.add(frameMessage(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])));
    socket.add(frameMessage(codec.encodeCommands(CommandBatch(Epoch.zero, const [
      SetThrottleCommand(PlayerId('player-1'), 0, 'demo-1', 1.0),
    ]))));
    await socket.flush();

    final parser = FrameParser();
    final seen = Completer<double>();
    final sub = socket.listen((chunk) {
      for (final payload in parser.addChunk(chunk)) {
        final v = codec.decodeWorld(payload).vessels['demo-1'];
        if (v != null && v.throttle == 1.0 && !seen.isCompleted) {
          seen.complete(v.throttle);
        }
      }
    });
    addTearDown(sub.cancel);

    expect(await seen.future.timeout(const Duration(seconds: 5)), 1.0);
  });

  test('a connecting client receives an initial frame with bodies', () async {
    final server = SimSocketServer(
      SimHost.sample(),
      tickInterval: const Duration(milliseconds: 10),
    );
    await server.start();
    addTearDown(server.stop);

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    addTearDown(socket.destroy);

    final parser = FrameParser();
    final first = Completer<Set<String>>();
    final sub = socket.listen((chunk) {
      for (final payload in parser.addChunk(chunk)) {
        if (!first.isCompleted) {
          first.complete(codec.decodeWorld(payload).bodies.keys.toSet());
        }
      }
    });
    addTearDown(sub.cancel);

    expect(
      await first.future.timeout(const Duration(seconds: 5)),
      containsAll(<String>{'kerbin', 'mun'}),
    );
  });
}
