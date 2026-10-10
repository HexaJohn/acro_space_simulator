// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The first five minutes of a city, laid out for the player.
///
/// A colony founded bare cannot grow at all: population needs a road-connected
/// SPACEPORT before anyone immigrates (see [CitySim.hasSpaceport]), and a
/// spaceport needs a road, and a road needs somewhere to start. Handing the
/// player an empty planet and those three interlocking prerequisites is not a
/// blank canvas, it is a puzzle with one solution. So the mode starts the way a
/// city-builder starts: a connection to the outside world, a crossroads, a
/// treasury, and everything else left to draw.
///
/// Off Earth the connection is also the lifeline. A kit founded on the Moon
/// with its farm, its pump and no air opened on a crew that could never land:
/// oxygen is managed there, nothing in the kit makes it, and a colony that
/// cannot supply a single breath supports nobody. So an off-world colony lives
/// on the player's supply chain from its first day — the kit stocks what the
/// world withholds and books the freight that keeps the town it was built for
/// breathing ([CityStarterKit.shortfall]); outgrowing that freight, or losing
/// the port it lands at, is the player's problem, which is the point.
///
/// Domain, not screen: the setup UI picks a world and a difficulty, and this
/// turns that into a live colony. A test — or a headless driver — can found the
/// same starting position with no widgets in the process.
library;

import 'dart:math' as math;

import 'city_building_spec.dart';
import 'city_config.dart';
import 'city_sim.dart';
import 'commodity.dart';
import 'parcel.dart';
import 'site_access/site_access_book.dart';
import '../../universe/celestial_body.dart';

/// How much rope the colony is given, as one pick on the setup screen.
///
/// Bundles the treasury and the difficulty knobs together because they are the
/// same decision: a harsh world with a fat treasury is not harder, it is just
/// slower to fail.
enum CityStart {
  relaxed(
    label: 'Relaxed',
    blurb: 'Deep pockets, calm skies. For judging the building, not the odds.',
    funds: 40000,
    ore: 650,
    supplies: 600,
    hostility: 0.12,
    forgiveness: 1.0,
    bounty: 1.0,
  ),
  standard(
    label: 'Standard',
    blurb: 'A working budget and weather that bites occasionally.',
    funds: 18000,
    ore: 480,
    supplies: 320,
    hostility: 0.4,
    forgiveness: 0.7,
    bounty: 0.7,
  ),
  harsh(
    label: 'Harsh',
    blurb: 'Thin margins, hostile ground. Every road has to earn itself.',
    funds: 7000,
    ore: 240,
    supplies: 180,
    hostility: 0.75,
    forgiveness: 0.35,
    bounty: 0.45,
  );

  const CityStart({
    required this.label,
    required this.blurb,
    required this.funds,
    required this.ore,
    required this.supplies,
    required this.hostility,
    required this.forgiveness,
    required this.bounty,
  });

  final String label;
  final String blurb;

  /// Opening treasury (§) — land purchases and the milestone economy.
  final double funds;

  /// Opening materials. Ore is what construction actually costs, so this is
  /// the number that decides how much can be standing before the first mine.
  ///
  /// Bounded by STORAGE, not by generosity: the stockpile caps at 200 plus
  /// whatever depots are standing, and the tick sweeps the overflow away
  /// within a frame. The kit's warehouse is what makes these figures land at
  /// all — see [CityStarterKit.found].
  final double ore;

  /// Opening food + water, in stock units each — and oxygen, on a world whose
  /// sky gives none ([CityStarterKit.shortfall]). Life support runway.
  final double supplies;

  final double hostility;
  final double forgiveness;
  final double bounty;

  /// This difficulty's knobs written over [base]. The site (world, biome,
  /// lat/lon) is the player's; the odds are the difficulty's.
  CityConfig configure(CityConfig base) => CityConfig(
        gridSize: base.gridSize,
        bodyId: base.bodyId,
        biome: base.biome,
        govtIndex: base.govtIndex,
        economyIndex: base.economyIndex,
        colonyModeIndex: base.colonyModeIndex,
        latitude: base.latitude,
        longitude: base.longitude,
        complexity: base.complexity,
        hostility: hostility,
        forgiveness: forgiveness,
        bounty: bounty,
      );
}

/// Founds a colony that is ready to be played rather than merely to exist.
class CityStarterKit {
  const CityStarterKit._();

  /// Half-length of each starter street, in metres. 300 m each way puts the
  /// crossroads a comfortable two blocks across — enough frontage to zone a
  /// first neighbourhood without drawing a road, not so much that the opening
  /// view is mostly empty tarmac.
  static const double streetHalfLengthM = 300;

