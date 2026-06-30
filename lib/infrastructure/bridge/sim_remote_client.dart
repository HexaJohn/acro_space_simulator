import 'dart:async';
import 'dart:io';

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/multiplayer/command.dart';
import '../../domain/multiplayer/player.dart';
import '../../domain/simulation/epoch.dart';
import '../../adapters/wire/flatbuffer_codec.dart';
import 'frame_protocol.dart';

/// Client side of the engine bridge: connects to a standalone authoritative
/// server (`bin/sim_server.dart`) over TCP, decodes the streamed
/// [WorldSnapshot]s, and sends player commands. Kept for the future multiplayer
/// path (many desktop clients of one shared server); the in-process serve path
/// — the app hosting its own sim for Unreal — is [SimBridge] instead.
///
/// Uses `dart:io` sockets, so this is DESKTOP/mobile only — keep it out of the
/// web build (only import it behind a `dart.library.io` conditional).
class SimRemoteClient {
  final FlatBufferCodec codec;
  String playerId;

  Socket? _socket;
  final FrameParser _parser = FrameParser();
  final StreamController<WorldSnapshot> _frames =
      StreamController<WorldSnapshot>.broadcast();

  SimRemoteClient({
    this.playerId = 'player-1',
    this.codec = const FlatBufferCodec(),
  });

  /// World frames as they arrive from the server.
  Stream<WorldSnapshot> get frames => _frames.stream;
  bool get isConnected => _socket != null;

  Future<void> connect(String host, int port) async {
    await disconnect();
    final socket = await Socket.connect(host, port);
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    socket.listen(
      (chunk) {
        try {
          for (final payload in _parser.addChunk(chunk)) {
            try {
              _frames.add(codec.decodeWorld(payload));
            } catch (_) {
              // skip a malformed/foreign frame
            }
          }
        } on FormatException {
          disconnect(); // framing desync — unrecoverable
        }
      },
      onError: (_) => disconnect(),
      onDone: disconnect,
      cancelOnError: true,
    );
  }

  Future<void> disconnect() async {
    final socket = _socket;
    _socket = null;
    socket?.destroy();
  }

  void _send(SimCommand cmd) {
    final socket = _socket;
    if (socket == null) return;
    socket.add(frameMessage(codec.encodeCommands(CommandBatch(Epoch.zero, [cmd]))));
  }

  void setThrottle(String vesselId, double throttle) =>
      _send(SetThrottleCommand(PlayerId(playerId), 0, vesselId, throttle));

  void separateStage(String vesselId) =>
      _send(SeparateStageCommand(PlayerId(playerId), 0, vesselId));

  /// Point the craft's nose along a forward axis (any vector; sim normalises).
  void setAttitude(String vesselId, double x, double y, double z) =>
      _send(SetAttitudeCommand(PlayerId(playerId), 0, vesselId, x, y, z));

  Future<void> dispose() async {
    await disconnect();
    await _frames.close();
  }
}
