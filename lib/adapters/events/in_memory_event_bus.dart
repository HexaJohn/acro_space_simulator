import '../../application/ports/event_bus.dart';
import '../../domain/simulation/domain_event.dart';

/// Simple synchronous event bus adapter. Fans events out to registered
/// listeners (UI HUD, logging, networking). A real build might back this with a
/// stream; the port stays the same.
class InMemoryEventBus implements EventBus {
  final List<void Function(DomainEvent)> _listeners = [];

  /// Recent events kept for the UI to read each frame (cleared by the reader).
  final List<DomainEvent> recent = [];

  void subscribe(void Function(DomainEvent) listener) =>
      _listeners.add(listener);

  /// Detach a previously [subscribe]d listener. Important now the bus is owned at
  /// app scope (see SimEngine) and outlives any one UI screen: a screen MUST
  /// unsubscribe on dispose or its callback leaks and fires after teardown.
  void unsubscribe(void Function(DomainEvent) listener) =>
      _listeners.remove(listener);

  @override
  void publish(DomainEvent event) {
    recent.add(event);
    for (final l in _listeners) {
      l(event);
    }
  }

  @override
  void publishAll(Iterable<DomainEvent> events) {
    for (final e in events) {
      publish(e);
    }
  }

  void clearRecent() => recent.clear();

  @override
  List<DomainEvent> drainRecent() {
    final out = List<DomainEvent>.of(recent);
    recent.clear();
    return out;
  }
}