  /// The starter pad is the base catalogue spaceport, and that spec states a
  /// 900 m site. The lot is cut to match so the pad and its parcel agree —
  /// a 900 m apron staked on a 30 m street lot would render straight through
  /// the road it fronts.
  static const double padSizeM = 900;

  /// The starter solar farm states a 780 m site; its lot matches, as the pad's
  /// does.
  static const double solarSizeM = 780;

  /// The starter farm's site, per its catalogue spec.
  static const double farmSizeM = 400;

  /// The aquifer pump's site, per its catalogue spec.
  static const double pumpWidthM = 260;
  static const double pumpDepthM = 180;

  /// Clearance from the crossroads to the pad's near corner. Inside the 90 m a
  /// manual lot is served from (see `ParcelNetwork`), so the port is connected
  /// the moment it is placed — the first thing the player would otherwise have
  /// to debug is why nobody is arriving.
  static const double padOffsetM = 60;

  /// How far past the design town's need the kit's air run flies
  /// ([shortfall]). A quarter over: a freighter turned away by a busy pad, or
  /// a day the town ran a little large, should not open on a suffocation.
  ///
  /// The air's alone. A margin is only one while the town does not grow into
  /// it, and it grows to whatever it is supplied with: shipped a quarter over
  /// on all three, Titan's town settled a fifth past its size, its larder
  /// empty part of every day and its air run with nothing to spare. Food and
  /// water fly at the design need, so the larder sets the town's size as the
  /// farm and the pump do on the Moon, and the air's quarter stays spare.
  static const double supplyHeadroom = 1.25;

  /// The kit's standing orders fly once a colony day — the reference day the
  /// loyalty calendar counts in — and that is also the longest interval the
  /// delivery editor offers, so the player can open one and save it unchanged.
  /// Three runs a day still leave the kit's one pad free between them
  /// ([CitySim.craftTotalSec] each).
  static const double supplyIntervalSec = 120;

  /// A shortfall under this, per second, is not booked: a third of one
  /// settler's oxygen, so nothing worth a freighter.
  static const double minShortfallPerSec = 0.01;

