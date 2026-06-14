import '../../domain/simulation/domain_event.dart';

/// Port for publishing domain events out of the simulation to interested
/// listeners (UI, achievements, networking). Adapters provide the transport.
abstract class EventBus {
  void publish(DomainEvent event);
  void publishAll(Iterable<DomainEvent> events);
}
