import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'frame_protocol.dart';
import 'sim_bridge.dart';

/// Desktop/mobile: a TCP broadcast server that serves the in-process sim. Same
/// length-prefixed FlatBuffer protocol the standalone bin/sim_server.dart uses,
/// so Unreal's USpaceSimSubsystem connects to the Flutter app the same way.
SimBridge makeSimBridge() => _IoSimBridge();

class _IoSimBridge implements SimBridge {
  ServerSocket? _server;
  final Set<Socket> _clients = {};
  Uint8List _latest = Uint8List(0);
  final StreamController<Uint8List> _commands =
      StreamController<Uint8List>.broadcast();

  @override
  int get port => _server?.port ?? 0;

  @override
  bool get hasClients => _clients.isNotEmpty;

  @override
  Stream<Uint8List> get commandFrames => _commands.stream;

  @override
  Future<void> start({int port = 5800}) async {
    if (_server != null) return;
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_accept);
  }

  void _accept(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _clients.add(socket);
    // Async write failures surface on done, not as a throw — catch so a dropped
    // renderer can't take the app down.
    unawaited(socket.done.then((_) => _drop(socket)).catchError((_) => _drop(socket)));

    final parser = FrameParser();
    socket.listen(
      (chunk) {
        try {
          for (final payload in parser.addChunk(chunk)) {
            _commands.add(Uint8List.fromList(payload));
          }
        } on FormatException {
          _drop(socket); // framing desync — unrecoverable
        }
      },
      onError: (_) => _drop(socket),
      onDone: () => _drop(socket),
      cancelOnError: true,
    );
    // Hand the new renderer the latest world right away.
    if (_latest.isNotEmpty) socket.add(frameMessage(_latest));
  }

  void _drop(Socket socket) {
    if (!_clients.remove(socket)) return; // teardown once
    socket.destroy();
  }

  @override
  void publish(Uint8List worldFrame) {
    _latest = worldFrame;
    final framed = frameMessage(worldFrame);
    for (final client in _clients.toList()) {
      try {
        client.add(framed);
      } catch (_) {
        _drop(client);
      }
    }
  }

  @override
  Future<void> stop() async {
    for (final client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
    await _server?.close();
    _server = null;
    await _commands.close();
  }
}
