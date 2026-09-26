// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Turning the population budgets into people (docs/plans/agent-traffic.md
/// §6.2, §6.6; docs/plans/slice3-implementation.md §1.4, §0).
///
/// [PopulationLedger] holds what is owed; this spends it. On each sub-step
/// that holds a whole person, [CitizenPopulation.realise] spawns arrivals,
/// removes emigrants and kills residents, and the world it does that in —
/// where a new citizen's car comes from, where a corpse lands, how a citizen
/// is placed at their home before there are walking trips — is [CitizenWorld],
/// implemented by the agents' facade. The split keeps this file free of the
/// site tables, and lets its tests drive a double.
///
/// Two rules from §0 are load-bearing, and both are about CARS:
///
/// - **Reconciliation never mints a car.** A citizen realised out of the
///   EXTERNAL budget — a load, a revolt, a test writing `population` — is not
///   an arrival: it adopts a free legacy car at its home ([CitizenWorld.adoptCarAt])
///   or owns none. Only a migration arrival draws `carOwnership`. Without
///   this, one `city.advance` over a restored save would invent cars and the
///   committed v2 fixture's `cars.count == saved.rows.length` would break.
/// - **A legacy car is never dropped and never owned twice.** A T4a car whose
///   owner is a BUILDING handle keeps its legacy kind and stands where it is
///   until a carless citizen of that building adopts it; it is re-saved
///   unchanged and offered again at every sync ([legacyCars]).
///
/// Spawns are capped at `max(4, 0.02·liveCount)` a sync (§6.2), so a colony
/// handed ten thousand people at once fills over the syncs after it rather
/// than in one frame; the rest stays in the budget.
///
/// **Why this file knows about parked cars.** [adoptLegacy] and
/// [freeLegacyCarAt] read [ParkedCarTable] directly, which nothing else about
/// the citizens does. The rule they carry — which car is still legacy-owned,
/// and who in that building may take it — is one rule, and it is asked in two
/// places: the sweep after each building sync, and the facade's own
/// `adoptCarAt` when an external arrival looks for a car. Splitting it would
/// let the two drift apart, and a legacy car owned twice is exactly what §0
/// forbids. Nothing here MOVES a car: adoption rewrites two columns
/// (`ParkedCarTable.reown`) and the row keeps its stall, its pool link and
/// its place behind whatever is on the tandem pad with it.
library;

import 'building_table.dart';
import 'citizen_match.dart';
import 'citizen_table.dart';
import 'parked_cars.dart';
import 'population_ledger.dart';
import 'slot_pool.dart';
import 'traffic_rng.dart';
import 'traffic_time.dart';
import 'traffic_tuning.dart';

/// What realisation needs of the world outside the citizen tables: the cars,
/// the placement and the corpses. Implemented by `CityAgents`' core.
abstract interface class CitizenWorld {
  /// A free legacy car standing at building slot [buildingSlot], re-owned by
  /// the citizen asking for it (`ParkedCarTable.reown`), or −1 when the home
  /// has none to give. The car does not move: adoption is a rewrite of two
  /// columns, never a park (§0).
  int adoptCarAt(int buildingSlot);

  /// A car drawn for [citizen] at home [buildingSlot] and parked there
  /// (§6.6): the home's lot if it has room, else a kerb slot within
  /// `homeCarRadiusM`, else garaged. Returns its handle, or −1.
  int mintCarAt(int citizen, int buildingSlot);

  /// [car]'s row leaves the world: its owner emigrated or died.
  void releaseCar(int car);

  /// Puts [citizen] at home [home] with no trip at all — the interim for
  /// §6.2's `movingIn` until slice 8 drives them in from a stub — and counts
  /// it in `stats.instantTrips` (§0 Q6).
  void placeAtHome(int citizen, int home);

  /// [citizen] has left the colony: whatever the facade holds for them goes.
  void leftTown(int citizen);

  /// A death at building slot [buildingSlot]: `BuildingTable.corpses += 1`,
  /// which slice 5's hearses serve (§6.2).
  void corpseAt(int buildingSlot);
}

/// Arrivals, departures and deaths. See the library comment.
class CitizenPopulation {
  CitizenPopulation(
      {required this.citizens,
      required this.buildings,
      required this.ledger,
      required this.match,
      required this.rng});

  final CitizenTable citizens;
  final BuildingTable buildings;
  final PopulationLedger ledger;
  final CitizenMatch match;

  /// Realisation's draws — car ownership, the return window an adopted car's
  /// owner wakes in — on a stream of their own.
  ///
  /// Not final, because a load puts the saved stream back ([restore]): two
  /// colonies resumed from one save must draw the same car for the same
  /// arrival, and a fresh fork of the parent would not (§17.4).
  TrafficRng rng;