  /// Found a colony with a crossroads, a working spaceport and a treasury.
  ///
  /// [config] carries the site the player chose; [start] carries the odds and
  /// the opening balance. [agentTraffic] founds it with real vehicles on its
  /// roads (docs/plans/agent-traffic.md, D24): the play surface asks for
  /// them, and every other caller keeps the colony as it always was.
  static CitySim found({
    required List<CelestialBody> bodies,
    CityConfig config = const CityConfig(),
    CityStart start = CityStart.standard,
    String id = 'colony-1',
    String name = 'Colony',
    bool agentTraffic = false,
  }) {
    final sim = CitySim.found(
      start.configure(config),
      bodies: bodies,
      id: id,
      name: name,
    );

    // The crossroads. Both streets run through the colony origin, which is
    // where the road network is rooted — so everything laid off them is
    // connected without the player having to discover the rule.
    //
    // Committed (not `layout.addRoad`) so the two split at their crossing and
    // the junction exists in the graph, exactly as a player-drawn pair would.
    // No ground probe: at founding there is no terrain service to hand it, and
    // the mode's free-build default ignores grade anyway.
    sim.commitRoad(
      const [Vec2(0, -streetHalfLengthM), Vec2(0, streetHalfLengthM)],
      RoadClass.street,
    );
    sim.commitRoad(
      const [Vec2(-streetHalfLengthM, 0), Vec2(streetHalfLengthM, 0)],
      RoadClass.street,
    );

    // The spaceport, on a lot cut to its own size in the north-east quadrant.
    // A manual parcel rather than a street lot: the apron is thirty times the
    // depth of anything the plat cuts off a street.
    const lo = padOffsetM;
    const hi = padOffsetM + padSizeM;
    final pad = sim.layout.addManualParcel(
      const [Vec2(lo, lo), Vec2(hi, lo), Vec2(hi, hi), Vec2(lo, hi)],
      // Fronts WEST, onto the north–south street it stands beside.
      frontage: (const Vec2(lo, lo), const Vec2(lo, hi)),
    );
    if (pad != null) {
      sim.placeOnParcel(pad.id, _spaceport);
      sim.everHadSpaceport = true;
    }

    // A solar farm, on its own field south-east of the crossroads. The port
    // draws 40 kW and a colony with no generation is a colony where nothing
    // runs — an opening position that reads as broken rather than as a
    // challenge. Sized to its own spec (780 m) for the same reason as the pad.
    const fLo = padOffsetM;
    const fHi = padOffsetM + solarSizeM;
    final field = sim.layout.addManualParcel(
      const [Vec2(fLo, -fHi), Vec2(fHi, -fHi), Vec2(fHi, -fLo), Vec2(fLo, -fLo)],
      frontage: (const Vec2(fLo, -fHi), const Vec2(fLo, -fLo)),
    );
    if (field != null) sim.placeOnParcel(field.id, _solar);

    // A farm and a pump, south-west and north-west. Not generosity: a colony
    // eats from its first second, and with no water there is no food, so a kit
    // without them opens on a population that is already dying — a losing
    // position dressed as a starting one. These are the lander's greenhouse
    // and bore, the things a founding expedition brings with it.
    const wLo = padOffsetM;
    final farm = sim.layout.addManualParcel(
      const [
        Vec2(-(wLo + farmSizeM), -(wLo + farmSizeM)),
        Vec2(-wLo, -(wLo + farmSizeM)),
        Vec2(-wLo, -wLo),
        Vec2(-(wLo + farmSizeM), -wLo),
      ],
      frontage: (const Vec2(-wLo, -(wLo + farmSizeM)), const Vec2(-wLo, -wLo)),
    );
    if (farm != null) sim.placeOnParcel(farm.id, _farm);

    final pump = sim.layout.addManualParcel(
      const [
        Vec2(-(wLo + pumpWidthM), wLo),
        Vec2(-wLo, wLo),
        Vec2(-wLo, wLo + pumpDepthM),
        Vec2(-(wLo + pumpWidthM), wLo + pumpDepthM),
      ],
      frontage: (const Vec2(-wLo, wLo), const Vec2(-wLo, wLo + pumpDepthM)),
    );
    if (pump != null) sim.placeOnParcel(pump.id, _pump);

    // A warehouse on the first street lot. Ore is capped at 200 without one,
    // which is under two buildings' worth — the opening budget would evaporate
    // on the first tick's cap sweep and the player would never see it.
    final depot = sim.layout.autoParcels.isEmpty
        ? null
        : sim.layout.autoParcels.first;
    if (depot != null) sim.placeOnParcel(depot.id, _warehouse);

    // Opening balance. Set rather than added: the difficulty IS the starting
    // position, and a colony's default stock is a founding gift from the same
    // budget.
    sim.funds = start.funds;
    sim.stock[Commodity.ore] = start.ore;
    sim.stock[Commodity.food] = start.supplies;
    sim.stock[Commodity.water] = start.supplies;

    // What the world will not give, the player's supply chain does, from the
    // first day: an opening stock and a standing order at the port for each
    // shortfall ([shortfall]). Nothing at all on Earth, which breathes, eats
    // and drinks off its own ground.
    if (pad != null) _bookSupply(sim, start, pad.id);

    // The agents build nothing until the colony first advances.
    if (agentTraffic) sim.agents.enabled = true;

    // Milestone tier 0 is the founding state. Recorded up front so the ladder
    // starts where the colony does and the first banner the player sees is a
    // tier they actually climbed.
    sim.claimMilestones();

    // Every site's access plan, drained in full (docs/plans/site-access.md
    // §4.1, §3.7a rule 3): the starter easements exist before the player can
    // zone a lot.
    sim.siteAccess.sync(sim, sim.roadGraph,
        maxUnits: SiteAccessBook.unlimited, maxChecks: SiteAccessBook.unlimited);
    return sim;
  }

  /// The town the kit is built for at [sim]'s site: as many people as its farm
  /// and pump feed running flat out — on this ground and at these odds (the
  /// biome's yield, the difficulty's bounty) — and never fewer than the
  /// lander's crew. Growing past it is the player's to provide for: more
  /// farms, more pumps, and off-world more freight.
  static double designPopulation(CitySim sim) {
    final full = _kitLifeNet(sim, 1.0);
    final fed = (full[Commodity.food] ?? 0) / CitySim.foodPerPersonPerSec;
    final watered =
        (full[Commodity.water] ?? 0) / CitySim.waterPerPersonPerSec;
    return math.max(CitySim.landerCrew.toDouble(), math.min(fed, watered));
  }

