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