  /// Whether the colony's world is sealed, so an arrival's vehicle is a rover
  /// and the ownership share is `carOwnershipSealed` (§6.6). The facade sets
  /// it from the body the colony stands on; a bare table reads breathable.
  bool sealed = false;

  /// What has happened since the colony started: citizens spawned, emigrated
  /// and dead; legacy cars adopted; and legacy cars still standing unowned,
  /// re-offered at every sync (§0 Q3).
  ///
  /// [legacyCars] is the only one that is not cumulative: it is what the LAST
  /// [adoptLegacy] sweep left standing, so a colony whose legacy cars have all
  /// been taken reads 0 and a save written before slice 3 counts down as its
  /// citizens arrive.
  int arrivals = 0, departures = 0, deaths = 0, adopted = 0, legacyCars = 0;

  /// Citizens one call may spawn (§6.2): at least `AgentTuning.arrivalsMin`,
  /// and at most `arrivalsShare` of those already alive. The rest stays owed.
  int get spawnCap {
    final min = AgentTuning.arrivalsMin;
    final share = AgentTuning.arrivalsShare * citizens.liveCount;
    if (!(share > min)) return min > 0 ? min : 0;
    return share.floor();
  }

  /// Spends what the ledger holds, at agent time [nowUs], in [world].
  ///
  /// [external] says which budget this call is allowed to draw an ARRIVAL
  /// from: false for `migrationBudget` (which mints cars), true for the
  /// external budget (which never does). Departures and deaths are the same
  /// either way.
  ///
  /// Each of the three is capped at [spawnCap] of its own, so one call can
  /// neither stop a frame nor empty a town: §6.2 caps the spawns, and the
  /// other two are bounded on the same number because they cost the same
  /// pass over the citizens that a spawn does.
  ///
  /// An arrival the table could not hold is handed BACK to its budget and
  /// offered again next time ([PopulationLedger.giveBack]); a departure or a
  /// death with nobody left to take is dropped, because a town of nobody
  /// cannot pay a debt of people and re-owing it would have the ledger carry
  /// it for ever.
  void realise(int nowUs, CitizenWorld world, {required bool external}) {
    final cap = spawnCap;
    final owed = ledger.takeArrivals(cap, external: external);
    var made = 0;
    while (made < owed && _arrive(nowUs, world, external: external)) {
      made++;
    }
    ledger.giveBack(owed - made, external: external);
    final leaving = ledger.takeDepartures(cap);
    for (var k = 0; k < leaving && _depart(world); k++) {}
    final dying = ledger.takeDeaths(cap);
    for (var k = 0; k < dying && _die(world); k++) {}
  }

  /// Offers every legacy-owned car of [cars] to a carless citizen of the
  /// building its `ownerIdx` names, at agent time [nowUs]. Returns how many
  /// changed hands; [legacyCars] is what is still standing unowned after it.
  ///
  /// This is §0's adoption, and the whole of it. A T4a save's `commuter` and
  /// `homePool` cars keep their meaning for ever — `ownerIdx` is a BUILDING
  /// slot — so a car that comes back out of one is offered, sync after sync,
  /// until somebody who lives there and has no car of their own takes it. A
  /// car nobody takes stands exactly where it is, keeps its legacy kind, and
  /// is written back into the next save unchanged (§0 Q3). A car that IS
  /// taken is re-owned in place, and never offered again, because its kind is
  /// `citizen` from then on: that is what "never owned twice" means.
  ///
  /// Where the car stands decides what its new owner is doing. A car at the
  /// home it belongs to changes nothing — its owner is at home with it. A car
  /// standing anywhere else is a car somebody drove to work and left there,
  /// so its taker is put `atWork` at the site the car is on, with a wake
  /// inside §6.4's return window, and drives it home (§14.3: agents in flight
  /// are never saved, so this is how a commute that was cut by a save is
  /// finished).
  int adoptLegacy(int nowUs, ParkedCarTable cars) {
    var took = 0, standing = 0;
    for (var i = 0; i < cars.pool.highWater; i++) {
      if (!cars.pool.isSlotLive(i)) continue;
      if (!_isLegacy(cars.ownerKind[i])) continue;
      // A car a trip has already taken is on its way off its stall. It is
      // nobody's to hand over this sync; it is still standing, and still
      // legacy, so it is counted and offered again at the next one.
      final taker = cars.claim[i] == ParkedCarTable.unclaimed
          ? _carlessResident(cars.owner[i])
          : SlotPool.none;
      if (taker == SlotPool.none) {
        standing++;
        continue;
      }
      cars.reown(cars.pool.handleOf(i), CarOwnerKind.citizen, taker);
      _takeCar(nowUs, taker, cars.pool.handleOf(i), cars.building[i]);
      adopted++;
      took++;
    }
    legacyCars = standing;
    return took;
  }

