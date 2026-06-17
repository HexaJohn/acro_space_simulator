import '../shared/vector3.dart';

/// What kind of craft a [FlightCraft] is — drives how it's drawn + treated.
enum FlightCraftKind {
  /// The LOCAL player's own craft (not collided against itself).
  localPlayer,

  /// Another player's craft, sharing the same body's airspace.
  remotePlayer,

  /// An automated supply / relief ship inbound to or outbound from a colony.
  supply,
}

/// A single craft in the shared flight world, in a body-centred frame (metres,
/// metres/second). Pure value object — no rendering, no IO. [ownerId] identifies
/// the controlling player (for remote players / supply dispatchers).
class FlightCraft {
  final String id;
  final FlightCraftKind kind;
  final String? ownerId;
  final String bodyId; // which celestial body's airspace it occupies
  final Vector3 position; // body-centred (m)
  final Vector3 velocity; // body-centred (m/s)

  /// Collision radius (m) — craft within this sum of radii have collided.
  final double radius;

  /// A short display label (callsign / cargo).
  final String label;

  const FlightCraft({
    required this.id,
    required this.kind,
    required this.bodyId,
    required this.position,
    required this.velocity,
    this.ownerId,
    this.radius = 12.0,
    this.label = '',
  });

  FlightCraft copyWith({Vector3? position, Vector3? velocity}) => FlightCraft(
        id: id,
        kind: kind,
        ownerId: ownerId,
        bodyId: bodyId,
        position: position ?? this.position,
        velocity: velocity ?? this.velocity,
        radius: radius,
        label: label,
      );
}

/// The SHARED flight simulator state: every craft currently aloft in the
/// universe, keyed by id. This is the single source of truth the flight screens
/// (ascent, descent, the live sim) read other traffic from and publish their own
/// craft into.
///
/// It is deliberately transport-agnostic. A LOCAL provider mutates it directly;
/// a future NETWORK provider applies the same upserts/removes from remote
/// players + a server. Determinism comes from a fixed step ([advance]).
///
/// Bodies are identified by id; per-body gravity is supplied by [gravityFor] so
/// the domain stays decoupled from the universe catalogue.
class FlightWorld {
  final Map<String, FlightCraft> _craft = {};

  /// μ (m^3/s^2) per body id — gravitational parameter for ballistic coasting.
  final double Function(String bodyId) gravityMu;

  /// Surface radius (m) per body id — used for ground-impact culling of supply.
  final double Function(String bodyId) bodyRadius;

  FlightWorld({required this.gravityMu, required this.bodyRadius});

  Iterable<FlightCraft> get craft => _craft.values;

  FlightCraft? operator [](String id) => _craft[id];

  /// Insert or update a craft (the local player publishes its own state here
  /// each frame; the network provider applies remote updates the same way).
  void upsert(FlightCraft c) => _craft[c.id] = c;

  void remove(String id) => _craft.remove(id);

  /// Every OTHER craft sharing [bodyId]'s airspace (excludes [exceptId], usually
  /// the caller's own craft).
  Iterable<FlightCraft> trafficNear(String bodyId, {String? exceptId}) =>
      _craft.values
          .where((c) => c.bodyId == bodyId && c.id != exceptId);

  /// Advance every craft NOT in [skipIds] ballistically (gravity only) by [dt].
  /// The local player's craft is integrated by its own screen with full
  /// thrust/drag physics and republished via [upsert], so it's skipped here.
  /// Supply craft that fall below the surface are removed (they've landed).
  void advance(double dt, {Set<String> skipIds = const {}}) {
    final landed = <String>[];
    _craft.updateAll((id, c) {
      if (skipIds.contains(id)) return c;
      final mu = gravityMu(c.bodyId);
      final r = c.position.length;
      if (r < 1) return c;
      final g = c.position.normalized * (-mu / (r * r));
      final v = c.velocity + g * dt;
      final p = c.position + v * dt;
      if (c.kind == FlightCraftKind.supply &&
          p.length <= bodyRadius(c.bodyId)) {
        landed.add(id);
      }
      return c.copyWith(position: p, velocity: v);
    });
    for (final id in landed) {
      _craft.remove(id);
    }
  }

  /// Ids of craft that have COLLIDED with [me] (centres within the sum of radii),
  /// among those sharing the same body. Used by a flying screen to end the run.
  List<String> collisionsWith(FlightCraft me) {
    final hits = <String>[];
    for (final c in _craft.values) {
      if (c.id == me.id || c.bodyId != me.bodyId) continue;
      final d = (c.position - me.position).length;
      if (d <= c.radius + me.radius) hits.add(c.id);
    }
    return hits;
  }

  /// Distance (m) from [me] to the NEAREST other craft on the same body, or
  /// infinity if alone — for a proximity warning.
  double nearestDistance(FlightCraft me) {
    var best = double.infinity;
    for (final c in _craft.values) {
      if (c.id == me.id || c.bodyId != me.bodyId) continue;
      final d = (c.position - me.position).length;
      if (d < best) best = d;
    }
    return best;
  }

  void clear() => _craft.clear();

  /// Replace all REMOTE-player craft with those described by network-snapshot
  /// rows (id, ownerId, body, pos, vel). [localOwnerId] marks which owner is us
  /// (skipped — our own craft is published separately). Supply craft are managed
  /// locally and untouched here. This is the bridge a real transport drives: the
  /// authoritative server's WorldSnapshot vessels flow in as remote traffic.
  void ingestRemote(
    Iterable<({
      String id,
      String ownerId,
      String body,
      Vector3 pos,
      Vector3 vel,
    })> rows, {
    required String localOwnerId,
  }) {
    // Drop stale remote-player craft, then re-add from the snapshot.
    _craft.removeWhere((_, c) => c.kind == FlightCraftKind.remotePlayer);
    for (final r in rows) {
      if (r.ownerId == localOwnerId) continue; // that's us
      _craft[r.id] = FlightCraft(
        id: r.id,
        kind: FlightCraftKind.remotePlayer,
        ownerId: r.ownerId,
        bodyId: r.body,
        position: r.pos,
        velocity: r.vel,
        label: r.ownerId,
      );
    }
  }

  /// A deterministic stand-in [gravityMu]/[bodyRadius] is not provided here on
  /// purpose — callers wire it from the real universe catalogue. This keeps the
  /// domain free of the body data, matching the rest of the layering.
  static double earthMu() => 3.986004418e14;
  static double earthRadius() => 6.371e6;
}
