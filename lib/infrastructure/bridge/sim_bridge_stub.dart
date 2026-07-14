// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

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
