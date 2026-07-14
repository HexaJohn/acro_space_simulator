// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import '../../domain/simulation/domain_event.dart';

/// Port for publishing domain events out of the simulation to interested
/// listeners (UI, achievements, networking). Adapters provide the transport.
abstract class EventBus {
  void publish(DomainEvent event);
  void publishAll(Iterable<DomainEvent> events);

  /// Returns the events published since the last drain and clears the buffer.
  /// Used to fold a tick's events into the render snapshot. Buses that don't
  /// buffer return empty.
  List<DomainEvent> drainRecent() => const [];
}
