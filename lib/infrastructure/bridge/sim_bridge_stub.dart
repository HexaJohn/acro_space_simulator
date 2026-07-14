// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'sim_bridge.dart';

/// Web build: no sockets. The bridge does nothing, so the game runs purely
/// in-process (Unreal is desktop-only anyway).
SimBridge makeSimBridge() => _StubSimBridge();

class _StubSimBridge implements SimBridge {
  @override
  Future<void> start({int port = 5800}) async {}

  @override
  int get port => 0;

  @override
  bool get hasClients => false;

  @override
  void publish(Uint8List worldFrame) {}

  @override
  Stream<Uint8List> get commandFrames => const Stream.empty();

  @override
  Future<void> stop() async {}
}
