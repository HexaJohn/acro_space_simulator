import '../../domain/flight/flight_world.dart';
import '../../domain/shared/vector3.dart';

/// The seam a flight screen (ascent / descent / live sim) reads SHARED traffic
/// from. It publishes the local player's own craft each frame and reads back
/// every OTHER craft in the same airspace — remote players + automated supply
/// ships — plus collision detection.
///
/// A [LocalFlightTraffic] backs this with an in-process [FlightWorld] today; a
/// future network provider implements the same interface over a transport (the
/// existing NetworkChannel / WorldSnapshot), so the screens don't change.
abstract class FlightTraffic {
  /// Publish (insert/update) the local player's craft into the shared world.
  void publishLocal(FlightCraft me);

  /// Advance the shared world (everything except the local craft, which the
  /// screen integrates itself) by [dt].
  void step(double dt, {required String localId});

  /// Every other craft sharing [bodyId]'s airspace (excludes [exceptId]).
  Iterable<FlightCraft> trafficNear(String bodyId, {String? exceptId});

  /// Ids of craft [me] has collided with this frame.
  List<String> collisions(FlightCraft me);

  void dispose();
}

/// In-process traffic provider. Owns a [FlightWorld], seeds some demo supply +
/// remote-player traffic so the feature is usable standalone, and (when a real
/// transport exists) ingests remote snapshots via [ingestRemote].
class LocalFlightTraffic implements FlightTraffic {
  final FlightWorld world;

  LocalFlightTraffic({
    required double Function(String) gravityMu,
    required double Function(String) bodyRadius,
  }) : world = FlightWorld(gravityMu: gravityMu, bodyRadius: bodyRadius);

  @override
  void publishLocal(FlightCraft me) => world.upsert(me);

  @override
  void step(double dt, {required String localId}) =>
      world.advance(dt, skipIds: {localId});

  @override
  Iterable<FlightCraft> trafficNear(String bodyId, {String? exceptId}) =>
      world.trafficNear(bodyId, exceptId: exceptId);

  @override
  List<String> collisions(FlightCraft me) => world.collisionsWith(me);

  /// Bridge for a real transport: feed the authoritative server's vessel rows in
  /// as remote-player traffic.
  void ingestRemote(
    Iterable<({
      String id,
      String ownerId,
      String body,
      Vector3 pos,
      Vector3 vel,
    })> rows, {
    required String localOwnerId,
  }) =>
      world.ingestRemote(rows, localOwnerId: localOwnerId);

  /// Add a supply / relief ship to the airspace (the colony dispatches these).
  void addSupply(FlightCraft supply) => world.upsert(supply);

  @override
  void dispose() => world.clear();
}
