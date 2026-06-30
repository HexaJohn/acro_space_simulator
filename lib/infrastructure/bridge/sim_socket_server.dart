import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'frame_protocol.dart';
import 'sim_host.dart';

/// Out-of-process engine transport: hosts a [SimHost] behind a TCP loopback
/// socket using length-prefixed FlatBuffer frames (see [frameMessage]).
///
/// Protocol, per connection:
///   * client -> server: CommandFrame frames (player intent), queued on the host.
///   * server -> client: a WorldFrame frame every tick (the render frame), plus
///     one immediately on connect so a fresh client has initial state.
///
/// The server ticks on its own fixed clock ([tickInterval]) independent of how
/// fast any client renders — the engine reads the latest frame and interpolates.
/// This mirrors the existing [LoopbackChannel] contract across a real socket;
/// a shared-memory ring is a drop-in faster transport later.
class SimSocketServer {
  final SimHost host;
  final Duration tickInterval;

  ServerSocket? _server;
  Timer? _timer;
  final Set<Socket> _clients = {};

  SimSocketServer(
    this.host, {
    this.tickInterval = const Duration(milliseconds: 50),
  });

  /// The actual bound port (resolves an ephemeral port when started with 0).
  int get port {
    final server = _server;
    if (server == null) {
      throw StateError('SimSocketServer not started');
    }
    return server.port;
  }

  Future<void> start({InternetAddress? address, int port = 0}) async {
    if (_server != null) {
      throw StateError('SimSocketServer already started');
    }
    _server = await ServerSocket.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    _server!.listen(_accept);
    _timer = Timer.periodic(tickInterval, (_) => _pump());
  }

  void _accept(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _clients.add(socket);
    // Async write failures (peer RST / broken pipe) surface on `done`, NOT as a
    // throw from add(); catch them here so a disconnecting client cannot escape
    // to the zone's unhandled-error handler and kill the process.
    unawaited(socket.done.then((_) => _drop(socket)).catchError((_) => _drop(socket)));

    final parser = FrameParser();
    socket.listen(
      (chunk) {
        try {
          for (final payload in parser.addChunk(chunk)) {
            try {
              host.submit(Uint8List.fromList(payload));
            } catch (_) {
              // Malformed CommandFrame — skip this frame, keep the connection.
            }
          }
        } on FormatException {
          _drop(socket); // framing desync (oversize/corrupt prefix) — unrecoverable
        }
      },
      onError: (_) => _drop(socket),
      onDone: () => _drop(socket),
      cancelOnError: true,
    );
    // Hand the new client the current world right away.
    socket.add(frameMessage(host.frameBytes()));
  }

  void _drop(Socket socket) {
    if (!_clients.remove(socket)) return; // already dropped — run teardown once
    socket.destroy();
  }

  void _pump() {
    host.step();
    final frame = frameMessage(host.frameBytes());
    for (final client in _clients.toList()) {
      try {
        client.add(frame);
      } catch (_) {
        // add() throws synchronously only if the sink is already closed; async
        // write failures are handled via socket.done in _accept.
        _drop(client);
      }
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    // Copy: destroy() can synchronously fire onDone -> _drop, mutating the set.
    for (final client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
    await _server?.close();
    _server = null;
  }
}
