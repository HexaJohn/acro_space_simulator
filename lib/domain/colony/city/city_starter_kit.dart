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
/// Domain, not screen: the setup UI picks a world and a difficulty, and this
/// turns that into a live colony. A test — or a headless driver — can found the
/// same starting position with no widgets in the process.
library;

import 'city_building_spec.dart';
import 'city_config.dart';
import 'city_sim.dart';
import 'commodity.dart';
import 'parcel.dart';
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

  /// Opening food + water, in stock units each. Life support runway.
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

    // The agents build nothing until the colony first advances.
    if (agentTraffic) sim.agents.enabled = true;

    // Milestone tier 0 is the founding state. Recorded up front so the ladder
    // starts where the colony does and the first banner the player sees is a
    // tier they actually climbed.
    sim.claimMilestones();
    return sim;
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