  /// A free legacy car whose `ownerIdx` is building slot [buildingSlot], in
  /// car slot order, or [SlotPool.none].
  ///
  /// What the facade's [CitizenWorld.adoptCarAt] answers from: it takes this
  /// car, `reown`s it to the citizen asking, and hands the handle back. The
  /// match is on the car's legacy OWNER and not on where it stands, because
  /// that is what the owner column means in a T4a save — the home a car pools
  /// at, or the home a car left at work came from (§0).
  static int freeLegacyCarAt(ParkedCarTable cars, int buildingSlot) {
    if (buildingSlot < 0) return SlotPool.none;
    for (var i = 0; i < cars.pool.highWater; i++) {
      if (!cars.pool.isSlotLive(i)) continue;
      if (!_isLegacy(cars.ownerKind[i])) continue;
      if (cars.owner[i] != buildingSlot) continue;
      if (cars.claim[i] != ParkedCarTable.unclaimed) continue;
      return cars.pool.handleOf(i);
    }
    return SlotPool.none;
  }

  /// The realisation's own state for the save's `pop` block: its stream, so
  /// two colonies resumed from one save draw the same cars, and its counters,
  /// so the readout does not go back across a load.
  Map<String, Object?> toJson() => {
        'rng': rng.toJson(),
        'arr': arrivals,
        'dep': departures,
        'dead': deaths,
        'adopt': adopted,
        'legacy': legacyCars,
      };

  /// Puts back what [toJson] wrote. Anything else — no block, a block from a
  /// build that had none — leaves the counters at 0 and the stream as it was
  /// forked, which is what a colony that has never realised anybody reads.
  void restore(Object? json) {
    if (json is! Map) return;
    final state = json['rng'];
    if (state != null) rng = TrafficRng.fromJson(state);
    arrivals = _countOf(json['arr']);
    departures = _countOf(json['dep']);
    deaths = _countOf(json['dead']);
    adopted = _countOf(json['adopt']);
    legacyCars = _countOf(json['legacy']);
  }

  /// [hash] with the counters and this stream's state folded in (§17.4).
  int digest(int hash) {
    var h = fnv1aU32(hash, arrivals);
    h = fnv1aU32(h, departures);
    h = fnv1aU32(h, deaths);
    h = fnv1aU32(h, adopted);
    h = fnv1aU32(h, legacyCars);
    final state = rng.toJson();
    for (var i = 0; i < state.length; i++) {
      h = fnv1aU32(h, state[i]);
    }
    return h;
  }

  // ---- Arrival, departure, death ----------------------------------------------

  /// One arrival, or false when the citizen table could not hold it.
  bool _arrive(int nowUs, CitizenWorld world, {required bool external}) {
    final home = match.drawVacantHome();
    // §6.6's draw is made whether or not there is a home to park a car at,
    // and whichever budget the person came out of, so that the stream does
    // not shift with the colony's vacancy or with how a tick was split. What
    // it decides is the LICENCE (§2.5); whether a car follows is §0's rule
    // below.
    final licensed = rng.nextUnit() < _ownership;
    final citizen = _spawn(home, nowUs);
    if (citizen == SlotPool.none) return false;
    final sl = SlotPool.slotOf(citizen);
    if (licensed) citizens.flags[sl] |= CitizenFlags.hasLicence;
    var car = SlotPool.none;
    if (home >= 0) {
      if (external) {
        // §0: reconciliation never mints. A citizen the colony reconciled
        // out of `population` takes a legacy car standing at their home, or
        // owns none at all.
        car = world.adoptCarAt(home);
        if (car >= 0) adopted++;
      } else if (licensed) {
        car = world.mintCarAt(citizen, home);
      }
      world.placeAtHome(citizen, home);
    }
    citizens.car[sl] = car >= 0 ? car : CitizenTable.carNone;
    // §0 Q6: `movingIn` resolves in the same sub-step until slice 8 drives
    // them in from a stub. They are at home, due now, and the activity loop
    // picks them up off the wheel in this very sub-step.
    citizens.state[sl] = CitizenState.atHome.index;
    arrivals++;
    return true;
  }

  /// One emigrant, or false when there is nobody to leave.
  bool _depart(CitizenWorld world) {
    final citizen = match.pickEmigrant();
    if (citizen == SlotPool.none) return false;
    _giveUpCar(citizen, world);
    world.leftTown(citizen);
    citizens.remove(citizen);
    departures++;
    return true;
  }

