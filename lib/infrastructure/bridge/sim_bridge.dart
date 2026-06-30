import 'dart:typed_data';

// Conditional impl: real dart:io socket server on desktop/mobile, no-op on web.
// SimulationView depends only on this file, so the web build never sees dart:io.
import 'sim_bridge_stub.dart' if (dart.library.io) 'sim_bridge_io.dart';

/// Serves the Flutter app's IN-PROCESS simulation to external renderers (Unreal)
/// over the engine-bridge socket protocol. The app stays authoritative: it
/// [publish]es a WorldFrame each tick and exposes the [commandFrames] clients
/// send back, which the app applies to its own repos.
///
/// On web this is a no-op (sockets aren't available; Unreal is desktop anyway),
/// so the game just runs in-process as before.
abstract class SimBridge {
  /// Begin listening. Safe no-op on web.
  Future<void> start({int port = 5800});

  /// The actual bound port (e.g. when started with 0 for an ephemeral port);
  /// 0 when not started / on web.
  int get port;

  /// True when at least one renderer is connected — gate the (cheap-but-not-free)
  /// snapshot capture/encode on this so there's zero cost when nothing's attached.
  bool get hasClients;

  /// Broadcast one encoded WorldFrame to all connected renderers.
  void publish(Uint8List worldFrame);

  /// Raw CommandFrame bytes arriving from renderers (decode with FlatBufferCodec).
  Stream<Uint8List> get commandFrames;

  Future<void> stop();
}

/// The platform-appropriate [SimBridge] (io impl on desktop, stub on web).
SimBridge createSimBridge() => makeSimBridge();
