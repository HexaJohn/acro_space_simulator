import 'dart:async';
import 'dart:io';

import 'package:acro_space_simulator/infrastructure/bridge/sim_host.dart';
import 'package:acro_space_simulator/infrastructure/bridge/sim_socket_server.dart';

/// Standalone authoritative simulation server for the Unreal bridge.
///
///   dart run bin/sim_server.dart [port] [tickHz]
///
/// Defaults: port 5800, 20 Hz. Streams WorldFrame FlatBuffers to every
/// connected client and applies the CommandFrames they send. Pure Dart VM —
/// no Flutter engine required.
Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args[0]) : 5800;
  final hz = args.length > 1 ? double.tryParse(args[1]) : 20.0;
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('usage: sim_server [port 0-65535] [tickHz>0]');
    exit(64);
  }
  if (hz == null || hz <= 0) {
    stderr.writeln('tickHz must be > 0');
    exit(64);
  }
  final interval = Duration(microseconds: (1000000 / hz).round());

  // Run the server inside a guarded zone: a transport-layer async error
  // (a peer RST, a half-open socket) is logged and swallowed instead of
  // terminating the process. Per-client errors are also handled at the source.
  await runZonedGuarded(() async {
    final server = SimSocketServer(SimHost.sample(), tickInterval: interval);
    await server.start(port: port);
    stdout.writeln(
      'acro sim server: 127.0.0.1:${server.port}  tick=${hz.toStringAsFixed(0)}Hz  '
      '(length-prefixed FlatBuffer frames; WorldFrame out, CommandFrame in)',
    );

    ProcessSignal.sigint.watch().listen((_) async {
      stdout.writeln('shutting down...');
      await server.stop();
      exit(0);
    });
  }, (error, stack) {
    stderr.writeln('transport error (continuing): $error');
  });
}
