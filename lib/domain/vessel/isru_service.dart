import 'converter.dart';
import 'resource_container.dart';
import 'vessel.dart';

/// Runs a vessel's in-situ resource converters each tick — the colony-ship ISRU
/// loop (mine ore, convert to fuel/water/oxygen on the spot). Domain service.
///
/// A converter only runs if ALL its inputs are available for the full step and
/// there is room for ALL its outputs; otherwise it idles (no partial waste).
/// This keeps resource accounting clean and avoids consuming inputs that would
/// be lost to a full output tank.
class IsruService {
  const IsruService();

  void advance(Vessel vessel, {required double dt}) {
    for (final c in vessel.converters) {
      _runConverter(vessel, c, dt);
    }
  }

  void _runConverter(Vessel vessel, Converter c, double dt) {
    final scale = c.throttle.clamp(0.0, 1.0) * dt;
    if (scale <= 0) return;

    // Check every input is fully available.
    for (final entry in c.inputsPerSecond.entries) {
      final need = entry.value * scale;
      if (_available(vessel, entry.key) < need - 1e-9) return;
    }
    // Check every output has room.
    for (final entry in c.outputsPerSecond.entries) {
      final produce = entry.value * scale;
      if (_room(vessel, entry.key) < produce - 1e-9) return;
    }

    // Consume inputs, produce outputs.
    c.inputsPerSecond.forEach((type, rate) => _draw(vessel, type, rate * scale));
    c.outputsPerSecond.forEach((type, rate) => _fill(vessel, type, rate * scale));
  }

  double _available(Vessel v, ResourceType t) {
    var sum = 0.0;
    for (final p in v.allParts) {
      for (final r in p.resources) {
        if (r.type == t) sum += r.amount;
      }
    }
    return sum;
  }

  double _room(Vessel v, ResourceType t) {
    var room = 0.0;
    for (final p in v.allParts) {
      for (final r in p.resources) {
        if (r.type == t) room += r.capacity - r.amount;
      }
    }
    return room;
  }

  void _draw(Vessel v, ResourceType t, double amount) {
    var remaining = amount;
    for (final p in v.allParts) {
      if (remaining <= 0) break;
      for (final r in p.resources) {
        if (r.type != t) continue;
        remaining -= r.draw(remaining);
        if (remaining <= 0) break;
      }
    }
  }

  void _fill(Vessel v, ResourceType t, double amount) {
    var remaining = amount;
    for (final p in v.allParts) {
      if (remaining <= 0) break;
      for (final r in p.resources) {
        if (r.type != t) continue;
        remaining = r.fill(remaining);
        if (remaining <= 0) break;
      }
    }
  }
}