  /// What the kit's own buildings cannot make at [sim]'s site for its
  /// [designPopulation], per second, by commodity, the air with
  /// [supplyHeadroom] — the standing orders [found] books. Empty where the
  /// world provides (Earth): the rule asks what the WORLD withholds, never
  /// whether the odds are kind, so a harsh desert town on Earth is still the
  /// player's to water with pumps, as it always was.
  ///
  /// - **Oxygen**, wherever life support manages it (off a breathable world,
  ///   at COMPLEXITY 0.3 up — [CitySim.o2NeedPerSec]): the kit brings no
  ///   plant, so all of the town's that the sky does not give
  ///   ([CitySim.airO2]).
  /// - **Food and water**, where the sun is too weak to run the farm and the
  ///   pump: the solar farm is the kit's only generator, and life support
  ///   draws first, so what it cannot power — Titan's, Europa's, Ceres's
  ///   twilight — is what is lost. Nothing on the Moon, Mars or Venus, whose
  ///   panels run both in full; the biome and the aquifer are no gate, since
  ///   the pump and the farm are sealed plants that run on any ground.
  static Map<String, double> shortfall(CitySim sim) {
    final pop = designPopulation(sim);
    final full = _kitLifeNet(sim, 1.0);
    final here = _kitLifeNet(sim, _kitLifePower(sim));
    final gaps = <String, double>{};
    void gap(String c, double perSec, [double headroom = 1]) {
      final booked = perSec * headroom;
      if (booked > minShortfallPerSec) gaps[c] = booked;
    }

    if (sim.systemOn(0.3) && !sim.breathable) {
      gap(
          Commodity.oxygen,
          pop * CitySim.waterPerPersonPerSec * (1 - sim.airO2) -
              (here[Commodity.oxygen] ?? 0),
          supplyHeadroom);
    }
    for (final (c, perPerson) in const [
      (Commodity.water, CitySim.waterPerPersonPerSec),
      (Commodity.food, CitySim.foodPerPersonPerSec),
    ]) {
      final built = math.min(pop * perPerson, full[c] ?? 0);
      gap(c, built - (here[c] ?? 0));
    }
    return gaps;
  }

  /// Opening stock and standing orders at [site] for the [shortfall]. The
  /// orders are ordinary player deliveries — recurring, self-fuelling so the
  /// colony needs no propellant to receive them, editable and cancellable
  /// like any other — booked in order of urgency (air, water, food), each
  /// sized so what LANDS, after the craft burns its return fuel out of its
  /// cargo, is a day's shortfall.
  static void _bookSupply(CitySim sim, CityStart start, String site) {
    final need = shortfall(sim);
    if (need.isEmpty) return;
    // Food and water are already stocked; the air is the one the larder
    // forgot.
    if (need.containsKey(Commodity.oxygen)) {
      sim.stock[Commodity.oxygen] = start.supplies;
    }
    // The return burn is affine in the cargo it lifts, so the booked amount
    // that lands a given payload is one division.
    final fixed = sim.returnFuelFor(0);
    final perUnit = sim.returnFuelFor(1) - fixed;
    for (final c in const [Commodity.oxygen, Commodity.water, Commodity.food]) {
      final perSec = need[c];
      if (perSec == null) continue;
      final landed = perSec * supplyIntervalSec;
      (sim.deliveries[site] ??= []).add(DeliverySchedule(
        resource: c,
        intervalSec: supplyIntervalSec,
        amount: (landed + fixed) / (1 - perUnit),
        spareFuel: true,
        timer: supplyIntervalSec,
      )..recurring = true);
    }
  }

  /// The kit's life support at [run] (0..1 of nameplate), net of what it
  /// uses, per second: the farm's and the pump's outputs at this site's yield
  /// and the difficulty's bounty, as the tick produces them.
  static Map<String, double> _kitLifeNet(CitySim sim, double run) {
    final net = <String, double>{};
    for (final s in [_farm, _pump]) {
      s.outputs.forEach((c, v) => net[c] =
          (net[c] ?? 0) + v * run * sim.biomeMult(c) * sim.bountyMult);
      s.inputs.forEach((c, v) => net[c] = (net[c] ?? 0) - v * run);
    }
    return net;
  }

  /// The share of the farm and pump the kit's solar farm can power, as the
  /// tick's life-first split gives it them (`lifeThrottle`'s power term).
  static double _kitLifePower(CitySim sim) {
    final out = _solar.powerOutput * sim.powerFactor(_solar.type);
    final draw = _farm.powerDraw + _pump.powerDraw;
    return draw <= 0 ? 1.0 : (out / draw).clamp(0.0, 1.0);
  }

  /// The base catalogue spaceport — the smallest one, and the only one open at
  /// population zero.
  static CityBuildingSpec get _spaceport =>
      kUtilCatalog.firstWhere((s) => s.type == 'spaceport');

  static CityBuildingSpec get _solar =>
      kUtilCatalog.firstWhere((s) => s.type == 'solar');

  static CityBuildingSpec get _warehouse =>
      kUtilCatalog.firstWhere((s) => s.type == 'warehouse');

  static CityBuildingSpec get _farm =>
      kUtilCatalog.firstWhere((s) => s.label == 'Farm');

  static CityBuildingSpec get _pump =>
      kUtilCatalog.firstWhere((s) => s.type == 'aquifer');
}