  /// One death, or false when there is nobody to die.
  bool _die(CitizenWorld world) {
    final citizen = match.pickForDeath();
    if (citizen == SlotPool.none) return false;
    final sl = SlotPool.slotOf(citizen);
    // §6.2: the body lands on the home, and a homeless death on the building
    // they slept nearest (§9.2). Neither: nowhere, and no hearse is owed.
    final home = citizens.home[sl];
    final at = home >= 0 ? home : citizens.sleepsNear[sl];
    if (at >= 0) world.corpseAt(at);
    _giveUpCar(citizen, world);
    citizens.remove(citizen);
    deaths++;
    return true;
  }

  /// [citizen]'s car out of the world: their row is about to go, and a
  /// parked car nobody owns would stand on its stall for ever.
  void _giveUpCar(int citizen, CitizenWorld world) {
    final sl = SlotPool.slotOf(citizen);
    final car = citizens.car[sl];
    if (car >= 0) world.releaseCar(car);
    citizens.car[sl] = CitizenTable.carNone;
  }

  /// A citizen of [home] (−1: homeless), at [nowUs] and due now, or
  /// [SlotPool.none].
  ///
  /// The table never grows by itself (§2.1), so an arrival is where its owner
  /// decides to double it: an arrival is not an inner loop, and §15.2's rule
  /// is about the steady state, which never reaches here. Past 2^20 slots it
  /// answers none and the person stays owed.
  int _spawn(int home, int nowUs) {
    final made = citizens.spawn(
        home: home,
        work: -1,
        car: CitizenTable.carNone,
        state: CitizenState.movingIn,
        wakeUs: nowUs.toDouble());
    if (made != SlotPool.none) return made;
    final want = citizens.capacity * 2;
    if (want > SlotPool.maxSlots) return SlotPool.none;
    citizens.grow(want);
    return citizens.spawn(
        home: home,
        work: -1,
        car: CitizenTable.carNone,
        state: CitizenState.movingIn,
        wakeUs: nowUs.toDouble());
  }

  // ---- Adoption ---------------------------------------------------------------

  /// Whether [ownerKind] is one of the two a T4a save wrote, whose owner is a
  /// BUILDING slot and not a citizen (§0).
  static bool _isLegacy(int ownerKind) =>
      ownerKind == CarOwnerKind.commuter.index ||
      ownerKind == CarOwnerKind.homePool.index;

  /// The first resident of building slot [buildingSlot], in arrival order,
  /// who owns no car; [SlotPool.none] when the building has none to spare.
  ///
  /// Arrival order and not a draw: two colonies that reached the same town by
  /// different roads must hand the same car to the same person, and the
  /// per-building list is the one order both of them agree on (§2.5).
  int _carlessResident(int buildingSlot) {
    if (buildingSlot < 0) return SlotPool.none;
    var c = citizens.firstResident(buildingSlot);
    while (c != SlotPool.none) {
      if (citizens.car[SlotPool.slotOf(c)] == CitizenTable.carNone) return c;
      c = citizens.nextResident(c);
    }
    return SlotPool.none;
  }

  /// [citizen] now owns [car], which stands at building slot [at] (−1 when
  /// it is garaged nowhere in particular). See [adoptLegacy].
  void _takeCar(int nowUs, int citizen, int car, int at) {
    final sl = SlotPool.slotOf(citizen);
    citizens.car[sl] = car;
    citizens.flags[sl] |= CitizenFlags.hasLicence;
    if (at < 0 || at == citizens.home[sl]) return;
    // The car is not at their home, so they are where it is. Give them the
    // job at that site if it has one going and they have none: a citizen
    // `atWork` at a building they do not work at would be laid off the next
    // sync, and drive home from a job they never had.
    if (citizens.work[sl] < 0 &&
        at < buildings.capacity &&
        buildings.jobVacancy(at) > 0) {
      citizens.setWork(citizen, at);
      buildings.workers[at]++;
    }
    citizens.state[sl] = CitizenState.atWork.index;
    citizens.schedule(
        citizen,
        nowUs +
            usOf(rng.nextBetween(AgentTuning.commuteReturnMinS,
                    AgentTuning.commuteReturnMaxS))
                .toDouble());
  }

  // ---- Numbers ----------------------------------------------------------------

  /// The share of arrivals who hold a licence, by the world they arrive on
  /// (§6.6).
  double get _ownership =>
      sealed ? AgentTuning.carOwnershipSealed : AgentTuning.carOwnership;

  /// [json] as a counter: a whole number at least 0, or 0.
  static int _countOf(Object? json) {
    if (json is! num) return 0;
    final v = json.toInt();
    return v > 0 ? v : 0;
  }
}
