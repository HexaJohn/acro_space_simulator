// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What moves, why, and under what control: the agent simulation's enums.
///
/// Every one is APPEND-ONLY. Their indices are what the typed columns hold (a
/// vehicle's kind is one byte), what the frame hands the renderer, and — for
/// [CitizenState] and [ServiceKind] — what a save writes
/// (docs/plans/agent-traffic.md §14.4). A member inserted anywhere but the
/// end silently turns every stored value into its neighbour, so new members
/// go last, and agent_kind_test pins each order.
library;

import '../traffic_readout.dart';

/// What a vehicle is.
///
/// Declared whole in slice 1, though most kinds first move in later slices,
/// so the byte a kind is stored as never changes under a save or a frame.
/// The domain names the kind and the renderer maps it to a mesh (D42): the
/// domain may not import the renderer's `VehicleKind`.
enum AgentKind {
  /// A resident's or a visitor's car.
  car,

  /// A box lorry: local deliveries and freight.
  truck,

  /// An articulated lorry: imports, exports and through freight.
  semi,

  /// A line's bus (slice 9).
  bus,

  // The service fleets (slices 5–7).
  garbageTruck,
  hearse,
  policeCar,
  ambulance,
  fireEngine,
  mailVan,
  deliveryVan,

  // Rail (slice 9b): these run on the rail graph, never in a road lane.
  train,
  lTrain,
  freightTrain,
}

/// Where a citizen is in their day (§2.5). Saved by index.
enum CitizenState {
  atHome,
  travelling,
  atWork,
  atErrand,
  outOfTown,
  movingIn,
  leaving,
  riding,
}

/// A service delivered per building by a vehicle that has to arrive (§9),
/// and the flag, `agents.serves(kind)`, that hands each one from the old
/// global code to the agents. Saved by index, as the save's `serves` list.
///
/// The first six are the services proper, in the order of the design's
/// service table. [transit] is the ridership flag (slice 9) and [goods] the
/// freight request (slice 8): both ride the same per-building request and
/// flag machinery, so they take an index here too.
enum ServiceKind {
  garbage,
  deathcare,
  police,
  mail,
  health,
  fire,
  transit,
  goods,
}

/// Why a trip is being made: fixed at spawn, and carried for the inspector
/// and the Traffic Routes view.
enum TripPurpose {
  /// Home to work.
  commute,

  /// Back home: from work, an errand, or out of town.
  homeward,

  /// To a shop, a park or a civic building (slice 3).
  errand,

  /// A resident's errand beyond the map, to an outside connection (slice 8).
  outOfTown,

  /// A visitor from beyond the map, in to a building or back out (slice 8).
  visit,

  /// From one outside connection to another, never stopping (slice 8).
  through,

  /// An immigrant on the way to a new home (slice 3).
  moveIn,

  /// An emigrant leaving the colony (slice 3).
  moveOut,

  /// Goods: an import, an export or a delivery (slice 8).
  freight,

  /// A service vehicle's run, or its return to its depot (slices 5–7).
  service,

  /// A bus or a train to or from its depot (slices 9, 9b).
  transit;

  /// The Traffic Routes view's coarser kind (traffic_readout.dart). A
  /// resident travelling to or from home — for work, or into and out of the
  /// colony — is a commuter; every other passenger trip reads as a shopper;
  /// freight is goods; service and transit runs are service.
  TripKind get tripKind => switch (this) {
        TripPurpose.commute ||
        TripPurpose.homeward ||
        TripPurpose.moveIn ||
        TripPurpose.moveOut =>
          TripKind.commuter,
        TripPurpose.errand ||
        TripPurpose.outOfTown ||
        TripPurpose.visit ||
        TripPurpose.through =>
          TripKind.shopper,
        TripPurpose.freight => TripKind.goods,
        TripPurpose.service || TripPurpose.transit => TripKind.service,
      };
}

/// How a trip travels (§4.9). Walking is always available, so every trip has
/// a mode.
enum TravelMode { walk, car, bus, rail }

/// How a node controls the traffic entering it (§3.2).
///
/// Mapped from the road network's own junction plan (`RoadNode.plan`), read
/// once per graph and never re-decided, so the lights the tiles draw are the
/// lights the agents wait at.
enum NodeControlKind {
  /// One leg, on the ground: traffic turns round here.
  deadEnd,

  /// A dead end where an outside connection leaves the map (slice 8).
  stub,

  /// One leg in the air or below ground: a deck that stops short of
  /// anything, drawn in the traffic view as a network error.
  danglingDeck,

  /// Two legs running on — a class change, a taper's seam, a ring's own join
  /// — where lanes may drop or add but nothing yields.
  continuation,

  /// A ramp joining a mainline: the ramp yields.
  rampMerge,

  /// Every inbound leg stops, and vehicles go in arrival order.
  allWayStop,

  /// Some legs stop, and yield to the rest.
  stop,

  signals,

  /// Every entry yields to the traffic already on the junction.
  roundabout,

  /// Three or more legs the warrant left without a plan. Never expected with
  /// the network's legs, but defined: rank first, then the right-hand rule.
  uncontrolled,
}
