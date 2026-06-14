import '../shared/vector3.dart';
import '../universe/celestial_body.dart';
import '../vessel/vessel.dart';
import 'comms_service.dart';

/// Computes which vessels have a control link, allowing relays: a vessel that
/// can't see the ground station directly is still connected if it can reach
/// (through clear inter-vessel line-of-sight) any vessel that is connected.
/// Domain service — graph reachability over the LOS graph.
///
/// Model (single body): the ground station sits on the body's +X surface; the
/// body itself is the only occluder. Connectivity floods out from every vessel
/// with a direct station link through vessel-to-vessel sightlines.
class RelayNetwork {
  final CommsService comms;
  const RelayNetwork([this.comms = const CommsService()]);

  /// Returns a map of vessel id -> has-link. Vessels must share the same
  /// [body]-centred frame.
  Map<String, bool> computeLinks(
    List<Vessel> vessels,
    CelestialBody body, {
    List<Vector3>? stations,
  }) {
    // Default: a single ground station on the body's +X surface.
    final groundStations = stations ?? [Vector3(body.radius, 0, 0)];
    final occluderRadius = body.radius * 0.999;

    bool sees(Vector3 a, Vector3 b) => comms.hasLineOfSight(
          a,
          b,
          occluderCentre: Vector3.zero,
          occluderRadius: occluderRadius,
        );

    bool seesAnyStation(Vector3 p) =>
        groundStations.any((s) => sees(p, s));

    // Sources: vessels with a direct line to ANY ground station.
    final connected = <String>{};
    final frontier = <Vessel>[];
    for (final v in vessels) {
      if (seesAnyStation(v.state.position)) {
        connected.add(v.id.value);
        frontier.add(v);
      }
    }

    // Flood through inter-vessel sightlines.
    while (frontier.isNotEmpty) {
      final v = frontier.removeLast();
      for (final other in vessels) {
        if (connected.contains(other.id.value)) continue;
        if (sees(v.state.position, other.state.position)) {
          connected.add(other.id.value);
          frontier.add(other);
        }
      }
    }

    return {for (final v in vessels) v.id.value: connected.contains(v.id.value)};
  }
}
