// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import '../../domain/multiplayer/command.dart';
import '../snapshot/world_snapshot.dart';

/// Transport boundary between a client and the authoritative server. The client
/// pushes command batches up and pulls authoritative snapshots down; how the
/// bytes move (loopback, WebSocket, UDP) is an infrastructure concern behind
/// this port.
///
/// This is the seam that keeps the deterministic simulation independent of any
/// particular networking stack.
abstract class NetworkChannel {
  /// Submit the local player's commands for a tick to the server.
  void sendCommands(CommandBatch batch);

  /// The latest authoritative snapshot the client has received, or null if none
  /// has arrived yet. A real channel buffers; the loopback returns the freshest.
  WorldSnapshot? pollSnapshot();
}
