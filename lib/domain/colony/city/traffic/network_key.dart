// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// When the lane graph must change, and how much of it (docs/plans/
/// agent-traffic.md §3.8).
///
/// The network's identity is the road agent's `RoadGraph` OBJECT, compared
/// with `identical`: their model rebuilds it on every structural edit and
/// patches it — a copy sharing its arrays — when only junction plans or road
/// names moved. Keying on the object rather than on a counter of our own
/// means the agents can never disagree with the routed model about which
/// network they are on. Two counters of ours ride beside it, for what only
/// the agents know about: outside connections and transit stops.
///
/// No hash of the junction overrides either: an override moves
/// `CitySim.roadsRevision`, and the new graph carries the plans it made.
library;

import '../city_sim.dart';
import '../road_graph.dart';

/// How much of the lane graph a change of network needs redone, least
/// first. A change needs the work of its own rank and of every rank below
/// it.
enum NetChange {
  /// The same network: nothing.
  none,

  /// A transit stop moved (slice 9): re-resolve the stops.
  stops,

  /// Junction plans or road names only: refresh node controls and
  /// connector roles; every lane, connector, id and route stands.
  controls,

  /// An outside connection changed (slice 8): rebuild the sink edges and
  /// remap the routes that used them.
  stubs,

  /// The roads themselves: build a new lane graph and remap every route.
  rebuild,
}

/// The network a lane graph was built for.
class TrafficNetKey {
  const TrafficNetKey(this.graph, {this.stubsRev = 0, this.stopsRev = 0});

  /// The road agent's graph, by identity.
  final RoadGraph graph;

  /// Bumped by our own tools and hooks: outside connections, transit stops.
  final int stubsRev, stopsRev;

  /// What the network moving from [built] (null: no graph yet) to this one
  /// asks of the lane graph.
  NetChange since(TrafficNetKey? built) {
    if (built == null) return NetChange.rebuild;
    final same = identical(graph, built.graph);
    if (!same && !graph.sharesStructureWith(built.graph)) {
      return NetChange.rebuild;
    }
    if (stubsRev != built.stubsRev) return NetChange.stubs;
    if (!same) return NetChange.controls;
    if (stopsRev != built.stopsRev) return NetChange.stops;
    return NetChange.none;
  }
}

/// What the watch reads a network from: the two counters every road edit
/// moves, and the graph, which is costly to ask for — reading it syncs the
/// routed model.
abstract interface class TrafficNetSource {
  /// `CitySim.roadsRevision`: every road edit and every junction override.
  int get roadsRevision;

  /// `CityLayout.version`: every re-cut of the plat.
  int get layoutVersion;

  /// `CitySim.roadGraph`.
  RoadGraph get roadGraph;
}

/// A colony as a [TrafficNetSource].
class CityNetSource implements TrafficNetSource {
  const CityNetSource(this.city);

  final CitySim city;

  @override
  int get roadsRevision => city.roadsRevision;

  @override
  int get layoutVersion => city.layout.version;

  @override
  RoadGraph get roadGraph => city.roadGraph;
}

/// Reads the network's graph only when it can have moved.
///
/// Every advance asks; almost every advance, two integer compares answer.
/// The graph is fetched only when `roadsRevision` or the layout version has
/// moved since the last fetch — by which time the routed model has synced it
/// that tick, so the fetch is a lookup, not a build.
class TrafficNetWatch {
  int _roadsRevision = -1, _layoutVersion = -1;
  RoadGraph? _graph;
  int _fetches = 0;

  /// How many times [poll] has read the graph (for the tests that pin how
  /// rarely that is).
  int get fetches => _fetches;

  /// The graph [source] stands on now.
  RoadGraph poll(TrafficNetSource source) {
    final rev = source.roadsRevision, ver = source.layoutVersion;
    final g = _graph;
    if (g != null && rev == _roadsRevision && ver == _layoutVersion) return g;
    _roadsRevision = rev;
    _layoutVersion = ver;
    _fetches++;
    return _graph = source.roadGraph;
  }

  /// Forget what was seen: the next [poll] fetches.
  void reset() {
    _roadsRevision = _layoutVersion = -1;
    _graph = null;
  }
}
