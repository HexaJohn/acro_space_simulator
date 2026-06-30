@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:acro_space_simulator/infrastructure/bridge/frame_protocol.dart';
import 'package:acro_space_simulator/infrastructure/bridge/sim_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// The in-process serve path: createSimBridge() on the VM is the dart:io socket
/// server. A renderer (here, a raw socket standing in for Unreal) gets the
/// latest published world and the bridge surfaces what the renderer sends back.
void main() {
  test('serves the latest frame to a new client and on every publish', () async {
    final bridge = createSimBridge();
    addTearDown(bridge.stop);
    await bridge.start(port: 0); // ephemeral

    bridge.publish(Uint8List.fromList([1, 2, 3])); // before anyone connects

    final socket = await Socket.connect(InternetAddress.loopbackIPv4, bridge.port);
    addTearDown(socket.destroy);
    final received = <List<int>>[];
    final parser = FrameParser();
    socket.listen((chunk) => received.addAll(parser.addChunk(chunk)));

    // 1) The newest world is handed to a client the moment it connects.
    await _until(() => received.isNotEmpty);
    expect(received.single, [1, 2, 3]);

    // 2) Subsequent publishes broadcast to the connected client.
    bridge.publish(Uint8List.fromList([4, 5]));
    await _until(() => received.length >= 2);
    expect(received[1], [4, 5]);
  });

  test('surfaces incoming command frames from a client', () async {
    final bridge = createSimBridge();
    addTearDown(bridge.stop);
    await bridge.start(port: 0);

    final socket = await Socket.connect(InternetAddress.loopbackIPv4, bridge.port);
    addTearDown(socket.destroy);

    final got = <List<int>>[];
    final sub = bridge.commandFrames.listen(got.add);
    addTearDown(sub.cancel);

    socket.add(frameMessage(Uint8List.fromList([9, 8, 7])));
    await socket.flush();

    await _until(() => got.isNotEmpty);
    expect(got.single, [9, 8, 7]);
  });

  test('hasClients tracks connect and disconnect', () async {
    final bridge = createSimBridge();
    addTearDown(bridge.stop);
    await bridge.start(port: 0);
    expect(bridge.hasClients, isFalse);

    final socket = await Socket.connect(InternetAddress.loopbackIPv4, bridge.port);
    await _until(() => bridge.hasClients);
    expect(bridge.hasClients, isTrue);

    await socket.close();
    socket.destroy();
    await _until(() => !bridge.hasClients);
    expect(bridge.hasClients, isFalse);
  });
}

/// Poll [cond] up to ~2s — bridge I/O is async across event-loop turns.
Future<void> _until(bool Function() cond) async {
  for (var i = 0; i < 200; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not met within timeout');
}
