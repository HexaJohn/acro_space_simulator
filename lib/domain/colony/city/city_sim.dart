// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The colony / city simulation, as a domain aggregate.
///
/// This used to live inside the city builder's `State` object, which meant the
/// colony only advanced while its screen was mounted — a city paused the moment
/// you flew away from it. Everything here is now plain Dart with no Flutter in
/// scope, so `AdvanceSimulationTick` can drive it alongside the vessel physics
/// and one world runs whether you are watching the city, the cockpit, or orbit.
///
/// The screen keeps what is genuinely presentational: the held tool, the paint
/// mode, camera state, and the icon/colour tables.
library;

import 'dart:math' as math;

import '../../planetary/atmospheric_composition.dart';
import '../../planetary/liquid_mix.dart';
import '../../planetary/planet_surface.dart';
import '../../planetary/surface_conditions.dart';
import '../../universe/celestial_body.dart';
import '../../shared/vector3.dart';
import '../building.dart';
import '../surface_placement.dart';
import '../city_network.dart';
import 'city_building_spec.dart';
import 'city_config.dart';
import 'city_layout.dart';
import 'parcel.dart';
import 'commodity.dart';

/// A craft visiting a spaceport — a relief mission or a scheduled delivery. It
/// descends onto a free pad, dwells ~30 s while loading/unloading (the payload
/// drops once at the start of the dwell), then ascends and departs.
class LandedCraft {
  final int anchor; // the spaceport it's serving
  final int padTile; // which footprint tile (pad) it sits on
  final bool isRelief; // relief mission (vs a scheduled resource delivery)
  final String? resource; // delivered commodity (deliveries only)
  final double payload; // actual amount delivered (after any spare-fuel cut)
  double phase = 0; // 0..1 PAD timeline (descend / dwell 30 s / ascend)
  bool granted = false; // one-shot payload guard

  LandedCraft({
    required this.anchor,
    required this.padTile,
    required this.isRelief,
    this.resource,
    this.payload = 0,
  });
}

/// A recurring resource delivery booked at a spaceport: every [intervalSec] a
/// craft brings [amount] of [resource]. [timer] counts down to the next dispatch.
class DeliverySchedule {
  String resource;
  double intervalSec;
  double amount;
  double timer;

  /// Pad this delivery is pinned to (footprint-tile index 0..cellCount-1), or
  /// null to use any free pad. Lets a starport route specific runs to specific
  /// pads so several deliveries can run in parallel / in a chosen order.
  int? padIndex;

  /// If true the craft carries its OWN return-to-orbit propellant (subtracted
  /// from its payload). If false the colony fuels it from the spaceport's
  /// fuel+oxidizer stockpile; with neither, the craft stays grounded.
  bool spareFuel;

  /// If true this run repeats every [intervalSec]; if false it's a ONE-TIME
  /// delivery — dispatched once, then removed from the schedule. Defaults to a
  /// one-time run; the editor's Recurring toggle sets it.
  bool recurring = false;
  DeliverySchedule({
    required this.resource,
    required this.intervalSec,
    required this.amount,
    this.padIndex,
    this.spareFuel = true,
    this.timer = 0,
  });
}

/// Sentinel "resource" for a delivery that brings settlers instead of a
/// commodity. People raise the population floor (like a relief drop) rather
/// than topping up a stockpile.
const String kDeliveryPeople = 'people';

/// Colony architecture style — how buildings + connections are rendered and what
/// they require. `open` = Earth-like (boxes + roads, needs breathable air);
/// `domed` = sealed habitat for hostile surfaces (dome caps + pressurized tubes);
/// `orbital` = vacuum station (cylindrical hull modules + truss corridors).
/// Captured PER BUILDING at placement; the Retrofit tool converts it in place.
enum ColonyStyle { open, domed, orbital }

/// Natural ground cover scattered on empty tiles, themed by biome. The painter
/// draws each kind; bulldozing clears it; it slowly regrows on cleared land.
enum ScatterKind { tree, conifer, bush, grass, cactus, rock, boulder, iceShard, fungus, crystalSpire, crater }

/// Biotic scatter kinds (plants/fungus) — present only where there's enough
/// habitability; they die off when the world turns hostile. The rest (rock,
/// boulder, iceShard, crystalSpire, crater) are abiotic and climate-invariant.
const Set<ScatterKind> bioticScatter = {
  ScatterKind.tree,
  ScatterKind.conifer,
  ScatterKind.bush,
  ScatterKind.grass,
  ScatterKind.cactus,
  ScatterKind.fungus,
};

/// Weather + catastrophe events the player can trigger. Each has a duration and
/// simple rendered effect over the map.
enum Disaster {
  none('None', 0),
  rain('Rain', 180),
  thunderstorm('Thunderstorm', 150),
  snow('Snow', 210),
  dustStorm('Dust Storm', 180),
  tornado('Tornado', 120),
  fire('Fire', 150),
  meteorShower('Meteor Shower', 120),
  plague('Plague', 240),
  famine('Famine', 240),
  solarStorm('Solar Storm', 180),
  nuke('Nuclear Strike', 120),
  // --- Appended (indices 12+) so the painter's existing case numbers hold. ---
  // Weather escalations / de-escalations.
  hurricane('Hurricane', 150),
  blizzard('Blizzard', 180),
  // Benign / atmospheric.
  fog('Fog', 120),
  acidRain('Acid Rain', 150),
  // Geophysical.
  earthquake('Earthquake', 40),
  // Sci-fi, condition-based per world.
  radiationStorm('Radiation Storm', 150),
  glassRain('Glass Rain', 130), // silicate rain (hot rocky worlds)
  ammoniaStorm('Ammonia Storm', 160), // ice-giant chemistry
  cryovolcanism('Cryovolcanism', 90), // icy-moon water volcanism
  miasma('Miasma', 140), // rises from unburied corpses
  // --- Wave 2 (indices 22+). Moving fronts, cosmic, bio, exotic, meta. ---
  // Moving fronts (ride the storm track).
  lavaFlow('Lava Flow', 100),
  sandworm('Sandworm', 90),
  grayGoo('Gray Goo', 110),
  crawlingForest('The Crawling Forest', 120),
  rollingGlitch('Rolling Glitch', 80),
  // Cosmic overlays.
  auroraBloom('Aurora Bloom', 120), // benign
  eclipse('Eclipse', 90),
  gammaRayBurst('Gamma-Ray Burst', 30),
  fallingStar('Falling Star', 40), // benign rare
  skyCrack('Sky Crack', 70),
  // Reality-bending.
  timeDilation('Time Dilation', 100),
  // Bio / matter.
  sporeBloom('Spore Bloom', 130),
  crystalGrowth('Crystal Growth', 140),
  biolumTide('Bioluminescent Tide', 120), // benign
  chemicalRain('Chemical Rain', 130),
  // Exotic precipitation.
  diamondRain('Diamond Rain', 90), // benign-ish (gifts gems)
  ironSnow('Iron Snow', 110),
  methaneDownpour('Methane Downpour', 120),
  bloodRain('Blood Rain', 110),
  blackRain('Black Rain', 120),
  // Society / meta (no painter — UI/economy only).
  commsBlackout('Comms Blackout', 100),
  goldRush('Gold Rush', 120), // positive
  refugeeInflux('Refugee Influx', 60),
  festival('Festival', 80), // benign
  cultUprising('Cult Uprising', 110),
  aiAwakening('AI Awakening', 120),
  marketCrash('Market Crash', 110),
  // Wildcards.
  alienBeacon('Alien Beacon', 150),
  rainingFrogs('Raining Frogs', 50), // benign meme
  glitchInMatrix('Glitch in the Matrix', 5); // repeats last

  final String label;
  final double duration; // seconds
  const Disaster(this.label, this.duration);
}

enum Govt {
  autocracy('Autocracy', false, 0.30, 1.4, -0.05),
  monarchy('Monarchy', false, 0.22, 1.1, 0.0),
  technocracy('Technocracy', false, 0.10, 0.9, 0.05),
  republic('Republic', true, 0.15, 0.8, 0.05),
  democracy('Democracy', true, 0.12, 0.7, 0.08),
  anarchy('Anarchy', false, 0.45, 1.8, -0.10);

  final String label;
  final bool lawsAutoVoted;
  final double corruptionBase;
  final double rebellionSensitivity;
  final double happinessMod;
  const Govt(this.label, this.lawsAutoVoted, this.corruptionBase,
      this.rebellionSensitivity, this.happinessMod);
}

enum Law {
  curfew('Curfew', 'crime −, happiness −'),
  freeHealthcare('Free Healthcare', 'happiness +, funds −'),
  antiCorruption('Anti-Corruption Bureau', 'corruption −, funds −'),
  homelessShelters('Homeless Shelters', 'homelessness relief, funds −'),
  industrialSubsidy('Industrial Subsidy', 'industry +, happiness −'),
  freePublicTransit('Free Public Transit', 'happiness +, funds −'),
  emissionsCap('Emissions Cap', 'pollution −, industry −'),
  wealthTax('Wealth Tax', 'inequality −, funds +, happiness −'),
  robotTax('Robot Tax / UBI', 'automation unemployment −, funds −, happiness +');

  final String label;
  final String effect;
  const Law(this.label, this.effect);
}

enum Economy {
  capitalism('Capitalism', 1.4, 0.6, 1.3, 0.0, true),
  freeMarket('Free Market', 1.8, 0.9, 1.5, 0.0, true),
  socialism('Socialism', 0.9, 0.25, 1.0, 0.15, true),
  communism('Communism', 0.7, 0.0, 0.8, 0.35, false);

  final String label;
  final double fundsMult;
  final double taxHappinessPenalty;
  final double researchMult;
  final double happinessFloor;
  final bool taxControllable;
  const Economy(this.label, this.fundsMult, this.taxHappinessPenalty,
      this.researchMult, this.happinessFloor, this.taxControllable);
}


/// Aggregate root for one colony: its land, buildings, stockpile, population,
/// politics, environment and disasters, plus the tick that advances them.
class CitySim {
  /// Found a colony from [cfg] (or all defaults). Picks the host body, applies
  /// the difficulty knobs, sculpts the starting terrain and drops the lander at
  /// the map's hub cell — everything the city builder's `initState` used to do
  /// inline, so a colony can now be founded headlessly.
  factory CitySim.found(
    CityConfig? cfg, {
    required List<CelestialBody> bodies,
    String id = 'colony-1',
    String name = 'Colony',
  }) {
    final sim = CitySim._(id, name);
    sim.bodies = bodies;
    sim.grid = (cfg?.gridSize ?? sim.grid).clamp(8, maxGrid);
    final wantBody = cfg?.bodyId ?? 'earth';
    sim.body = bodies.firstWhere((b) => b.id.value == wantBody,
        orElse: () => bodies.firstWhere((b) => b.id.value == 'earth',
            orElse: () => bodies.first));
    if (cfg?.biome != null) sim.biome = cfg!.biome!;
    // Colony mode: from config, but a gas giant forces a non-surface mode.
    if (cfg?.colonyModeIndex != null) {
      sim.colonyMode = ColonyStyle.values[cfg!.colonyModeIndex!];
    }
    if (sim.body.isGasGiant && sim.colonyMode == ColonyStyle.open) {
      sim.colonyMode = ColonyStyle.domed; // floating cloud city
    }
    if (cfg?.govtIndex != null) sim.govt = Govt.values[cfg!.govtIndex!];
    if (cfg?.economyIndex != null) {
      sim.economy = Economy.values[cfg!.economyIndex!];
    }
    sim.complexity = cfg?.complexity ?? sim.complexity;
    sim.hostility = cfg?.hostility ?? sim.hostility;
    sim.forgiveness = cfg?.forgiveness ?? sim.forgiveness;
    sim.bounty = cfg?.bounty ?? sim.bounty;
    // Colony site lat/long: from config, else a deterministic spot per world
    // (stable across launches; biased toward mid-latitudes, not the poles).
    final seed = sim.body.id.value.hashCode;
    sim.cityLat = cfg?.latitude ?? (((seed % 1000) / 1000) * 100 - 50); // -50..50
    sim.cityLon =
        cfg?.longitude ?? ((((seed ~/ 1000) % 1000) / 1000) * 360 - 180);
    sim.hubKey = sim.key(sim.grid ~/ 2, sim.grid ~/ 2);
    sim.roads.add(sim.hubKey);
    sim.genElevation(); // sculpt rolling terrain + the sea/lava level
    sim.seedScatter(); // dress the virgin land in biome-appropriate flora/rocks
    sim.recompute();
    return sim;
  }

  CitySim._(this.id, this.name);

  /// Stable identity in the world. Colonies are addressed by it in snapshots,
  /// delivery contracts and save files.
  final String id;
  final String name;

  int grid = 20; // overridden by CityConfig.gridSize
  static const maxGrid = 48; // ~10x the old 144-tile cap (now up to 2304)
  static const cellM = 24.0;

  static const double zoneBuildCost = 20;
  static const double refundFraction = 0.5;
  static const double foodPerPersonPerSec = 0.02;
  static const double waterPerPersonPerSec = 0.03;
  // Per-capita waste output. Kept low so a handful of landfills / sewage plants
  // keep a mid-size colony clear — the old rates (0.015 / 0.02) buried even a
  // small colony in backlog faster than reasonable waste infrastructure could
  // process it.
  static const double garbagePerPersonPerSec = 0.006;
  static const double sewagePerPersonPerSec = 0.008;
  static const double baseStockCap = 200;
  static const double taxPerWorkerPerSec = 0.05;
  static const double researchPerPopPerSec = 0.02;
  static const double growThreshold = 0.2;
  static const double abandonDelay = 4.0;
  static const double landCost = 200;
  static const int landerCrew = 6; // crew quarters in the landed capsule

  // Placement.
  final Map<int, CityZoneType> zones = {};
  final Set<int> grown = {};
  // Per grown-zone cell: build/utilisation progress 0..1. 0..0.3 = under
  // construction (scaffold, no economy yet); 0.3..1 ramps occupancy from
  // small -> medium -> large -> max as demand sustains it.
  final Map<int, double> growProgress = {};
  final Set<int> abandoned = {};
  final Map<int, double> abandonTimer = {};
  final Map<int, CityBuildingSpec> utils = {}; // keyed by ANCHOR (top-left) cell
  // For multi-tile buildings: every non-anchor cell they cover -> anchor cell,
  // so taps / occupancy / clearing on any covered tile resolve to the building.
  final Map<int, int> footprint = {};
  // Rubble left by disasters: cells that held a building flattened by a
  // catastrophe. Cosmetic debris until bulldozed; blocks placement.
  final Set<int> rubble = {};
  // Active fires: burning building tiles -> burn intensity 0..1. A fire damages
  // its building, SPREADS to adjacent flammable tiles (blocked by roads + a
  // random firebreak chance), and is put out by emergency-service coverage. Map
  // value also gates the flame render's size.
  final Map<int, double> fires = {};
  final Set<int> roads = {};
  late int hubKey;
  Set<int> connectedCells = {};
  final Map<int, double> traffic = {}; // road key -> normalised load 0..1
  double congestion = 0; // peak traffic 0..1 (drags commute efficiency)


  // Host planet (sets solar + wind effectiveness) + biome (local terrain buffs).
  late final List<CelestialBody> bodies;
  late CelestialBody body;
  double cityLat = 0, cityLon = 0; // colony site on the host body (degrees)
  Biome biome = Biome.grassland;

  // Difficulty (0..1 each). Complexity = how many systems are active; Hostility
  // = disaster frequency/severity; Forgiveness = how much slack before people
  // die/leave; Bounty = production-rate multiplier (high = easy/abundant).
  double complexity = 0.6;
  double hostility = 0.4;
  double forgiveness = 1.0; // DEBUG default: max slack
  double bounty = 1.0; // DEBUG default: max abundance
  // Countdown to the next random disaster, in SIM seconds. Seeded with a long
  // opening grace (~30 min of sim time) so a brand-new colony gets a long, calm
  // start to establish itself before the first event (was 0 = instant disaster).
  double autoDisasterTimer = 1800;

  double timeWarp = 4;
  final Map<String, double> stock = {
    Commodity.ore: 200,
    Commodity.fuel: 40,
    Commodity.oxidizer: 30,
    Commodity.water: 100,
    Commodity.food: 100,
  };
  double population = 0;
  bool starved = false;
  double happiness = 0.5;
  double foodSecurity = 1.0;
  double funds = 0;
  double research = 0;
  double pollution = 0; // accumulated atmospheric pollution 0..~
  double computeSupply = 0; // current compute capacity
  double computeDemand = 0;
  Economy economy = Economy.capitalism;
  double taxRate = 0.15;
  Govt govt = Govt.democracy;
  final Set<Law> laws = {};
  double crime = 0;
  double corruption = 0;
  double inequality = 0;
  int homeless = 0;
  double rebellion = 0;
  double corpses = 0; // unprocessed bodies awaiting deathcare
  double disease = 0; // 0..1 outbreak level
  double deathRate = 0; // people/s dying (display)
  double wasteBacklog = 0; // 0..1 unprocessed garbage+sewage nuisance
  double radiation = 0; // 0..1 background radiation (nuke/space/disaster)
  double nuclearWinter = 0; // 0..1 sky-darkening (cuts solar + food + temp)
  double terraform = 0; // 0..1 terraforming progress (shifts biome toward Earthlike)
  double waterTable = 1.0; // 0..1 colony aquifer level (pumping dries the ground)
  double oceanPollution = 0; // 0..1 contaminant fraction injected into the sea

  bool flagPlanted = false; // a flag planted at the landing site (cosmetic)
  bool infiniteRes = false; // DEBUG: stockpiles never deplete (show ∞, keep rates)
  bool infiniteDemand = false; // DEBUG: RCI demand pinned to max (zones keep growing)
  bool infiniteRobotics = false; // DEBUG/endgame: buildings need no workers (full staffing)
  bool ignoreUnlocks = false; // DEBUG: build anything regardless of population gate

  int? landerPad; // spaceport anchor the lander is parked on (occupied), or null
  // Craft currently visiting spaceports — relief missions (request assistance) +
  // scheduled resource deliveries. Each lands on a free pad of its spaceport,
  // dwells ~30 s while it loads/unloads, then leaves. A spaceport supports one
  // craft PER FOOTPRINT TILE.
  final List<LandedCraft> craft = [];
  double reliefCooldown = 0; // seconds until assistance can be requested again
  int reliefCrew = 0; // settlers the relief missions have added (population floor)
  // Recurring delivery schedules per spaceport anchor — a LIST so one starport
  // can run several deliveries (each its own resource/interval/pad). A craft is
  // dispatched whenever a schedule is due and its assigned (or any free) pad is
  // open; the list order is the dispatch priority.
  final Map<int, List<DeliverySchedule>> deliveries = {};

  // Active disaster + its remaining seconds + an animation phase.
  Disaster disaster = Disaster.none;
  double disasterTime = 0;
  // Tornado/cyclone track: a moving epicentre (grid-fraction coords 0..grid) the
  // funnel walks across the colony, so it visibly travels + damages where it is.
  double stormX = 0, stormY = 0; // current position
  double stormVX = 0, stormVY = 0; // velocity (cells/sec)
  bool stormLeftMap = false; // a sweeping front has drifted off the map -> end
  // Transient modifiers driven by meta/positive events (1.0 = neutral).
  double eventProductionMult = 1.0; // gold rush boosts, market crash cuts
  double eventHappyBonus = 0.0; // festival / aurora cheer, cult / blackout gloom
  double eventSimWarp = 1.0; // time-dilation multiplier on dt
  double dayPhase = 0.25; // 0..1 around the body's rotation (0.25 = morning)
  bool commsDown = false; // comms blackout: no immigration this event
  Disaster lastDisaster = Disaster.none; // for "glitch in the matrix" replay
  int? beaconCell; // grid cell the alien-beacon monolith stands on
  final Set<int> crystal = {}; // tiles overgrown by crystal/spore (block build)
  // Tiles around waste-producing buildings (housing/commercial) where litter
  // piles up — so garbage/sewage appears NEXT TO where people live, not on
  // empty streets. Recomputed when the layout changes.
  final List<int> wasteSites = [];
  // Natural ground cover (trees/rocks/etc) per empty tile -> ScatterKind.index.
  // Bulldozable; slowly regrows on cleared land. Themed by the host biome.
  final Map<int, int> scatter = {};
  double regrowTimer = 0; // countdown to the next scatter regrowth step
  // Per-tile terrain elevation in metres above the local datum (rolling hills +
  // basins). Tiles BELOW the sea/lava level are liquid. Generated once at start.
  final Map<int, double> elevation = {};
  // Rolling-hills relief is OPT-IN. Off (default) -> flat land (oceans/coastlines
  // still form, just without lumpy ground). On -> the biome's full height field.
  bool terrainRelief = false;
  double seaLevel = -1e9; // datum (m); tiles with elevation < this are liquid
  // Cells that are standing liquid (ocean / lava). Computed in genElevation
  // BEFORE the sea floor is flattened, so membership survives clamping.
  final Set<int> liquidTiles = {};
  // Per-building architecture style (anchor cell -> ColonyStyle.index), captured
  // at placement. Environment changes don't auto-reskin; the Retrofit tool does.
  final Map<int, int> buildStyle = {};
  // Road tiles laid while the air was NOT breathable -> rendered as sealed
  // pressurised TRANSPORT TUBES (like the buildings, the style is captured at
  // BUILD time and preserved; terraforming later doesn't flip them — Retrofit
  // does). A tile absent here is an open-air asphalt road.
  final Set<int> roadSealed = {};
  // Colony mode chosen at founding (surface vs floating vs orbital). Drives the
  // DEFAULT style for new buildings + the support requirement.
  ColonyStyle colonyMode = ColonyStyle.open;
  // Open-style buildings exposed to hostile air accumulate a decompression timer;
  // past the grace they're destroyed (not just abandoned). anchor -> seconds.
  final Map<int, double> decompressTimer = {};
  // Structural support layer (Platform over water / Truss in vacuum / Lift-frame
  // in atmosphere). Placed like roads; a building needs support adjacency. Loss
  // of support DESTROYS the building it held.
  final Set<int> support = {};
  String? revoltMsg;
  // Cached aggregate readouts (recomputed each tick from active buildings).
  int housing = 0, jobs = 0;
  double staffing = 1.0; // filled jobs / required jobs (0..1)
  double throttle = 1.0; // min(power, compute, staffing) production scaler
  double powerOut = 0, powerDraw = 0;
  double resTarget = 0, comTarget = 0, indTarget = 0; // RCI demand
  final Map<String, double> services = {};
  String? blocked;

  int key(int x, int y) => y * grid + x;

  // Earth references for normalising solar flux + air density to 1.0.
  static const double earthFlux = 1361; // W/m^2
  static const double earthDensity = 1.225; // kg/m^3

  /// Solar effectiveness: ∝ irradiance at this body (closer to the Sun = more,
  /// farther = less), normalised so Earth = 1.0.
  double get solarFactor => (body.solarFlux / earthFlux).clamp(0.05, 4.0);

  /// Wind effectiveness: ∝ atmospheric density (airless bodies = ~0, thick
  /// atmospheres = more), normalised so Earth = 1.0 and capped.
  double get windFactor {
    final d = body.atmosphere?.seaLevelDensity ?? 0;
    return (d / earthDensity).clamp(0.0, 3.0);
  }

  /// Daylight level 0 (deep night) .. 1 (noon), a smooth sun curve over the day
  /// phase. Sunrise ~0.25, noon 0.5, sunset ~0.75. Used to tint the map + switch
  /// building lights on at night.
  double get daylight {
    // sin peaks at phase 0.5 (noon), zero at 0/1 (midnight). Clamp the night to
    // a soft floor so it's dusk-dark, not pitch black.
    final s = math.sin(dayPhase * math.pi); // 0 at midnight, 1 at noon
    return (s * s).clamp(0.0, 1.0);
  }

  /// O2 mole fraction of the host atmosphere (0 if airless / no data).
  double get o2Fraction =>
      body.composition?.fractions[AtmosphereGas.oxygen] ?? 0;

  /// Breathable worlds (Earth-like O2 + real atmosphere) supply oxygen for free
  /// — no city oxygen production needed.
  bool get breathable =>
      (body.atmosphere?.seaLevelDensity ?? 0) > 0.3 && o2Fraction >= 0.15;

  /// Can an atmospheric harvester pull O2 here? (Some breathable-enough O2 in a
  /// real atmosphere, but not free-breathable.)
  bool get o2Harvestable =>
      (body.atmosphere?.seaLevelDensity ?? 0) > 0.05 && o2Fraction >= 0.02;

  /// Per-biome economic buffs/debuffs. Multipliers on food/water/ore/solar
  /// production + a flat happiness + pollution-scrub modifier.
  ({
    double food,
    double water,
    double ore,
    double solar,
    double happy,
    double scrub, // pollution decay bonus
  }) get biomeFx => switch (biome) {
        Biome.ocean => (food: 1.2, water: 1.6, ore: 0.6, solar: 1.0, happy: 0.02, scrub: 0.5),
        Biome.iceCap => (food: 0.5, water: 1.4, ore: 0.8, solar: 0.6, happy: -0.05, scrub: 0.0),
        Biome.tundra => (food: 0.6, water: 1.1, ore: 1.0, solar: 0.8, happy: -0.02, scrub: 0.0),
        Biome.desert => (food: 0.5, water: 0.5, ore: 1.1, solar: 1.4, happy: -0.03, scrub: 0.0),
        Biome.grassland => (food: 1.4, water: 1.0, ore: 0.9, solar: 1.0, happy: 0.05, scrub: 0.5),
        Biome.forest => (food: 1.2, water: 1.1, ore: 0.8, solar: 0.9, happy: 0.08, scrub: 2.0),
        Biome.mountains => (food: 0.7, water: 1.0, ore: 1.6, solar: 1.0, happy: 0.0, scrub: 0.5),
        Biome.volcanic => (food: 0.6, water: 0.8, ore: 1.8, solar: 1.0, happy: -0.04, scrub: -1.0),
        Biome.barren => (food: 0.3, water: 0.6, ore: 1.2, solar: 1.1, happy: -0.06, scrub: 0.0),
        Biome.wetland => (food: 1.6, water: 1.8, ore: 0.5, solar: 0.9, happy: 0.0, scrub: 1.5),
        Biome.coastal => (food: 1.3, water: 1.5, ore: 0.7, solar: 1.0, happy: 0.06, scrub: 1.0),
        Biome.volcano => (food: 0.2, water: 0.3, ore: 2.2, solar: 1.0, happy: -0.08, scrub: -2.0),
      };

  /// Live physical surface conditions for THIS body, blended with the colony's
  /// terraforming progress + environmental damage. Drives habitability, flora,
  /// breathability and (later) the colony architecture style.
  SurfaceConditions get surface => SurfaceConditions.of(
        body,
        biome: biome,
        waterTable: waterTable,
        terraform: terraform,
        pollution: pollution,
        nuclearWinter: nuclearWinter,
        radiationLevel: radiation,
      );

  /// The colony's surface liquid (ocean / aquifer / lava lake) as a molecular
  /// mix, derived from the body's conditions and then CONTAMINATED by the
  /// colony's own ocean pollution. Drives the water/lava tile colour + what the
  /// aquifer yields.
  LiquidMix get liquid {
    final s = surface;
    // A volcano biome's "sea" is always a molten lava lake, regardless of the
    // global climate; otherwise derive the dominant liquid from conditions.
    var mix = biome == Biome.volcano
        ? LiquidMix.lava()
        : LiquidMix.forConditions(
            temperatureK: s.temperatureK,
            co2Fraction: co2Fraction,
            methaneFraction:
                body.composition?.fractions[AtmosphereGas.methane] ?? 0,
          );
    if (oceanPollution > 0.01) mix = mix.contaminated('oil', oceanPollution);
    return mix;
  }

  /// The architecture style a NEWLY placed building takes, from the colony mode
  /// + live conditions: orbital stations are always orbital; on a surface/
  /// floating colony you build open where the air is breathable, domed where it
  /// isn't (or where it's a floating cloud deck). Existing buildings keep their
  /// own captured style until retrofitted.
  ColonyStyle get currentStyle {
    if (colonyMode == ColonyStyle.orbital) return ColonyStyle.orbital;
    if (colonyMode == ColonyStyle.domed) {
      // Floating cloud deck: open only if the surrounding air is breathable.
      return surface.breathable ? ColonyStyle.open : ColonyStyle.domed;
    }
    return surface.breathable ? ColonyStyle.open : ColonyStyle.domed;
  }

  int styleOf(int anchor) =>
      buildStyle[anchor] ?? currentStyle.index;

  // ---- Structural support ----
  /// Whether this colony needs a support structure under/beside buildings:
  /// orbital stations (vacuum) + floating colonies (no solid ground). Surface
  /// colonies don't (except over water — handled per-tile in [tileSupported]).
  bool get colonyNeedsSupport => colonyMode != ColonyStyle.open;

  /// Support-structure name for this colony mode (UI).
  String get supportLabel => switch (colonyMode) {
        ColonyStyle.orbital => 'Truss',
        ColonyStyle.domed => 'Lift-frame', // floating colony
        ColonyStyle.open => 'Platform', // over water
      };

  /// A colony that has any standing surface liquid (ocean/coastal/wetland/lava):
  /// some tiles are below the sea level and need Platforms to build on.
  bool get isOceanColony =>
      colonyMode == ColonyStyle.open && seaLevel > -1e8;

  /// True if [k] is a liquid tile (below the sea/lava level) needing a Platform.
  bool isWaterTile(int k) => isLiquidTile(k);

  /// Is a building footprint at these cells structurally supported? On solid
  /// land this is always true; on orbital/floating colonies (and over OCEAN
  /// water) every covered cell must BE a support tile or be adjacent to one
  /// (orbital/floating) or directly ON one (water platforms).
  bool footprintSupported(int ax, int ay, int fw, int fh) {
    for (var dy = 0; dy < fh; dy++) {
      for (var dx = 0; dx < fw; dx++) {
        final k = key(ax + dx, ay + dy);
        if (isWaterTile(k)) {
          // Water: the tile itself must be platformed (no adjacency shortcut —
          // you can't hang a building over open water off a neighbour's pier).
          if (!support.contains(k)) return false;
        } else if (colonyNeedsSupport) {
          if (!cellSupported(k)) return false;
        }
      }
    }
    return true;
  }

  bool cellSupported(int k) {
    if (support.contains(k)) return true;
    for (final nb in neighbours(k)) {
      if (support.contains(nb)) return true;
    }
    return false;
  }

  /// Which natural ground cover grows on the current biome (+ density 0..1 of
  /// how much of the open land it carpets). Airless/barren worlds are sparse;
  /// lush biomes are dense. The exotic kinds appear off-world.
  ({List<ScatterKind> kinds, double density}) get biomeScatter {
    final s = surface;
    final flora = s.floraDensity; // climate × biome flora potential × wetness
    final cold = s.temperatureK < 268;
    final warm = s.temperatureK > 288;
    final dry = s.surfaceMoisture < 0.35;
    final isMoon = body.parent != null && !inEarthSystem; // a moon, off-world
    final airless = s.pressureAtm < 0.05;

    // --- Abiotic (climate-invariant geology): always present. ---
    final abiotic = <ScatterKind>[ScatterKind.rock, ScatterKind.boulder];
    if (cold || airless) abiotic.add(ScatterKind.iceShard);
    if (isMoon || airless) abiotic.add(ScatterKind.crater); // cratered surfaces
    if (!inEarthSystem && s.pressureAtm < 0.2 && s.temperatureK < 200) {
      abiotic.add(ScatterKind.crystalSpire); // exotic frozen worlds
    }

    // --- Biotic: how lush is the surface? Driven by floraDensity (so a living
    //     Earth forest is dense + green, a dry desert sparse, raw Mars empty). ---
    final biotic = <ScatterKind>[];
    if (flora > 0.08) {
      if (warm && dry) biotic.add(ScatterKind.cactus); // wet air, dry ground = scrub
      if (!cold) {
        biotic.add(ScatterKind.grass);
        if (flora > 0.25) biotic.add(ScatterKind.bush);
        if (flora > 0.4) biotic.add(ScatterKind.tree);
      }
      if (cold && flora > 0.2) biotic.add(ScatterKind.conifer);
      if (flora > 0.5 && s.surfaceMoisture > 0.6) biotic.add(ScatterKind.fungus);
    }

    // Weight the mix toward biotic on lush worlds, abiotic on dead ones.
    final kinds = <ScatterKind>[
      ...abiotic,
      for (final b in biotic) ...[b, b],
      if (flora > 0.6) ...biotic, // extra greenery on lush worlds
    ];
    // Density: abiotic baseline + biotic bonus from the flora cover.
    final density = (0.18 + flora * 0.6).clamp(0.1, 0.85);
    return (kinds: kinds, density: density);
  }

  /// Pick a scatter kind for a cell deterministically (so it doesn't reshuffle).
  int scatterKindFor(int k) {
    final kinds = biomeScatter.kinds;
    if (kinds.isEmpty) return ScatterKind.rock.index;
    final h = (k * 2654435761) & 0x7fffffff;
    return kinds[h % kinds.length].index;
  }

  /// True if a cell is bare ground available for scatter to grow on. Liquid tiles
  /// (ocean/lava) are excluded — nothing scatters on water.
  bool cellOpen(int k) =>
      k != hubKey &&
      !roads.contains(k) &&
      !zones.containsKey(k) &&
      anchorOf(k) == null &&
      !rubble.contains(k) &&
      !crystal.contains(k) &&
      !isLiquidTile(k) &&
      !scatter.containsKey(k);

  /// Seed the initial natural cover across the open map (called once at start +
  /// after buying land). Density + kinds come from the biome.
  /// Smooth value-noise elevation (metres) for a cell — deterministic per body +
  /// biome so terrain is stable. Combines two octaves for rolling hills.
  double elevNoise(int gx, int gy) {
    final seed = body.id.value.hashCode ^ (biome.index * 0x9E3779B1);
    double oct(double scale) {
      final x = (gx / scale), y = (gy / scale);
      final x0 = x.floor(), y0 = y.floor();
      double v(int ix, int iy) {
        var h = seed ^ (ix * 73856093) ^ (iy * 19349663);
        h = (h ^ (h >> 13)) * 1274126177;
        return ((h & 0x7fffffff) % 1000) / 1000.0;
      }

      final fx = x - x0, fy = y - y0;
      double lerp(double a, double b, double t) => a + (b - a) * t;
      final sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy);
      final top = lerp(v(x0, y0), v(x0 + 1, y0), sx);
      final bot = lerp(v(x0, y0 + 1), v(x0 + 1, y0 + 1), sx);
      return lerp(top, bot, sy);
    }

    return oct(6.0) * 0.7 + oct(2.5) * 0.3; // 0..1
  }

  /// Build the elevation field + pick the sea/lava level. Flatter for stations
  /// (decks are flat) and dry biomes; lumpier for mountains; water-rich biomes
  /// get a higher sea level so more of the map is liquid (lumpy coastline).
  void genElevation() {
    elevation.clear();
    final relief = switch (biome) {
      Biome.mountains => 60.0,
      Biome.volcano || Biome.volcanic => 40.0,
      Biome.wetland => 8.0, // flat swamp
      Biome.ocean => 30.0,
      Biome.coastal => 35.0,
      _ => 22.0,
    };
    // Stations / cloud decks are flat platforms.
    final flat = colonyMode != ColonyStyle.open;
    // Coastal worlds get ONE ocean edge: land ramps DOWN toward the +Y (bottom)
    // edge into a single flat sea, instead of noise that makes scattered
    // islands. The ramp dominates; noise only roughens the land above water.
    final coastal = !flat && biome == Biome.coastal;
    // Ocean / volcano (lava lake) worlds are FULLY flooded — open water all the
    // way out (no land islands poking up); the colony lives on platforms. The
    // seabed sits well below the datum everywhere.
    final fullyFlooded =
        !flat && (biome == Biome.ocean || biome == Biome.volcano);
    var minE = 1e9, maxE = -1e9;
    for (var k = 0; k < grid * grid; k++) {
      final gx = k % grid, gy = k ~/ grid;
      // Relief is opt-in: when off, the lumpy land NOISE is dropped (flat ground),
      // but the structural flood geometry (coastal ramp, seabed) is KEPT so
      // oceans/coastlines still form. [noiseAmp] gates only the bumpy part.
      final noiseAmp = terrainRelief ? 1.0 : 0.0;
      double e;
      if (flat) {
        e = 0.0;
      } else if (fullyFlooded) {
        // Below the waterline everywhere: flat seabed, gently undulating only
        // when relief is on.
        e = -relief * (0.6 + elevNoise(gx, gy) * 0.4 * noiseAmp);
      } else if (coastal) {
        // 0 at the far (top) inland edge .. 1 at the near (bottom) sea edge.
        final t = grid > 1 ? gy / (grid - 1) : 0.0;
        // Ramp downward toward the shore (kept regardless of relief so the single
        // ocean edge always forms); bumpy inland noise only when relief is on.
        final ramp = (0.55 - t) * relief * 1.6;
        e = ramp + elevNoise(gx, gy) * relief * 0.25 * (1 - t) * noiseAmp;
      } else {
        // Dry inland biomes: flat unless relief is enabled.
        e = elevNoise(gx, gy) * relief * noiseAmp;
      }
      // The hub pad is always dry land (the colony's founding platform), even on
      // fully-flooded worlds where everything around it is sea.
      if (k == hubKey && fullyFlooded) e = 0.0;
      elevation[k] = e;
      if (e < minE) minE = e;
      if (e > maxE) maxE = e;
    }
    // Sea/lava level: a fraction of the relief range, by how watery the biome is.
    final waterFrac = switch (biome) {
      Biome.ocean => 0.75,
      Biome.coastal => 0.3,
      Biome.wetland => 0.35,
      Biome.volcano => 0.5, // lava lake
      _ => -1.0, // dry biomes: no standing liquid
    };
    seaLevel = waterFrac < 0 ? -1e9 : minE + (maxE - minE) * waterFrac;
    // Record which tiles are standing liquid (below the datum), THEN flatten the
    // sea floor to the datum so ocean reads as a single flat sheet (no lumpy
    // submerged hills). Membership is captured before clamping so it survives.
    liquidTiles.clear();
    if (waterFrac >= 0) {
      elevation.forEach((k, e) {
        if (e < seaLevel && k != hubKey) liquidTiles.add(k);
      });
      elevation.updateAll((k, e) => e < seaLevel ? seaLevel : e);
    }
    // Clear any pre-existing scatter that now sits on water (e.g. after a land
    // expansion re-floods tiles) — nothing grows on the sea.
    scatter.removeWhere((k, _) => liquidTiles.contains(k));
  }

  /// True if a tile is standing liquid (ocean/lava) — needs a platform. Reads the
  /// set captured at generation, since the sea floor is flattened to the datum
  /// afterward (so an elevation compare would no longer detect it).
  bool isLiquidTile(int k) =>
      colonyMode == ColonyStyle.open && liquidTiles.contains(k);

  void seedScatter() {
    if (colonyMode != ColonyStyle.open) return; // stations/cloud decks: no flora
    final sc = biomeScatter;
    final rnd = math.Random();
    for (var k = 0; k < grid * grid; k++) {
      if (!cellOpen(k)) continue;
      if (rnd.nextDouble() < sc.density) scatter[k] = scatterKindFor(k);
    }
  }

  /// Natural cover responds to LIVE habitability. When the world is alive,
  /// biotic cover (plants) regrows on cleared land; when it turns hostile
  /// (a ruined atmosphere, nuclear winter), the plants DIE OFF, leaving only the
  /// climate-invariant rocks/craters. Terraforming a dead world grows life;
  /// nuking a living one kills it.
  void regrowScatter(double dt) {
    if (colonyMode != ColonyStyle.open) return; // no terrain on stations/decks
    regrowTimer -= dt;
    if (regrowTimer > 0) return;
    regrowTimer = 4.0; // a step every ~4 sim-seconds
    final sc = biomeScatter;
    final flora = surface.floraDensity;

    // 1) Die-off: when the surface can't sustain its current greenery (low flora
    //    density — a ruined atmosphere, a pumped-dry water table, nuclear winter)
    //    plants die back. Rocks stay. Lower flora = faster die-off.
    if (flora < 0.4) {
      final biotic = scatter.entries
          .where((e) => bioticScatter.contains(ScatterKind.values[e.value]))
          .map((e) => e.key)
          .toList();
      if (biotic.isNotEmpty) {
        biotic.shuffle(math.Random());
        final kill = (1 + (0.4 - flora) * 10).round().clamp(1, 6);
        for (var i = 0; i < biotic.length && i < kill; i++) {
          scatter.remove(biotic[i]);
        }
      }
    }

    // 2) Regrowth: sprout new cover on cleared open land, up to the surface's
    //    supported density (which already scales with habitability).
    if (sc.density <= 0 || sc.kinds.isEmpty) return;
    final open = <int>[];
    for (var k = 0; k < grid * grid; k++) {
      if (cellOpen(k)) open.add(k);
    }
    if (open.isEmpty) return;
    final target = (open.length + scatter.length) * sc.density;
    if (scatter.length >= target) return;
    open.shuffle(math.Random());
    for (var i = 0; i < open.length && i < 3; i++) {
      scatter[open[i]] = scatterKindFor(open[i]);
    }
  }

  /// Open-style buildings need breathable ambient air. When the surface air is
  /// NOT breathable (raw hostile world, or a once-Earth atmosphere ruined by a
  /// nuke), any OPEN building that hasn't been retrofitted to a sealed (domed/
  /// orbital) style decompresses — after a short grace it is DESTROYED into
  /// rubble (not merely abandoned). Domed/orbital buildings ride it out.
  void decompressTick(double dt) {
    // Structural failure is for VACUUM/anoxia only — near-zero pressure or no
    // oxygen. Pollution (dirty but thick, oxygenated air) hurts health, not the
    // building, so it must NOT trigger demolition even when it makes the air
    // "un-breathable". Recover: when the air can hold structure, timers reset.
    if (!surface.vacuumHostile) {
      if (decompressTimer.isNotEmpty) decompressTimer.clear();
      return;
    }
    const grace = 12.0; // seconds of exposure before structural failure
    final doomed = <int>[];
    for (final anchor in [...grown, ...utils.keys]) {
      if (styleOf(anchor) != ColonyStyle.open.index) continue; // sealed = safe
      final t = (decompressTimer[anchor] ?? 0) + dt;
      if (t >= grace) {
        doomed.add(anchor);
      } else {
        decompressTimer[anchor] = t;
      }
    }
    for (final k in doomed) {
      decompressTimer.remove(k);
      flattenAt(k); // structural failure -> rubble
    }
  }

  /// Aquifer pumps draw the colony's water table DOWN; rain/snow + a water-rich
  /// biome recharge it. A falling table dries the surface (via surface's
  /// waterTable input → lower flora density → die-off), so over-pumping a forest
  /// or grassland slowly turns it to scrub. Bounded 0..1.
  void waterTableTick(double dt) {
    var pumps = 0;
    for (final e in activeSpecs) {
      if (e.value.type == 'aquifer') pumps++;
    }
    // Drawdown scales with pumps; recharge from natural seepage (faster on wet
    // biomes) + a big boost during rain/snow.
    final drawdown = pumps * 0.006 * dt;
    final raining =
        disaster == Disaster.rain || disaster == Disaster.snow ||
            disaster == Disaster.thunderstorm;
    final recharge =
        (biomeFx.water * 0.002 + (raining ? 0.02 : 0.0)) * dt;
    waterTable = (waterTable - drawdown + recharge).clamp(0.0, 1.0);
  }

  /// On orbital stations + floating colonies, a building whose footprint is no
  /// longer supported (its truss / lift-frame was removed) loses its anchor and
  /// is DESTROYED — it falls / drifts away. Surface colonies are unaffected.
  void supportTick() {
    if (!colonyNeedsSupport && !isOceanColony) return;
    final doomed = <int>[];
    for (final anchor in [...grown, ...utils.keys]) {
      final gx = anchor % grid, gy = anchor ~/ grid;
      final fw = specAt(anchor)?.footW ?? 1, fh = specAt(anchor)?.footH ?? 1;
      if (!footprintSupported(gx, gy, fw, fh)) doomed.add(anchor);
    }
    for (final k in doomed) {
      flattenAt(k);
    }
  }

  /// Biome multiplier on a produced commodity (food/water/ore boosted or hurt
  /// by terrain). Other commodities = 1.0.
  double biomeMult(String commodity) => switch (commodity) {
        // Nuclear winter freezes crops.
        Commodity.food => biomeFx.food * (1 - nuclearWinter * 0.7),
        Commodity.water => biomeFx.water,
        Commodity.ore => biomeFx.ore,
        _ => 1.0,
      };

  /// Planet-dependent multiplier on a power building's nameplate output: solar
  /// scales with sun distance, wind with air density; everything else = 1.0.
  double powerFactor(String type) => switch (type) {
        // Nuclear winter / heavy dust blots out the sun.
        'solar' => solarFactor * biomeFx.solar * (1 - nuclearWinter * 0.9),
        'wind' => windFactor,
        _ => 1.0,
      };

  // ---- Building enumeration ----

  CityBuildingSpec grownSpec(CityZoneType z) => kZoneSpecs[z.kind]![z.density]!;

  bool isConnected(int key) => connectedCells.contains(key);

  /// (key, spec) for every building that is connected + occupied (the economy).
  Iterable<MapEntry<int, CityBuildingSpec>> get activeSpecs sync* {
    for (final k in grown) {
      final z = zones[k];
      if (z != null && isConnected(k) && !abandoned.contains(k)) {
        yield MapEntry(k, grownSpec(z));
      }
    }
    for (final e in utils.entries) {
      if (isConnected(e.key) && !abandoned.contains(e.key)) yield e;
    }
  }

  /// 0..1 ramp for the disaster weather overlay so it fades IN at onset + OUT
  /// near the end instead of popping. Driven by how far through the event we are.
  double get weatherFade {
    if (disaster == Disaster.none) return 0;
    const ramp = 1.5; // seconds to fade in / out
    final dur = disaster.duration;
    final elapsed = dur - disasterTime; // counts up from 0
    final fadeIn = (elapsed / ramp).clamp(0.0, 1.0);
    final fadeOut = (disasterTime / ramp).clamp(0.0, 1.0);
    return math.min(fadeIn, fadeOut);
  }

  bool get hasSpaceport =>
      utils.entries.any((e) => e.value.type == 'spaceport' && isConnected(e.key));

  /// Honest one-word population trend for the status chip. Mirrors the pop
  /// step's target so the label matches what's actually happening: without a
  /// working spaceport the colony is stuck at its crew floor (no immigration),
  /// so it's 'stable', not 'growing'. With a spaceport it's growing toward the
  /// housing/happiness cap, shrinking past it, or stable at it.
  String get popTrend {
    final liveHousing = math.max(0.0, housing - corpses);
    final cap = liveHousing * (0.4 + 0.6 * happiness);
    final floor = (landerCrew + reliefCrew).toDouble();
    final target = (hasSpaceport ? math.max(cap, floor) : floor) * foodSecurity;
    if (!hasSpaceport) return 'stable'; // no immigration without a spaceport
    if (commsDown) return 'isolated'; // blackout halts arrivals
    const eps = 0.5;
    if (population < target - eps) return 'growing';
    if (population > target + eps) return 'shrinking';
    return 'stable';
  }

  /// True once the colony has built at least one spaceport — so if it later has
  /// none we can say it was DEMOLISHED rather than never built.
  bool everHadSpaceport = false;

  /// A spaceport exists somewhere but isn't road-connected to the hub.
  bool get spaceportDisconnected =>
      !hasSpaceport &&
      utils.values.any((s) => s.type == 'spaceport');

  /// Why there's no working spaceport, for the status readout.
  /// 0 = never built, 1 = built but disconnected, 2 = demolished (had one, now none).
  int get noSpaceportReason {
    if (spaceportDisconnected) return 1;
    if (everHadSpaceport) return 2;
    return 0;
  }


  double get stockCap {
    var cap = baseStockCap;
    for (final e in utils.entries) {
      if (isConnected(e.key)) cap += e.value.storageBonus;
    }
    return cap;
  }

  double stockOf(String c) => stock[c] ?? 0;

  double effectiveTax() => economy.taxControllable ? taxRate : 0.5;

  bool unlocked(CityBuildingSpec s) => ignoreUnlocks || population >= s.unlockPop;

  // --- Difficulty-derived modifiers ---
  /// Bounty: production rate multiplier. 0 -> 0.5×, 1 -> 2×.
  double get bountyMult => 0.5 + bounty * 1.5;

  /// Forgiveness: scales down the punishments (death + emigration rates). 0 ->
  /// harsh (×1.6), 1 -> gentle (×0.4).
  double get forgiveMult => 1.6 - forgiveness * 1.2;

  /// Whether a system is enabled at the current complexity level. Higher
  /// complexity unlocks more systems to manage.
  bool systemOn(double threshold) => complexity >= threshold;


  /// Advance the colony by [simDt] seconds of SIMULATION time.
  ///
  /// The caller owns pacing — the city screen multiplies by [timeWarp], the
  /// authoritative tick passes its own warped step — so a colony driven by the
  /// world and a colony driven by its screen do not each apply a different
  /// speed-up. What stays here is [eventSimWarp], because a time-dilation event
  /// is the colony's own physics, not a view setting.
  ///
  /// The clamp bounds a single step so a long frame hitch (or a backgrounded
  /// window resuming) cannot jump the economy forward by minutes in one
  /// integration.
  void advance(double simDt) {
    // eventSimWarp (set by a time-dilation event last tick) speeds/slows time.
    final dt = (simDt * eventSimWarp).clamp(0.0, 0.5);
    if (dt <= 0) return;

    // Day/night: advance the day phase by the body's rotation rate. A reference
    // Earth-day (~86400 s sidereal) is compressed to ~120 s of play; faster
    // spinners get proportionally shorter days, slow/tidELocked ones longer.
    const refDaySeconds = 120.0; // an Earth day, in real seconds of play
    final rot = body.siderealRotationPeriod.abs();
    final dayLen = rot <= 1 ? refDaySeconds : refDaySeconds * (rot / 86400.0);
    dayPhase = (dayPhase + dt / dayLen.clamp(20.0, 1200.0)) % 1.0;

    final active = activeSpecs.toList();

    // Aggregate power, compute, jobs, housing, services.
    powerOut = 0;
    powerDraw = 0;
    housing = 0;
    jobs = 0;
    computeSupply = 0;
    computeDemand = 0;
    services.clear();
    for (final e in active) {
      final s = e.value;
      // Grown zones contribute in proportion to their utilisation (small/med/
      // large/max). Still-under-construction cells contribute 0. Utils = full.
      final uf = utilFactor(e.key);
      powerOut += s.powerOutput * powerFactor(s.type);
      powerDraw += s.powerDraw * (s.housing > 0 || s.jobs > 0 ? uf : 1.0);
      housing += (s.housing * uf).round();
      jobs += (s.jobs * uf).round();
      computeSupply += s.computeOutput;
      computeDemand += s.computeDraw;
      s.services.forEach((k, v) => services[k] = (services[k] ?? 0) + v * uf);
    }
    // The lander itself is a tiny residential building: its crew live in the
    // capsule and count toward population, so a colony has a starter housing of
    // a few people from the moment it touches down — no spaceport needed yet.
    housing += landerCrew;
    final powerRatio = powerDraw <= 0 ? 1.0 : (powerOut / powerDraw).clamp(0.0, 1.0);
    final computeRatio =
        computeDemand <= 0 ? 1.0 : (computeSupply / computeDemand).clamp(0.0, 1.0);
    final workforce = math.min(population.floor(), jobs);
    // Staffing: a building runs at full only if the city has the workers. Global
    // staffing ratio = filled jobs / required jobs.
    // Commute efficiency: heavy road congestion means workers spend longer
    // travelling, so fewer effective worker-hours reach the jobs. Up to a 40%
    // staffing penalty at full gridlock.
    final commuteEff = 1 - congestion * 0.4;
    // Infinite Robotics: automated labour fills every job — buildings run at full
    // staffing with no workers (demo aid + foreshadows the endgame where robotics
    // + compute progressively replace human labour).
    final staffing = infiniteRobotics
        ? 1.0
        : (jobs <= 0 ? 1.0 : (workforce / jobs * commuteEff).clamp(0.0, 1.0));
    // Overall throttle on production = the weakest of power / compute / staffing.
    final throttle = math.min(powerRatio, math.min(computeRatio, staffing));
    // Stash for the UI (net-rate display + understaffed icons).
    this.staffing = staffing;
    this.throttle = throttle;

    // Medicine gates HEALTH service: hospitals/clinics consuming medicine only
    // deliver full health coverage when supplied. Scale the health service by
    // how well medicine demand is met (so running dry on medicine quietly
    // degrades health -> more disease).
    var medDemand = 0.0;
    for (final e in active) {
      medDemand += e.value.inputs[Commodity.medicine] ?? 0;
    }
    if (medDemand > 0) {
      final medCov =
          (stockOf(Commodity.medicine) / (medDemand + 0.01)).clamp(0.0, 1.0);
      services['health'] = (services['health'] ?? 0) * medCov;
    }

    // 1. Production: inputs drain, outputs fill, scaled by throttle. Skip a
    //    building's outputs if its inputs can't be met (no free lunch).
    var pollutionRate = 0.0;
    final emissionCut = has(Law.emissionsCap) ? 0.5 : 1.0;
    for (final e in active) {
      final s = e.value;
      // Can we afford this building's inputs this tick?
      var canRun = true;
      s.inputs.forEach((k, v) {
        if (stockOf(k) < v * throttle * dt) canRun = false;
      });
      final run = canRun ? throttle : 0.0;
      s.inputs.forEach(
          (k, v) => stock[k] = (stockOf(k) - v * run * dt).clamp(0, 1e12));
      s.outputs.forEach((k, v) => stock[k] = stockOf(k) +
          v * run * biomeMult(k) * bountyMult * eventProductionMult * dt);
      pollutionRate += s.pollution * (s.powerOutput > 0 ? 1 : run) * emissionCut;
    }

    // 1.4 Pollution accumulates (industry/power emit, parks + low activity decay).
    var parks = 0.0;
    for (final e in active) {
      parks += e.value.services['leisure'] ?? 0;
    }
    // Green decay (parks + a flat natural scrub + forests). A POSITIVE scrub
    // cleans the air; a negative one (volcanic) is a dirty BASELINE instead — it
    // shouldn't let pollution climb forever with nothing built. So:
    //  - clean biomes: decay air toward 0.
    //  - dirty biomes: hold a smog floor (scaled by how dirty) but no runaway.
    final scrub = biomeFx.scrub;
    final scrubDecay = (parks / 200 + 1.5 + math.max(0.0, scrub)) * dt;
    // OCEAN SINK: open water absorbs air pollution (gas exchange + runoff), and
    // it does so PROPORTIONALLY to how dirty the air is — so the more polluted,
    // the faster the sea scrubs it. This pins the equilibrium low: pollution
    // settles at ~emissions/sinkRate, so on a watery world (Earth) you'd need a
    // huge, map-filling industrial output to ever push toxicity up. A non-molten
    // sea only. Sink strength scales with how much of the map is water.
    final waterTiles =
        liquid.isMolten ? 0 : liquidTiles.length;
    final waterFrac = (waterTiles / (grid * grid)).clamp(0.0, 1.0);
    // Up to ~8%/s drain at a fully-oceanic map; a small lake still helps.
    final oceanSink = (0.02 + 0.6 * waterFrac).clamp(0.0, 0.9);
    final proportionalDrain = pollution * oceanSink * dt;
    // Dirty-biome baseline the smog settles AT (volcanic -1 -> ~20, volcano -2
    // -> ~40). Pollution eases toward it instead of accumulating without bound.
    final dirtyFloor = scrub < 0 ? -scrub * 20.0 : 0.0;
    var p = pollution - scrubDecay - proportionalDrain; // green + ocean scrub
    if (p < dirtyFloor) {
      // Below the biome's smog floor: relax UP toward it (slowly), not snap.
      p += (dirtyFloor - p) * (0.2 * dt).clamp(0.0, 1.0);
    }
    pollution = (p + pollutionRate * dt).clamp(0.0, 1e6);

    // Ocean pollution: heavy air pollution seeps into the surface liquid (runoff)
    // and lingers — it discolours the sea + degrades what the aquifer yields. It
    // creeps toward the current pollution level and decays slowly when clean.
    final oceanTarget = (pollution / 250).clamp(0.0, 1.0);
    oceanPollution = oceanPollution +
        (oceanTarget - oceanPollution) * (0.05 * dt).clamp(0.0, 1.0) -
        0.002 * dt;
    oceanPollution = oceanPollution.clamp(0.0, 1.0);

    // 1.5 Life support. Population eats food + drinks water. Food SECURITY is
    //     measured as how many SECONDS of runway the stockpile holds at the
    //     current consumption rate, mapped to 0..1 over a target runway. This is
    //     population-INDEPENDENT in shape, so it no longer snaps to "1.0" the
    //     instant population dips toward zero (the cause of the starve sawtooth):
    //     a small steady food import keeps a small population's runway high and
    //     stable instead of toggling the flag every frame.
    final foodPerSec = population * foodPerPersonPerSec;
    final waterPerSec = population * waterPerPersonPerSec;
    stock[Commodity.food] =
        (stockOf(Commodity.food) - foodPerSec * dt).clamp(0, 1e12);
    stock[Commodity.water] =
        (stockOf(Commodity.water) - waterPerSec * dt).clamp(0, 1e12);
    // Oxygen: FREE on breathable worlds (Earth); elsewhere the city must produce
    // it (electrolysis / atmospheric harvester) or shuttle it in, or the
    // population suffocates. We keep the stockpile topped on breathable worlds so
    // the security calc treats O2 as a non-constraint there.
    // Oxygen is a managed system only at COMPLEXITY >= 0.3 (and off breathable
    // worlds). Below that, life support ignores it for a gentler game.
    final o2Managed = systemOn(0.3) && !breathable;
    final o2PerSec = o2Managed ? population * waterPerPersonPerSec : 0.0;
    if (!o2Managed) {
      stock[Commodity.oxygen] = stockCap; // free / not tracked
    } else {
      stock[Commodity.oxygen] =
          (stockOf(Commodity.oxygen) - o2PerSec * dt).clamp(0, 1e12);
    }
    // Runway (seconds) = stock / consumption. With ~zero consumption (tiny pop)
    // any stock = effectively infinite runway -> full security, but it gets there
    // smoothly via the ease, not by a hard pop<=0 branch.
    const targetRunway = 30.0; // 30 s buffer = "secure"
    double runwaySec(double stock, double perSec) =>
        perSec < 1e-6 ? targetRunway : stock / perSec;
    final secTarget = [
      runwaySec(stockOf(Commodity.food), foodPerSec) / targetRunway,
      runwaySec(stockOf(Commodity.water), waterPerSec) / targetRunway,
      runwaySec(stockOf(Commodity.oxygen), o2PerSec) / targetRunway,
    ].map((v) => v.clamp(0.0, 1.0)).reduce(math.min);
    // Ease slowly so transient dips don't whip the flag.
    foodSecurity =
        (foodSecurity + (secTarget - foodSecurity) * (0.6 * dt).clamp(0.0, 1.0))
            .clamp(0.0, 1.0);
    // Wide hysteresis band: only declare starving when really empty (<0.12),
    // recover only when comfortably stocked (>0.6).
    if (foodSecurity < 0.12) {
      starved = true;
    } else if (foodSecurity > 0.6) {
      starved = false;
    }

    // 1.53 Waste: the population generates GARBAGE + SEWAGE; landfills /
    //      recyclers / sewage plants consume them (handled in the production
    //      loop). Whatever isn't processed PILES UP — a big backlog leaks
    //      pollution + disease + drags happiness. Only active at higher
    //      COMPLEXITY (one of the systems the player opts into).
    if (systemOn(0.5)) {
      stock[Commodity.garbage] = stockOf(Commodity.garbage) +
          population * garbagePerPersonPerSec * dt;
      stock[Commodity.sewage] = stockOf(Commodity.sewage) +
          population * sewagePerPersonPerSec * dt;
      wasteBacklog = population <= 0
          ? 0.0
          : ((stockOf(Commodity.garbage) + stockOf(Commodity.sewage)) /
                  (population * 2))
              .clamp(0.0, 1.0);
      pollution += wasteBacklog * 3 * dt; // rotting waste pollutes
    } else {
      wasteBacklog = 0;
    }

    // 1.55 Society + politics.
    socialTick(workforce, dt);

    // 1.51 Environment: disasters, radiation, nuclear winter, terraforming.
    envTick(dt);
    regrowScatter(dt); // natural cover slowly reclaims cleared land
    decompressTick(dt); // open buildings fail when the air turns hostile
    supportTick(); // unsupported buildings on stations/floating colonies fall
    reliefTick(dt); // relief craft animation + care-package grant
    fireTick(dt); // per-tile fires spread + are fought (outlive the disaster)
    waterTableTick(dt); // aquifer pumps draw the table down; rain recharges it
    // A molten lava lake (volcano biome) bakes the colony: extra pollution +
    // heat radiating off the surface. Bounded — it tops up the smog toward a
    // ceiling rather than climbing forever.
    if (liquid.isMolten && seaLevel > -1e8 && pollution < 60) {
      pollution += 1.5 * dt;
    }

    // 1.52 Mortality + deathcare. People die of HUNGER (low food security),
    //      DISEASE (poor health coverage + pollution + corpse backlog), and WAR
    //      (a small attrition while military bases operate). Deaths add to the
    //      CORPSE backlog; deathcare buildings process it. Unprocessed corpses
    //      breed disease + drag happiness — a feedback loop.
    final pop = population;
    // Disease: rises with weak health coverage, pollution, crowding, and a big
    // corpse pile; falls with hospitals. A small, healthy settlement looks after
    // itself — the "no hospital" penalty only bites once the population grows
    // past what the lander's own crew can manage (so the starter crew don't
    // sicken and die in a fed, clean colony). The unmet-health demand is the
    // population ABOVE that grace size that has no coverage.
    const healthGrace = 20.0; // people who need no formal healthcare
    final needHealth = math.max(0.0, pop - healthGrace);
    final uncovered = needHealth <= 0
        ? 0.0
        : (1 - ((services['health'] ?? 0) / needHealth)).clamp(0.0, 1.0);
    final corpseFrac = pop > 0 ? (corpses / pop).clamp(0.0, 1.0) : 0.0;
    final diseaseTarget = (0.35 * uncovered +
            0.2 * (pollution / 200).clamp(0.0, 1.0) +
            0.25 * corpseFrac +
            0.3 * radiation + // radiation sickness
            0.2 * wasteBacklog) // filth breeds disease
        .clamp(0.0, 1.0);
    disease = ease(disease, diseaseTarget, dt, 0.25);
    // Death rate (people/s). Only ACUTE radiation (above the harmless space
    // background) kills directly — a thin-atmosphere world's faint background
    // shouldn't quietly wipe out the starter crew.
    final radDeaths = pop * math.max(0.0, radiation - 0.25) * 0.013;
    final hungerDeaths = starved ? pop * 0.02 : 0.0;
    final diseaseDeaths = pop * disease * 0.01;
    var warDeaths = 0.0;
    for (final e in activeSpecs) {
      if (e.value.type == 'base' || e.value.type == 'airfield') {
        warDeaths += pop * 0.0008; // standing-army attrition
      }
    }
    deathRate =
        (hungerDeaths + diseaseDeaths + warDeaths + radDeaths) * forgiveMult;
    final died = deathRate * dt;
    population = (pop - died).clamp(0, double.infinity);
    corpses += died;
    // Deathcare processing.
    var careRate = 0.0;
    for (final e in activeSpecs) {
      careRate += e.value.deathcareRate;
    }
    corpses = (corpses - careRate * dt).clamp(0, double.infinity);

    // 1.6 Happiness. Pollution now also drags it.
    final coverage = serviceCoverage();
    final tax = effectiveTax();
    final pollutionDrag = (pollution / 200).clamp(0.0, 0.4);
    final corpseDrag = population > 0
        ? (corpses / population).clamp(0.0, 1.0) * 0.4
        : 0.0;
    final socialDrag = crime * 0.35 +
        inequality * 0.3 +
        (population > 0 ? (homeless / population).clamp(0.0, 1.0) : 0) * 0.4 +
        corruption * 0.2 +
        disease * 0.3 +
        wasteBacklog * 0.2 + // stinking streets
        corpseDrag +
        pollutionDrag;
    var happyTarget = starved
        ? 0.0
        : (coverage - tax * economy.taxHappinessPenalty - socialDrag +
                govt.happinessMod +
                lawHappiness() +
                transitBonus() +
                biomeFx.happy +
                eventHappyBonus) // festival/aurora cheer or cult/blackout gloom
            .clamp(economy.happinessFloor, 1.0);
    if (starved) happyTarget = 0.0;
    happiness =
        (happiness + (happyTarget - happiness) * (0.4 * dt).clamp(0.0, 1.0))
            .clamp(0.0, 1.0);

    // 1.7 Payoff: tax (funds) + research.
    final taxIncome = workforce *
        happiness *
        tax *
        taxPerWorkerPerSec *
        economy.fundsMult *
        (1 - corruption * 0.6);
    funds += (taxIncome + lawFundsRate()) * dt;
    research += population *
        happiness *
        researchPerPopPerSec *
        economy.researchMult *
        dt;

    // 2. Population: needs a spaceport; capped by housing × happiness × food
    //    SECURITY. Using the smooth security value (not the binary starved flag)
    //    as a continuous multiplier means a food shortfall gently lowers the
    //    sustainable population instead of toggling it to 0 and back (the cause
    //    of the thrash). Immigration/emigration both ease toward that target.
    // Unburied corpses still occupy their homes — that housing isn't free for
    // the living until deathcare clears them. So the sustainable LIVING
    // population is the housing capacity MINUS the corpse backlog (corpses don't
    // count toward population; they hold a slot until processed).
    final liveHousing = math.max(0.0, housing - corpses);
    final cap = liveHousing * (0.4 + 0.6 * happiness);
    // The lander always seeds its crew; relief settlers add to that floor; a
    // spaceport unlocks growth beyond them.
    final floor = (landerCrew + reliefCrew).toDouble();
    final target = (hasSpaceport ? math.max(cap, floor) : floor) * foodSecurity;
    // Migration BOTH ways needs a working (road-connected) spaceport — it's the
    // only way on or off the world. A comms blackout also halts arrivals.
    // Without a spaceport the colony is stuck with exactly its landed crew: no
    // immigration in, no emigration out (people can still DIE, handled above).
    if (hasSpaceport) {
      if (population < target && !commsDown) {
        population =
            (population + (1.5 + 3.0 * happiness) * dt).clamp(0, target);
      } else if (population > target) {
        // Leave faster the bigger the shortfall, but bounded so it can't whip.
        final shortfall = (1 - foodSecurity);
        final leaveRate =
            (1.0 + (1 - happiness) * 1.5 + shortfall * 2.0) * forgiveMult;
        population =
            (population - leaveRate * dt).clamp(target, double.infinity);
      }
    }

    // 3. RCI demand eases toward targets (no sawtooth).
    final jobsD = jobs.toDouble();
    final housingD = housing.toDouble();
    // DEBUG infinite demand: pin every RCI target to max so zones always grow.
    final rTgt = infiniteDemand
        ? 1.0
        : (hasSpaceport ? (0.2 + (jobsD - housingD) / 120).clamp(0.1, 1.0) : 0.0);
    final leisure = services['leisure'] ?? 0;
    final cTgt = infiniteDemand
        ? 1.0
        : (population > 0 ? (1 - leisure / population).clamp(0.0, 1.0) : 0.0);
    final iTgt = infiniteDemand
        ? 1.0
        : (population > 0 ? (population / 500).clamp(0.0, 1.0) : 0.0);
    double easeDemand(double cur, double tgt) =>
        cur + (tgt - cur) * (dt * 1.2).clamp(0.0, 1.0);
    resTarget = easeDemand(resTarget, rTgt);
    comTarget = easeDemand(comTarget, cTgt);
    indTarget = easeDemand(indTarget, iTgt);

    // 4. Growth: connected un-grown zoned tile grows once demand clears threshold
    //    and there's ore. (Density of the zone sets the grown spec.)
    var built = 0;
    for (final e in zones.entries) {
      final k = e.key;
      if (grown.contains(k) || !isConnected(k)) continue;
      if (built >= 2) break;
      if (demandFor(e.value.kind) > growThreshold &&
          stockOf(Commodity.ore) >= zoneBuildCost) {
        grown.add(k);
        buildStyle[k] = currentStyle.index; // capture the build style
        growProgress[k] = 0; // starts under construction
        abandonTimer[k] = 0;
        stock[Commodity.ore] = stockOf(Commodity.ore) - zoneBuildCost;
        built++;
      }
    }

    // 4b. Construction + utilisation ramp. Each grown, healthy zone cell builds
    //     up (through the construction phase) then fills toward an occupancy
    //     target set by its demand — so a building gradually grows small -> max
    //     when wanted, and slowly empties (shrinks utilisation) when demand dies.
    for (final k in grown) {
      final z = zones[k];
      if (z == null) continue;
      final p = growProgress[k] ?? 1.0;
      // "Healthy" drives the occupancy target — so it must use the DELAYED
      // abandoned flag, NOT the raw instantaneous powerRatio. A borderline power
      // ratio (hovering near the cutoff) would otherwise flip the target between
      // full and empty every tick, jittering the building's height. Sustained
      // failure already trips abandoned (with a grace delay) below.
      final healthy = isConnected(k) && !abandoned.contains(k);
      // Occupancy target: full while still building (so it always finishes),
      // then tracks demand once occupied. Unhealthy cells decay to empty.
      // A FINISHED building never sits exactly at constructFrac (the
      // construction<->built render boundary) — it's floored a little above it,
      // so float jitter can't flip it between scaffold and box ("bouncing").
      const occupiedFloor = constructFrac + 0.08;
      final demand = demandFor(z.kind);
      final target = !healthy
          ? 0.0
          : (p <= constructFrac
              ? 1.0
              : (occupiedFloor + (1 - occupiedFloor) * demand)
                  .clamp(occupiedFloor, 1.0));
      // Construction is brisk; utilisation grows/shrinks more slowly.
      final rate = p <= constructFrac ? 0.35 : 0.12;
      final step = (rate * dt).clamp(0.0, 1.0);
      growProgress[k] =
          (p + (target - p).clamp(-step, step)).clamp(0.0, 1.0);
    }

    // 5. Abandonment on infrastructure failure (disconnect / unpowered).
    final removed = <int>[];
    for (final k in grown) {
      if (zones[k] == null) {
        removed.add(k);
        continue;
      }
      final failed = !isConnected(k) || powerRatio < 0.35;
      if (failed) {
        abandonTimer[k] = (abandonTimer[k] ?? 0) + dt;
        if ((abandonTimer[k] ?? 0) >= abandonDelay) abandoned.add(k);
      } else {
        abandonTimer[k] = 0;
        abandoned.remove(k);
      }
    }
    for (final k in removed) {
      grown.remove(k);
      abandoned.remove(k);
      abandonTimer.remove(k);
      growProgress.remove(k);
    }

    // 6. Storage cap.
    final sc = stockCap;
    for (final t in stock.keys.toList()) {
      if (stockOf(t) > sc) stock[t] = sc;
    }

    // DEBUG infinite resources: top every input commodity back up so nothing
    // ever runs dry. Production/consumption (and thus the displayed rates) still
    // happen above this; this only refills the tanks. Waste backlogs are left
    // alone so the colony still has something to manage.
    if (infiniteRes) {
      for (final c in Commodity.ordered) {
        if (c == Commodity.garbage || c == Commodity.sewage) continue;
        stock[c] = sc;
      }
    }
  }

  double demandFor(String kind) => switch (kind) {
        'residential' => resTarget,
        'commercial' => comTarget,
        _ => indTarget,
      };

  // --- Zone utilisation / construction ---
  static const double constructFrac = 0.3; // progress below this = building

  /// Occupancy fraction (0..1) of a grown zone cell: ramps in only AFTER the
  /// construction phase. Utils are always 1.0 (no construction model for them).
  double utilFactor(int k) {
    if (!grown.contains(k)) return 1.0;
    final p = growProgress[k] ?? 1.0;
    if (p <= constructFrac) return 0.0; // still under construction
    return ((p - constructFrac) / (1 - constructFrac)).clamp(0.0, 1.0);
  }

  /// True while a grown zone cell is still being built (scaffold render, no
  /// economic output yet).
  bool underConstruction(int k) =>
      grown.contains(k) && (growProgress[k] ?? 1.0) <= constructFrac;

  /// Utilisation stage name for a grown zone cell (UI / tooltips).
  String utilStage(int k) {
    if (underConstruction(k)) return 'Building';
    final u = utilFactor(k);
    if (u < 0.3) return 'Small';
    if (u < 0.6) return 'Medium';
    if (u < 0.9) return 'Large';
    return 'Max';
  }

  bool has(Law l) => laws.contains(l);

  /// Transit relieves commuting: each connected transit stop serves ~150 people;
  /// full coverage gives a happiness bonus (cheaper commutes, less congestion).
  double transitBonus() {
    final stops = utils.entries
        .where((e) => e.value.type == 'transit' && isConnected(e.key))
        .length;
    if (stops == 0 || population <= 0) return 0;
    final coverage = (stops * 150 / population).clamp(0.0, 1.0);
    return coverage * 0.1; // up to +10% happiness at full transit coverage
  }

  double lawHappiness() {
    var h = 0.0;
    if (has(Law.freeHealthcare)) h += 0.12;
    if (has(Law.freePublicTransit)) h += 0.08;
    if (has(Law.homelessShelters)) h += 0.05;
    if (has(Law.curfew)) h -= 0.06;
    if (has(Law.industrialSubsidy)) h -= 0.05;
    if (has(Law.wealthTax)) h -= 0.04;
    if (has(Law.robotTax)) h += 0.06; // UBI cushions the displaced
    return h;
  }

  double lawFundsRate() {
    final scale = (population / 100).clamp(0.2, 5.0);
    var f = 0.0;
    if (has(Law.freeHealthcare)) f -= 0.6 * scale;
    if (has(Law.freePublicTransit)) f -= 0.5 * scale;
    if (has(Law.homelessShelters)) f -= 0.4 * scale;
    if (has(Law.antiCorruption)) f -= 0.5 * scale;
    if (has(Law.wealthTax)) f += 0.8 * scale;
    if (has(Law.industrialSubsidy)) f -= 0.3 * scale;
    if (has(Law.robotTax)) f -= 0.5 * scale; // UBI payouts cost the treasury
    return f;
  }

  void socialTick(int workforce, double dt) {
    final pop = population;
    homeless = math.max(0, (pop - housing)).round();
    final homelessFrac = pop > 0 ? (homeless / pop).clamp(0.0, 1.0) : 0.0;
    final shelterRelief = has(Law.homelessShelters) ? 0.5 : 1.0;
    // Automation displaces labour: with Infinite Robotics, machines fill the
    // jobs people would have worked, so human unemployment climbs unless the
    // state shares the gains (a Robot Tax / UBI softens it). This is the
    // political cost of automation — inequality + unrest if left unaddressed.
    final autoDisplaced =
        infiniteRobotics ? (1.0 - (has(Law.robotTax) ? 0.6 : 0.0)) : 0.0;
    final unemployedFrac = pop > 0
        ? math.max(((pop - workforce) / pop).clamp(0.0, 1.0), autoDisplaced)
        : 0.0;
    final safety = services['safety'] ?? 0;
    final safetyCov = pop > 0 ? (safety / pop).clamp(0.0, 1.0) : 1.0;
    var crimeTarget = (0.5 * unemployedFrac +
            0.4 * homelessFrac * shelterRelief +
            0.3 * (1 - safetyCov))
        .clamp(0.0, 1.0);
    if (has(Law.curfew)) crimeTarget *= 0.6;
    crime = ease(crime, crimeTarget, dt, 0.5);

    var corrTarget =
        (govt.corruptionBase + (pop / 1500).clamp(0.0, 0.4)).clamp(0.0, 1.0);
    if (has(Law.antiCorruption)) corrTarget *= 0.4;
    corruption = ease(corruption, corrTarget, dt, 0.3);

    final tax = effectiveTax();
    var ineqTarget = (0.4 * unemployedFrac +
            0.3 * corruption +
            0.3 * (tax * (1 - serviceCoverage())))
        .clamp(0.0, 1.0);
    if (has(Law.wealthTax)) ineqTarget *= 0.5;
    inequality = ease(inequality, ineqTarget, dt, 0.3);

    if (govt.lawsAutoVoted) autoVote();

    final unrest = (0.5 * (1 - happiness) +
            0.2 * crime +
            0.2 * inequality +
            0.1 * corruption) *
        govt.rebellionSensitivity;
    rebellion =
        (rebellion + (unrest - 0.4 - rebellion) * 0.15 * dt).clamp(0.0, 1.0);
    if (rebellion >= 1.0 && pop > 0) {
      final lost = (pop * 0.3).round();
      population = (pop - lost).clamp(0, double.infinity);
      funds *= 0.6;
      rebellion = 0.3;
      revoltMsg =
          'REVOLT! $lost citizens fled, treasury raided. Fix crime, inequality + happiness.';
    }
  }

  void autoVote() {
    // Hysteresis: enact a law once a metric crosses the HIGH threshold, repeal
    // it only when it drops back below a LOWER one. Without the dead band a law
    // that fixes the very metric it reacts to (curfew lowers crime, which then
    // repeals the curfew, which lets crime climb again) flip-flops forever.
    void band(Law l, double value, double onAt, double offAt) {
      if (laws.contains(l)) {
        if (value < offAt) laws.remove(l);
      } else {
        if (value > onAt) laws.add(l);
      }
    }

    band(Law.homelessShelters, population > 0 ? homeless / population : 0,
        0.10, 0.04);
    band(Law.freeHealthcare, 1 - happiness, 0.55, 0.40); // low happiness -> on
    band(Law.antiCorruption, corruption, 0.40, 0.25);
    band(Law.curfew, crime, 0.50, 0.30);
    band(Law.wealthTax, inequality, 0.50, 0.35);
    band(Law.emissionsCap, pollution, 120, 80);
    band(Law.freePublicTransit, population.toDouble(), 200, 150);
    // Voters demand a robot tax / UBI once automation drives unemployment up.
    band(Law.robotTax, infiniteRobotics ? inequality : 0.0, 0.45, 0.25);
  }

  double ease(double cur, double tgt, double dt, double rate) =>
      cur + (tgt - cur) * (rate * dt).clamp(0.0, 1.0);

  /// Count connected terraformers (utility type 'terraformer').
  int get terraformers => utils.entries
      .where((e) => e.value.type == 'terraformer' && isConnected(e.key))
      .length;

  int countUtil(String type) => utils.entries
      .where((e) => e.value.type == type && isConnected(e.key))
      .length;

  /// Disaster severity multiplier (<1 = better protected). Emergency services +
  /// bunkers cut the harm; floors at 0.3.
  double get mitigate {
    final prep = countUtil('emergency') * 0.15 + countUtil('bunker') * 0.08;
    return (1 - prep).clamp(0.3, 1.0);
  }

  bool get hasWarning => countUtil('warning') > 0;

  /// Environment tick: disasters, radiation, nuclear winter, terraforming.
  /// Whether the host body has a real (weather-bearing) atmosphere — required
  /// for wind/precip-type events. Airless/near-vacuum worlds get no weather.
  bool get hasWeatherAir => (body.atmosphere?.seaLevelDensity ?? 0) > 0.05;

  // --- World-condition flags driving the exotic, condition-based disasters. ---
  /// Scorching world (close to the Sun / runaway greenhouse) — Venus, Mercury.
  bool get isHot => solarFactor > 1.6 || (co2Fraction > 0.5 && hasWeatherAir);
  /// Cryogenic world (very far from the Sun, icy) — outer moons, Pluto-likes.
  bool get isFrozen => solarFactor < 0.15;
  /// Hydrogen/methane/ammonia-rich reducing atmosphere — gas/ice giants & moons.
  bool get hasReducingAtmo {
    final f = body.composition?.fractions;
    if (f == null) return false;
    return (f[AtmosphereGas.hydrogen] ?? 0) +
            (f[AtmosphereGas.methane] ?? 0) >
        0.2;
  }
  double get co2Fraction =>
      body.composition?.fractions[AtmosphereGas.carbonDioxide] ?? 0;
  /// Tectonically/volcanically active — quakes + ground hazards.
  bool get isTectonic =>
      biome == Biome.volcanic || biome == Biome.mountains;
  /// Magnetosphere shielding (airless + no field = bathed in radiation).
  bool get isUnshielded =>
      (body.dipoleMoment <= 0) && !hasWeatherAir;

  /// Earth + its moons (Luna): the home system. We keep this grounded — only
  /// real-world disasters here; the exotic/sci-fi events are reserved for the
  /// stranger worlds out in the rest of the solar system.
  bool get inEarthSystem =>
      body.id.value == 'earth' || body.parent?.value == 'earth';

  /// The fantastical / hard-sci-fi events that should NOT occur in the Earth
  /// system (they need exotic worlds + chemistry, or are pure sci-fi).
  static const Set<Disaster> exoticDisasters = {
    Disaster.glassRain,
    Disaster.ammoniaStorm,
    Disaster.cryovolcanism,
    Disaster.diamondRain,
    Disaster.methaneDownpour,
    Disaster.grayGoo,
    Disaster.crawlingForest,
    Disaster.rollingGlitch,
    Disaster.timeDilation,
    Disaster.skyCrack,
    Disaster.gammaRayBurst,
    Disaster.alienBeacon,
    Disaster.glitchInMatrix,
    Disaster.crystalGrowth,
    Disaster.sporeBloom,
  };

  /// True if a disaster is physically plausible on the CURRENT planet + biome.
  /// Airless worlds get no wind/rain; deserts don't snow; oceans don't burn, etc.
  bool disasterPossible(Disaster d) {
    // In the Earth system, exotic/sci-fi events are off the table.
    if (inEarthSystem && exoticDisasters.contains(d)) return false;
    final cold = biome == Biome.iceCap ||
        biome == Biome.tundra ||
        biome == Biome.mountains;
    final wet = biome == Biome.ocean ||
        biome == Biome.grassland ||
        biome == Biome.forest ||
        biome == Biome.tundra ||
        biome == Biome.wetland ||
        biome == Biome.coastal;
    final dusty = biome == Biome.desert ||
        biome == Biome.barren ||
        biome == Biome.volcanic ||
        biome == Biome.volcano ||
        biome == Biome.mountains;
    return switch (d) {
      Disaster.none => false,
      // Precip needs air + moisture.
      Disaster.rain || Disaster.thunderstorm => hasWeatherAir && wet,
      Disaster.snow => hasWeatherAir && cold,
      // Wind events need an atmosphere.
      Disaster.dustStorm => hasWeatherAir && dusty,
      Disaster.tornado => hasWeatherAir && !cold,
      // Fire needs oxygen + something to burn (not ocean/ice).
      Disaster.fire =>
        breathable && biome != Biome.ocean && biome != Biome.iceCap,
      // Crops to fail anywhere people farm.
      Disaster.famine => true,
      // Outbreaks need people (always possible once populated).
      Disaster.plague => true,
      // Space hazards — worse with a thin/absent atmosphere, possible anywhere.
      Disaster.meteorShower || Disaster.solarStorm => true,
      // War: always possible.
      Disaster.nuke => true,
      // Hurricane: big warm-ocean storm — needs thick air + a wet/ocean world.
      Disaster.hurricane =>
        hasWeatherAir && (biome == Biome.ocean || biome == Biome.grassland),
      // Blizzard: extreme snow — cold biome OR a frozen world, with air.
      Disaster.blizzard => hasWeatherAir && (cold || isFrozen),
      // Fog: any world with a real atmosphere.
      Disaster.fog => hasWeatherAir,
      // Acid rain: sulphur/CO2 haze — Venus-like or polluted thick atmospheres.
      Disaster.acidRain =>
        hasWeatherAir && (co2Fraction > 0.3 || pollution > 40),
      // Earthquake: volcanic/tectonic ground (no atmosphere required).
      Disaster.earthquake => isTectonic,
      // Radiation storm: unshielded worlds (no magnetosphere + thin air) or near
      // a flaring sun.
      Disaster.radiationStorm => isUnshielded || solarFactor > 1.3,
      // Glass rain: molten-silicate rain on scorching rocky worlds.
      Disaster.glassRain => isHot && !hasReducingAtmo,
      // Ammonia storm: hydrogen/methane/ammonia chemistry (giant-moon worlds).
      Disaster.ammoniaStorm => hasReducingAtmo,
      // Cryovolcanism: water/ammonia volcanism on frozen icy bodies.
      Disaster.cryovolcanism => isFrozen,
      // Miasma: rises from unburied bodies — only when the corpse backlog is high.
      Disaster.miasma => corpses > 3,
      // --- Wave 2 ---
      // Moving fronts, mostly world-gated.
      Disaster.lavaFlow => biome == Biome.volcanic || isHot,
      Disaster.sandworm => biome == Biome.desert || biome == Biome.barren,
      Disaster.grayGoo => true, // nanites anywhere
      Disaster.crawlingForest =>
        biome == Biome.forest || biome == Biome.grassland || biome == Biome.ocean,
      Disaster.rollingGlitch => true, // sim glitch — anywhere
      // Cosmic — anywhere, but bursts/eclipses make sense everywhere.
      Disaster.auroraBloom => true,
      Disaster.eclipse => true,
      Disaster.gammaRayBurst => true,
      Disaster.fallingStar => true,
      Disaster.skyCrack => true,
      Disaster.timeDilation => true,
      // Bio / matter.
      Disaster.sporeBloom =>
        biome == Biome.forest || biome == Biome.grassland || hasWeatherAir,
      Disaster.crystalGrowth => true,
      Disaster.biolumTide => biome == Biome.ocean,
      Disaster.chemicalRain => hasWeatherAir,
      // Exotic precip — strongly per-world.
      Disaster.diamondRain => hasReducingAtmo, // ice/gas-giant chemistry
      Disaster.ironSnow => isHot,
      Disaster.methaneDownpour => hasReducingAtmo && isFrozen, // Titan-like
      Disaster.bloodRain => hasWeatherAir && (biome == Biome.desert ||
          biome == Biome.barren || biome == Biome.volcanic),
      Disaster.blackRain => hasWeatherAir && radiation > 0.2, // fallout
      // Meta — society events, possible anywhere with people.
      Disaster.commsBlackout => true,
      Disaster.goldRush => true,
      Disaster.refugeeInflux => hasSpaceport,
      Disaster.festival => true,
      Disaster.cultUprising => true,
      Disaster.aiAwakening => computeSupply > 20,
      Disaster.marketCrash => true,
      // Wildcards.
      Disaster.alienBeacon => true,
      Disaster.rainingFrogs => hasWeatherAir,
      Disaster.glitchInMatrix => lastDisaster != Disaster.none,
    };
  }

  /// Which disasters can strike at the current hostility — mild weather at low
  /// hostility, escalating to catastrophes at high — filtered to those that make
  /// sense on the current planet + biome.
  List<Disaster> hostilityPool() {
    final pool = <Disaster>[
      // Benign / mild — always in the mix (most filter out as impossible).
      Disaster.rain,
      Disaster.snow,
      Disaster.thunderstorm,
      Disaster.dustStorm,
      Disaster.fog,
      Disaster.acidRain,
      // Exotic but condition-gated, so safe to always offer.
      Disaster.glassRain,
      Disaster.ammoniaStorm,
      Disaster.cryovolcanism,
      Disaster.miasma, // gated on corpse backlog
      // Wave 2: benign + positive + condition-gated flavour (mostly low-weight).
      Disaster.auroraBloom,
      Disaster.fallingStar,
      Disaster.biolumTide,
      Disaster.festival,
      Disaster.goldRush,
      Disaster.eclipse,
      Disaster.diamondRain,
      Disaster.ironSnow,
      Disaster.methaneDownpour,
      Disaster.bloodRain,
      Disaster.blackRain,
      Disaster.chemicalRain,
      Disaster.crystalGrowth,
      Disaster.sporeBloom,
      Disaster.rainingFrogs,
      Disaster.commsBlackout,
      Disaster.refugeeInflux,
      Disaster.timeDilation,
      Disaster.rollingGlitch,
      Disaster.alienBeacon,
    ];
    if (hostility > 0.35) {
      pool.addAll([
        Disaster.fire,
        Disaster.tornado,
        Disaster.famine,
        Disaster.blizzard,
        Disaster.earthquake,
        Disaster.lavaFlow,
        Disaster.sandworm,
        Disaster.cultUprising,
        Disaster.marketCrash,
      ]);
    }
    if (hostility > 0.6) {
      pool.addAll([
        Disaster.plague,
        Disaster.solarStorm,
        Disaster.meteorShower,
        Disaster.hurricane,
        Disaster.radiationStorm,
        Disaster.grayGoo,
        Disaster.crawlingForest,
        Disaster.skyCrack,
        Disaster.aiAwakening,
      ]);
    }
    if (hostility > 0.85) {
      pool.addAll([Disaster.nuke, Disaster.gammaRayBurst]);
    }
    // Glitch in the Matrix can sneak in once there's a prior disaster to repeat.
    if (lastDisaster != Disaster.none) pool.add(Disaster.glitchInMatrix);
    final filtered = pool.where(disasterPossible).toList();
    // Fall back to space hazards if nothing weather-y fits (e.g. airless world).
    return filtered.isEmpty ? [Disaster.meteorShower] : filtered;
  }

  /// Relative likelihood of a disaster GIVEN it's already possible here. Weights
  /// by the real environment: solar storms scale with proximity to the Sun + a
  /// thin atmosphere (less shielding); meteors with a thin atmosphere (less
  /// burn-up); dust storms dominate deserts; fire favours hot/dry O₂-rich worlds;
  /// snow the cold biomes; rain the wet ones; plague with crowding; famine on
  /// barren ground. 1.0 = baseline.
  double disasterWeight(Disaster d) {
    // Atmosphere shielding: 1 (airless) -> 0 (thick air).
    final airThin = 1 - windFactor.clamp(0.0, 1.0);
    final hot = biome == Biome.desert || biome == Biome.volcanic;
    final cold = biome == Biome.iceCap ||
        biome == Biome.tundra ||
        biome == Biome.mountains;
    final wet = biome == Biome.ocean ||
        biome == Biome.grassland ||
        biome == Biome.forest ||
        biome == Biome.wetland ||
        biome == Biome.coastal;
    final dusty = biome == Biome.desert ||
        biome == Biome.barren ||
        biome == Biome.volcanic ||
        biome == Biome.volcano;
    final crowding = housing <= 0 ? 0.0 : (population / housing).clamp(0.0, 1.0);
    return switch (d) {
      // Closer to the Sun (solarFactor up) + thin air => far more solar storms.
      Disaster.solarStorm => 0.4 + solarFactor * 1.2 + airThin * 1.5,
      // Less air = meteors reach the ground instead of burning up.
      Disaster.meteorShower => 0.4 + airThin * 2.0,
      Disaster.dustStorm => dusty ? 3.0 : 0.6,
      Disaster.fire => (hot ? 2.5 : 1.0) * (breathable ? 1.5 : 0.3),
      Disaster.snow => cold ? 2.5 : 0.5,
      Disaster.rain || Disaster.thunderstorm => wet ? 2.0 : 0.6,
      // Crops fail more readily on poor ground.
      Disaster.famine =>
        (biomeFx.food < 1.0 ? 2.0 : 0.8) * (1 + nuclearWinter),
      // Outbreaks scale with how crowded the housing is.
      Disaster.plague => 0.5 + crowding * 2.0,
      Disaster.tornado => wet ? 1.5 : 1.0,
      Disaster.nuke => 1.0,
      // Benign weather is common where conditions allow.
      Disaster.fog => hasWeatherAir ? 1.5 : 0.0,
      Disaster.acidRain => co2Fraction > 0.3 ? 2.0 : 0.8,
      // Escalations are rarer than their base weather.
      Disaster.hurricane => wet ? 1.2 : 0.3,
      Disaster.blizzard => cold ? 1.8 : 0.4,
      Disaster.earthquake => isTectonic ? 2.0 : 0.2,
      // Condition-based exotics — strongly favoured where they fit.
      Disaster.radiationStorm => 0.5 + solarFactor + airThin * 1.0,
      Disaster.glassRain => isHot ? 2.5 : 0.2,
      Disaster.ammoniaStorm => hasReducingAtmo ? 2.5 : 0.2,
      Disaster.cryovolcanism => isFrozen ? 2.0 : 0.2,
      // Likelier the more bodies pile up (corpses per 100 pop).
      Disaster.miasma =>
        population <= 0 ? 0.0 : (corpses / population * 100).clamp(0.0, 4.0),
      // --- Wave 2: most are rare flavour (low base weight) so they sprinkle in. ---
      Disaster.lavaFlow => biome == Biome.volcanic ? 2.0 : 0.5,
      Disaster.sandworm => biome == Biome.desert ? 1.5 : 0.6,
      Disaster.grayGoo => 0.4,
      Disaster.crawlingForest => biome == Biome.forest ? 1.5 : 0.5,
      Disaster.rollingGlitch => 0.3,
      Disaster.auroraBloom => 0.8,
      Disaster.eclipse => 0.6,
      Disaster.gammaRayBurst => 0.15,
      Disaster.fallingStar => 0.5,
      Disaster.skyCrack => 0.3,
      Disaster.timeDilation => 0.3,
      Disaster.sporeBloom => biome == Biome.forest ? 1.5 : 0.5,
      Disaster.crystalGrowth => 0.5,
      Disaster.biolumTide => 1.0,
      Disaster.chemicalRain => 0.6,
      Disaster.diamondRain => 0.6,
      Disaster.ironSnow => 0.8,
      Disaster.methaneDownpour => 1.0,
      Disaster.bloodRain => 0.5,
      Disaster.blackRain => radiation > 0.2 ? 1.5 : 0.0,
      Disaster.commsBlackout => 0.5,
      Disaster.goldRush => 0.6,
      Disaster.refugeeInflux => 0.5,
      Disaster.festival => 0.7,
      Disaster.cultUprising => 0.3 + rebellion,
      Disaster.aiAwakening => 0.2,
      Disaster.marketCrash => 0.4,
      Disaster.alienBeacon => 0.25,
      Disaster.rainingFrogs => 0.3,
      Disaster.glitchInMatrix => 0.1,
      Disaster.none => 0.0,
    };
  }

  /// Weighted random pick from the eligible pool using [disasterWeight].
  Disaster pickDisaster(List<Disaster> pool) {
    final weights = [for (final d in pool) math.max(0.01, disasterWeight(d))];
    final total = weights.fold(0.0, (a, b) => a + b);
    var r = math.Random().nextDouble() * total;
    for (var i = 0; i < pool.length; i++) {
      r -= weights[i];
      if (r <= 0) return pool[i];
    }
    return pool.last;
  }

  void envTick(double dt) {
    // --- Auto-disasters (driven by HOSTILITY) ---
    if (hostility > 0.02 && disaster == Disaster.none && population > 5) {
      autoDisasterTimer -= dt;
      if (autoDisasterTimer <= 0) {
        // Calm spell between strikes — target roughly ONE disaster per ~30 min
        // of sim time. Higher hostility shortens it (down to ~15 min at max),
        // plus a random spread; there's always a generous floor so the colony
        // gets long clear stretches to recover.
        autoDisasterTimer =
            (1800 - hostility * 900) + math.Random().nextDouble() * 600;
        final pool = hostilityPool();
        disaster = pickDisaster(pool); // weighted by planet + biome
        disasterTime = disaster.duration;
        initStormTrack();
        onDisasterStart();
      }
    }

    // --- Active disaster ---
    // Event modifiers are transient — reset to neutral each tick and re-apply
    // below for whatever event is running.
    eventProductionMult = 1.0;
    eventHappyBonus = 0.0;
    eventSimWarp = 1.0;
    commsDown = false;
    if (disaster != Disaster.none) {
      disasterTime -= dt;
      switch (disaster) {
        case Disaster.rain:
          stock[Commodity.water] = stockOf(Commodity.water) + 3 * dt; // refill
        case Disaster.snow:
          stock[Commodity.water] = stockOf(Commodity.water) + 1.5 * dt;
        case Disaster.thunderstorm:
          stock[Commodity.water] = stockOf(Commodity.water) + 2 * dt;
          damageBuildings(0.006, dt); // genuinely RARE lightning strike
        case Disaster.fire:
          // ONE blaze is lit at the start (onDisasterStart); it spreads on its
          // own (fireTick). The event is over the moment every fire is out —
          // whether burned through, contained by roads, or put out by emergency
          // services.
          pollution += 1 * dt;
          if (fires.isEmpty) disasterTime = 0; // all fires gone -> event ends
        case Disaster.tornado:
          // A tornado wanders VERY slowly across the map; once it drifts off the
          // edge the disaster is over (handled by the shared off-map check).
          moveStorm(dt, 0.4);
          damageNearStorm(0.6, dt, 1.4); // only hits buildings near the funnel
        case Disaster.hurricane:
          moveStorm(dt, 1.6);
          stock[Commodity.water] = stockOf(Commodity.water) + 2 * dt;
          damageNearStorm(0.5, dt, 3.0); // wider eye, slower
        case Disaster.blizzard:
          stock[Commodity.water] = stockOf(Commodity.water) + 1.0 * dt;
          // Heavy cold strains the colony: a little extra emigration.
          population = (population - population * 0.002 * dt * forgiveMult)
              .clamp(0, 1e9);
        case Disaster.fog:
          break; // benign — just reduced visibility (visual only)
        case Disaster.acidRain:
          // Corrodes a little — light pollution + a trickle of building wear.
          pollution += 1.5 * dt;
          damageBuildings(0.02, dt);
        case Disaster.earthquake:
          // Sharp ground shaking: brief but flattens structures.
          damageBuildings(0.35, dt);
        case Disaster.radiationStorm:
          radiation = (radiation + 0.3 * dt * mitigate).clamp(0.0, 1.0);
        case Disaster.glassRain:
          // Molten silicate shards: pollution + steady building damage.
          pollution += 2 * dt;
          damageBuildings(0.06, dt);
        case Disaster.ammoniaStorm:
          // Toxic reducing-atmo storm: pollution + mild casualties.
          pollution += 2 * dt;
          population = (population - population * 0.002 * dt * mitigate)
              .clamp(0, 1e9);
        case Disaster.cryovolcanism:
          // Cryolava + venting: water gain but pollution + some damage.
          stock[Commodity.water] = stockOf(Commodity.water) + 1.5 * dt;
          damageBuildings(0.04, dt);
        case Disaster.miasma:
          // Decay gas from corpses: disease climbs (scaled by the backlog) +
          // pollution; clears when deathcare catches up. Drives a little death.
          final load = population <= 0
              ? 0.5
              : (corpses / population * 20).clamp(0.2, 1.0);
          disease = (disease + 0.08 * load * dt * mitigate).clamp(0.0, 1.0);
          pollution += 1.5 * load * dt;
          population = (population - population * 0.004 * load * dt * mitigate)
              .clamp(0, 1e9);
        case Disaster.meteorShower:
          damageBuildings(0.08, dt);
          population = (population - population * 0.003 * dt).clamp(0, 1e9);
        case Disaster.dustStorm:
          pollution += 3 * dt; // sky dims (cuts solar via pollution path)
        case Disaster.nuke:
          // One-shot devastation: huge radiation + nuclear winter, mass casualty,
          // buildings flattened, fires.
          radiation = (radiation + 0.5 * dt / Disaster.nuke.duration)
              .clamp(0.0, 1.0);
          nuclearWinter = (nuclearWinter + 0.4 * dt / Disaster.nuke.duration)
              .clamp(0.0, 1.0);
          population = (population - population * 0.02 * dt).clamp(0, 1e9);
          pollution += 12 * dt;
          damageBuildings(0.5, dt); // worst case, still spread over time
        case Disaster.plague:
          // Outbreak: disease soars; emergency services + medicine soften it.
          disease = (disease + 0.15 * dt * mitigate).clamp(0.0, 1.0);
          population =
              (population - population * 0.015 * dt * mitigate).clamp(0, 1e9);
        case Disaster.famine:
          // Crops fail: drain the food stockpile fast.
          stock[Commodity.food] =
              (stockOf(Commodity.food) - population * 0.05 * dt).clamp(0, 1e12);
        case Disaster.solarStorm:
          // Geomagnetic storm: radiation up, electronics/power disrupted.
          radiation = (radiation + 0.25 * dt * mitigate).clamp(0.0, 1.0);
          stock[Commodity.compute] =
              (stockOf(Commodity.compute) - 5 * dt).clamp(0, 1e12);
        // ===== Wave 2 =====
        // --- Moving fronts (ride the storm track) ---
        case Disaster.lavaFlow:
          moveStorm(dt, 1.2);
          pollution += 4 * dt;
          damageNearStorm(0.7, dt, 1.6); // flattens a path of buildings
        case Disaster.sandworm:
          moveStorm(dt, 4.0); // fast burrower
          damageNearStorm(0.5, dt, 1.0); // narrow, swallows what's on its line
        case Disaster.grayGoo:
          moveStorm(dt, 1.0);
          damageNearStorm(0.6, dt, 1.8); // consumes buildings
          pollution += 1 * dt;
        case Disaster.crawlingForest:
          moveStorm(dt, 0.8); // creeps slowly
          overgrowNearStorm(dt, 1.6); // covers tiles in vegetation (block build)
        case Disaster.rollingGlitch:
          moveStorm(dt, 3.0);
          // Buildings it covers are temporarily disabled, not destroyed — handled
          // visually; here it just adds a flicker of lost compute.
          stock[Commodity.compute] =
              (stockOf(Commodity.compute) - 2 * dt).clamp(0, 1e12);
        // --- Cosmic overlays ---
        case Disaster.auroraBloom:
          eventHappyBonus = 0.06; // a cheering light show
        case Disaster.eclipse:
          // Sun blotted out -> solar power craters (via the nuclear-winter path
          // used by powerFactor); model as a temporary winter-like dimming.
          nuclearWinter = math.max(nuclearWinter, 0.6);
        case Disaster.gammaRayBurst:
          // Brief, lethal radiation that ignores the atmosphere.
          radiation = (radiation + 1.2 * dt / Disaster.gammaRayBurst.duration)
              .clamp(0.0, 1.0);
          population = (population - population * 0.02 * dt * mitigate)
              .clamp(0, 1e9);
        case Disaster.fallingStar:
          eventHappyBonus = 0.04;
          research += 4 * dt; // make a wish — a little inspiration
        case Disaster.skyCrack:
          eventHappyBonus = -0.05; // unsettling
          if (math.Random().nextDouble() < 0.1 * dt) flattenOne();
        case Disaster.timeDilation:
          // Warp the sim clock erratically for the duration.
          eventSimWarp = 0.4 + (0.6 + 0.6 * math.sin(disasterTime * 2)) * 1.5;
        // --- Bio / matter ---
        case Disaster.sporeBloom:
          moveStorm(dt, 0.6);
          overgrowNearStorm(dt, 1.4);
          stock[Commodity.food] =
              (stockOf(Commodity.food) - population * 0.01 * dt).clamp(0, 1e12);
        case Disaster.crystalGrowth:
          moveStorm(dt, 0.5);
          overgrowNearStorm(dt, 1.2); // crystallises tiles
          stock[Commodity.ore] = stockOf(Commodity.ore) + 1.5 * dt; // mineable
        case Disaster.biolumTide:
          eventHappyBonus = 0.07; // glowing shores -> tourism cheer
        case Disaster.chemicalRain:
          // Mutagenic/chemical: pollution + a coin-flip health swing.
          pollution += 2 * dt;
          disease = (disease + 0.03 * dt * mitigate).clamp(0.0, 1.0);
        // --- Exotic precipitation ---
        case Disaster.diamondRain:
          stock[Commodity.ore] = stockOf(Commodity.ore) + 3 * dt; // precious
          eventHappyBonus = 0.03;
        case Disaster.ironSnow:
          stock[Commodity.ore] = stockOf(Commodity.ore) + 2 * dt; // free metal
          damageBuildings(0.03, dt); // metallic precip dents roofs
        case Disaster.methaneDownpour:
          stock[Commodity.fuel] = stockOf(Commodity.fuel) + 2 * dt; // hydrocarbons
        case Disaster.bloodRain:
          eventHappyBonus = -0.04; // ominous
          stock[Commodity.food] =
              (stockOf(Commodity.food) - population * 0.005 * dt).clamp(0, 1e12);
        case Disaster.blackRain:
          // Fallout precip: radiation + pollution.
          radiation = (radiation + 0.1 * dt * mitigate).clamp(0.0, 1.0);
          pollution += 3 * dt;
        // --- Society / meta ---
        case Disaster.commsBlackout:
          commsDown = true; // no immigration (applied in pop step)
        case Disaster.goldRush:
          eventProductionMult = 1.6; // boom
          eventHappyBonus = 0.03;
        case Disaster.refugeeInflux:
          // A wave of arrivals: population jumps toward housing.
          population = (population + 2.0 * dt).clamp(0, 1e9);
        case Disaster.festival:
          eventHappyBonus = 0.10; // big morale boost
          eventProductionMult = 0.85; // everyone's off work
        case Disaster.cultUprising:
          rebellion = (rebellion + 0.05 * dt).clamp(0.0, 1.0);
          eventHappyBonus = -0.06;
        case Disaster.aiAwakening:
          // The data centres wake up: research windfall, but unsettling.
          research += 12 * dt;
          eventHappyBonus = -0.03;
        case Disaster.marketCrash:
          funds = math.max(0, funds - funds * 0.02 * dt);
          eventProductionMult = 0.8;
        // --- Wildcards ---
        case Disaster.alienBeacon:
          research += 6 * dt; // studying the monolith
          eventHappyBonus = -0.02;
        case Disaster.rainingFrogs:
          eventHappyBonus = -0.02; // "ew"
        case Disaster.glitchInMatrix:
          break; // handled on expiry (replays the last disaster)
        case Disaster.none:
          break;
      }
      // A sweeping front (tornado, hurricane, lava flow, sandworm, …) is OVER the
      // moment it drifts off the map — end the disaster regardless of its timer.
      if (stormLeftMap) {
        stormLeftMap = false;
        disasterTime = 0;
      }
      if (disasterTime <= 0) evolveDisaster();
    }

    // --- Radiation: a small space-background on thin-atmosphere worlds, plus
    //     lingering fallout. Decays slowly. Drives disease/mortality.
    final spaceBg = (1 - windFactor.clamp(0.0, 1.0)) * 0.15; // less air = more
    radiation = math.max(spaceBg, radiation - 0.04 * dt).clamp(0.0, 1.0);

    // --- Nuclear winter: decays naturally; terraformers clear it faster. Cuts
    //     solar + food + raises cold (handled where nuclearWinter is read).
    final clear = 0.02 + terraformers * 0.03;
    nuclearWinter = (nuclearWinter - clear * dt).clamp(0.0, 1.0);

    // --- Terraforming (FAST for the demo): connected terraformers push progress;
    //     progress nudges the biome toward a green/breathable state + clears
    //     nuclear winter. (Real-world this would take ages.)
    if (terraformers > 0) {
      terraform = (terraform + terraformers * 0.05 * dt).clamp(0.0, 1.0);
      // At full terraform, flip a harsh biome to grassland (greened the world).
      if (terraform >= 1.0 &&
          (biome == Biome.barren ||
              biome == Biome.desert ||
              biome == Biome.volcanic)) {
        biome = Biome.grassland;
        terraform = 0;
      }
    }
  }

  /// Flatten one random building into rubble (disasters). Its footprint cells
  /// become rubble (cosmetic debris, blocks placement) rather than vanishing, so
  /// damage is visible and recoverable (bulldoze to clear). No refund.
  void flattenOne() {
    final keys = [...grown, ...utils.keys];
    if (keys.isEmpty) return;
    flattenAt(keys[math.Random().nextInt(keys.length)]);
  }

  /// Flatten the building at anchor [k] into rubble over its whole footprint.
  void flattenAt(int k) {
    for (final c in cellsOf(k)) {
      rubble.add(c);
      fires.remove(c); // a flattened building stops burning
    }
    footprint.removeWhere((cell, anchor) => anchor == k);
    grown.remove(k);
    utils.remove(k);
    zones.remove(k);
    abandoned.remove(k);
    growProgress.remove(k);
    buildStyle.remove(k);
    decompressTimer.remove(k);
    if (landerPad == k) landerPad = null;
    recompute();
  }

  /// Probabilistic disaster damage: at [perSec] expected buildings/second, flatten
  /// at most one per tick (gentler + spread out over the now-long disasters).
  void damageBuildings(double perSec, double dt) {
    if (math.Random().nextDouble() < (perSec * dt).clamp(0.0, 1.0)) {
      flattenOne();
    }
  }

  // ---- Fire: a per-tile, spreading hazard ----

  /// A tile that can CATCH fire: a standing building (zoned or utility) that
  /// isn't already rubble or burning. Roads/empty ground/water don't burn — they
  /// act as firebreaks.
  bool flammable(int k) =>
      !rubble.contains(k) &&
      (grown.contains(k) || anchorOf(k) != null);

  /// Local fire-suppression strength at a tile, 0..~1+: nearby CONNECTED
  /// emergency-service / police stations fight the blaze. Falls off with
  /// Chebyshev distance up to a small response radius.
  double suppressionAt(int k) {
    final x = k % grid, y = k ~/ grid;
    var s = 0.0;
    for (final e in activeSpecs) {
      final t = e.value.type;
      if (t != 'emergency' && t != 'police') continue;
      final ax = e.key % grid, ay = e.key ~/ grid;
      final d = math.max((ax - x).abs(), (ay - y).abs());
      const reach = 6;
      if (d <= reach) {
        // Emergency services are stronger responders than police.
        final base = t == 'emergency' ? 0.9 : 0.4;
        s += base * (1 - d / (reach + 1));
      }
    }
    return s;
  }

  /// Light a fire on a random standing building (a fresh ignition).
  void igniteRandom() {
    final candidates = [
      for (final k in {...grown, ...utils.keys})
        if (flammable(k) && !fires.containsKey(k)) k
    ];
    if (candidates.isEmpty) return;
    fires[candidates[math.Random().nextInt(candidates.length)]] = 0.4;
  }

  /// Advance every active fire: grow intensity, damage the building (destroying
  /// it at full burn), SPREAD to flammable orthogonal neighbours (roads + a
  /// random firebreak chance stop it), and let emergency services PUT IT OUT.
  /// Fires also self-extinguish without fuel/air.
  void fireTick(double dt) {
    if (fires.isEmpty) return;
    final rnd = math.Random();
    final destroyed = <int>[];
    final extinguished = <int>[];
    final ignite = <int>[];
    // Fire can't burn without oxygen (sealed/airless worlds smother it).
    final canBurn = surface.o2Fraction >= 0.05;

    fires.forEach((k, intensity) {
      // Suppression eats intensity; without responders it climbs.
      final suppress = suppressionAt(k);
      var i = intensity + (0.18 - suppress * 0.6) * dt;
      if (!canBurn) i -= 0.5 * dt; // smothered
      if (!flammable(k)) {
        extinguished.add(k); // building already gone
        return;
      }
      if (i <= 0.02) {
        extinguished.add(k);
        return;
      }
      i = i.clamp(0.0, 1.0);
      fires[k] = i;
      // Burning damages the building; at full burn it collapses to rubble.
      if (i >= 1.0) {
        destroyed.add(k);
        return;
      }
      // Spread: a hot fire reaches into flammable orthogonal neighbours. Roads
      // (and empty/water tiles) aren't flammable, so they break the spread; a
      // random chance also halts it (firebreak / a building that doesn't catch).
      if (canBurn && i > 0.55) {
        for (final nb in neighbours(k)) {
          if (!flammable(nb) || fires.containsKey(nb)) continue;
          final spreadChance = (0.5 - suppressionAt(nb) * 0.4) * dt;
          if (rnd.nextDouble() < spreadChance.clamp(0.0, 1.0)) {
            ignite.add(nb);
          }
        }
      }
    });
    for (final k in ignite) {
      fires[k] = 0.35;
    }
    for (final k in extinguished) {
      fires.remove(k);
    }
    for (final k in destroyed) {
      fires.remove(k);
      flattenAt(k); // burned to the ground
      pollution += 4; // smoke
    }
  }

  /// When a disaster expires it may EVOLVE into a related one rather than just
  /// clearing: rain ⇄ thunderstorm ⇄ hurricane, snow → blizzard. Escalation is
  /// likelier at high hostility; otherwise it de-escalates or clears. The
  /// successor only takes hold if it's possible on this world.
  void evolveDisaster() {
    // The disaster that's ENDING becomes the "previous" one a future "glitch in
    // the matrix" can replay (never record glitch itself). Captured before it
    // changes below.
    final ending = disaster;
    if (ending != Disaster.glitchInMatrix) lastDisaster = ending;
    // Candidate successors per disaster: (next, chance). Picked top-down.
    final chains = <Disaster, List<(Disaster, double)>>{
      Disaster.rain: [
        (Disaster.thunderstorm, 0.25 + hostility * 0.35),
      ],
      Disaster.thunderstorm: [
        (Disaster.hurricane, 0.12 + hostility * 0.3),
        (Disaster.rain, 0.4), // devolve to plain rain
      ],
      Disaster.hurricane: [
        (Disaster.thunderstorm, 0.6), // always winds down
      ],
      Disaster.snow: [
        (Disaster.blizzard, 0.2 + hostility * 0.4),
      ],
      Disaster.blizzard: [
        (Disaster.snow, 0.7),
      ],
    };
    // Glitch in the Matrix: déjà-vu — instantly re-run the disaster before it.
    if (disaster == Disaster.glitchInMatrix &&
        lastDisaster != Disaster.none &&
        lastDisaster != Disaster.glitchInMatrix &&
        disasterPossible(lastDisaster)) {
      disaster = lastDisaster;
      disasterTime = lastDisaster.duration;
      initStormTrack();
      return;
    }
    final next = chains[disaster];
    if (next != null) {
      for (final (cand, chance) in next) {
        if (disasterPossible(cand) && math.Random().nextDouble() < chance) {
          disaster = cand;
          disasterTime = cand.duration;
          initStormTrack();
          return;
        }
      }
    }
    disaster = Disaster.none; // otherwise the weather clears
    beaconCell = null; // the monolith departs with the event
  }

  /// Disasters that travel across the map as a tracked epicentre (the painter
  /// draws their front at [stormX]/[stormY]).
  bool get isMovingFront => const {
        Disaster.tornado,
        Disaster.hurricane,
        Disaster.lavaFlow,
        Disaster.sandworm,
        Disaster.grayGoo,
        Disaster.crawlingForest,
        Disaster.rollingGlitch,
        Disaster.sporeBloom,
        Disaster.crystalGrowth,
      }.contains(disaster);

  /// One-shot setup when a new disaster begins. Currently: drop the alien-beacon
  /// monolith onto an empty grid tile so it's a real object on the map, not a
  /// screen overlay. Cleared again when the event ends.
  void onDisasterStart() {
    if (disaster == Disaster.alienBeacon) {
      beaconCell = randomEmptyCell();
    }
    // Fire starts as a SINGLE blaze; it spreads from there (and the event ends
    // once every fire is out).
    if (disaster == Disaster.fire) {
      igniteRandom();
    }
  }

  /// A random empty, in-bounds cell (no road/zone/util/rubble/crystal/hub), or
  /// null if the grid is full.
  int? randomEmptyCell() {
    final free = <int>[];
    for (var k = 0; k < grid * grid; k++) {
      if (k == hubKey) continue;
      if (roads.contains(k) ||
          zones.containsKey(k) ||
          anchorOf(k) != null ||
          rubble.contains(k) ||
          crystal.contains(k)) {
        continue;
      }
      free.add(k);
    }
    if (free.isEmpty) return null;
    return free[math.Random().nextInt(free.length)];
  }

  /// Seed a moving-storm track (tornado/hurricane): drop it at a random edge and
  /// send it across the grid on a random heading, so it walks over the colony.
  void initStormTrack() {
    stormLeftMap = false;
    final r = math.Random();
    final fromLeft = r.nextBool();
    stormX = fromLeft ? 0 : grid.toDouble();
    stormY = r.nextDouble() * grid;
    final ang = (fromLeft ? 0 : math.pi) + (r.nextDouble() - 0.5) * 1.2;
    final speed = 1.5 + r.nextDouble() * 1.5; // cells/sec base
    stormVX = math.cos(ang) * speed;
    stormVY = math.sin(ang) * speed;
  }

  /// Advance the storm epicentre. By default it [bounce]s softly off the grid
  /// edges to stay on the map for the disaster's duration. With [bounce] false it
  /// drifts straight off; returns TRUE once it has fully left the map (a margin
  /// past the edge) so the caller can end the disaster.
  bool moveStorm(double dt, double speedMul, {bool bounce = false}) {
    stormX += stormVX * speedMul * dt;
    stormY += stormVY * speedMul * dt;
    if (bounce) {
      if (stormX < 0 || stormX > grid) stormVX = -stormVX;
      if (stormY < 0 || stormY > grid) stormVY = -stormVY;
      stormX = stormX.clamp(0.0, grid.toDouble());
      stormY = stormY.clamp(0.0, grid.toDouble());
      return false;
    }
    // No bounce: it's gone once it's a couple of cells past any edge. Record it
    // so the tick can END the disaster (a sweeping front is over when it leaves).
    const margin = 2.0;
    final gone = stormX < -margin ||
        stormX > grid + margin ||
        stormY < -margin ||
        stormY > grid + margin;
    if (gone) stormLeftMap = true;
    return gone;
  }

  /// Flatten a building only if it lies within [radius] cells of the storm
  /// epicentre — so a tornado damages what it actually passes over, not random
  /// tiles across the whole colony.
  void damageNearStorm(double perSec, double dt, double radius) {
    if (math.Random().nextDouble() >= (perSec * dt).clamp(0.0, 1.0)) return;
    final r2 = radius * radius;
    final near = <int>[];
    for (final k in [...grown, ...utils.keys]) {
      final cx = k % grid + 0.5, cy = k ~/ grid + 0.5;
      final dx = cx - stormX, dy = cy - stormY;
      if (dx * dx + dy * dy <= r2) near.add(k);
    }
    if (near.isEmpty) return;
    flattenAt(near[math.Random().nextInt(near.length)]);
  }

  /// Overgrow tiles near the storm epicentre (spore bloom / crawling forest /
  /// crystal growth): empty cells within [radius] get covered (added to
  /// [crystal]), blocking placement until bulldozed. A building it reaches is
  /// flattened first, then its rubble overgrows.
  void overgrowNearStorm(double dt, double radius) {
    if (math.Random().nextDouble() >= (0.8 * dt).clamp(0.0, 1.0)) return;
    final cx = stormX.round(), cy = stormY.round();
    final r = radius.ceil();
    for (var dy = -r; dy <= r; dy++) {
      for (var dx = -r; dx <= r; dx++) {
        if (dx * dx + dy * dy > radius * radius) continue;
        final x = cx + dx, y = cy + dy;
        if (x < 0 || x >= grid || y < 0 || y >= grid) continue;
        final k = key(x, y);
        if (k == hubKey) continue;
        // Cover only a fraction per pass so it spreads visibly over time.
        if (math.Random().nextDouble() < 0.25) crystal.add(k);
      }
    }
    recompute();
  }

  static const requiredServices = ['safety', 'health', 'leisure'];
  double serviceCoverage() {
    final pop = population <= 0 ? 1.0 : population;
    var minCov = 1.0;
    for (final t in requiredServices) {
      final cov = ((services[t] ?? 0) / pop).clamp(0.0, 1.0);
      if (cov < minCov) minCov = cov;
    }
    return minCov;
  }

  // ---- Network ----

  /// Network roots: the landing-site marker (hub) PLUS every spaceport. The hub
  /// is no longer special — a colony works off any road-connected spaceport, so
  /// you can bulldoze the landing pad once a real spaceport anchors the network.
  Set<int> get netRoots => {
        hubKey,
        for (final e in utils.entries)
          if (e.value.type == 'spaceport') ...cellsOf(e.key),
      };

  void recompute() {
    // A virtual 'root' node bridges to the hub cell + every spaceport cell, so
    // anything road-connected to ANY of them counts as connected.
    final net = CityNetwork(hub: 'root');
    final roots = netRoots;
    bool isNet(int k) => roads.contains(k) || roots.contains(k);
    for (final r in roots) {
      net.addRoad('root', '$r');
    }
    for (final k in {...roads, ...roots}) {
      for (final nb in neighbours(k)) {
        if (isNet(nb)) net.addRoad('$k', '$nb');
      }
    }
    for (final k in [...zones.keys, ...utils.keys]) {
      // 8-way over the building's whole footprint: it's road-served if a road
      // touches ANY of its cells (corner included). The anchor is the node.
      for (final cell in cellsOf(k)) {
        for (final nb in neighbours8(cell)) {
          if (isNet(nb)) net.addRoad('$k', '$nb');
        }
      }
    }
    connectedCells = net
        .connectedSet()
        .where((s) => s != 'root')
        .map(int.parse)
        .toSet();
    computeTraffic();
    computeWasteSites();
    // Remember we ever had a working spaceport, so a later 0-count reads as
    // "demolished" rather than "never built".
    if (hasSpaceport) everHadSpaceport = true;
  }

  /// Litter tiles = the cells ON and immediately AROUND each waste-producing
  /// building (anything with housing, plus commercial zones — people generate
  /// rubbish where they live + shop). Empty streets far from buildings stay
  /// clean. The painter renders garbage/sewage only on these tiles.
  void computeWasteSites() {
    wasteSites.clear();
    final seen = <int>{};
    void addAround(int anchor) {
      for (final cell in cellsOf(anchor)) {
        if (seen.add(cell)) wasteSites.add(cell);
        for (final nb in neighbours8(cell)) {
          // Litter spills onto the kerb/yard, but never onto a road lane.
          if (!roads.contains(nb) && nb != hubKey && seen.add(nb)) {
            wasteSites.add(nb);
          }
        }
      }
    }

    for (final k in grown) {
      final z = zones[k];
      if (z == null || !isConnected(k) || abandoned.contains(k)) continue;
      // Residential + commercial zones produce household waste.
      if (z.kind == 'residential' || z.kind == 'commercial') addAround(k);
    }
    for (final e in utils.entries) {
      if (!isConnected(e.key) || abandoned.contains(e.key)) continue;
      if (e.value.housing > 0) addAround(e.key); // e.g. the spaceport crew
    }
  }

  /// Per-road traffic load: BFS the road network from the hub to get each road
  /// tile's shortest path back, then every connected BUILDING routes its trips
  /// along the road path to the hub, adding load to each tile it crosses. Roads
  /// not on ANY building's route (spurs, roads-to-nowhere) stay at zero, so no
  /// commuters are drawn on them. Normalised to 0..1; the peak is the congestion.
  void computeTraffic() {
    traffic.clear();
    // Multi-source BFS from EVERY network root (hub + spaceports) over the road
    // cells -> parent pointers. Each tile thus routes to its NEAREST root.
    final roots = netRoots;
    final parent = <int, int>{};
    final seen = <int>{...roots};
    final q = <int>[...roots];
    var qi = 0;
    bool isRoad(int k) => roads.contains(k) || roots.contains(k);
    while (qi < q.length) {
      final n = q[qi++];
      for (final nb in neighbours(n)) {
        if (isRoad(nb) && seen.add(nb)) {
          parent[nb] = n;
          q.add(nb);
        }
      }
    }
    // Each connected building enters at an adjacent road tile and walks the
    // parent chain to its nearest root, loading every road tile on the way.
    final buildings = [
      ...grown.where((k) => isConnected(k) && !abandoned.contains(k)),
      ...utils.keys.where((k) => isConnected(k) && !abandoned.contains(k)),
    ];
    var peak = 0.0;
    for (final b in buildings) {
      // Adjacent road tile (incl. diagonal/corner, across the whole footprint).
      final entry = roadEntry(b, isRoad, seen);
      if (entry == null) continue;
      var cur = entry;
      while (true) {
        if (!roots.contains(cur)) {
          final t = (traffic[cur] ?? 0) + 1;
          traffic[cur] = t;
          if (t > peak) peak = t;
        }
        final p = parent[cur];
        if (p == null) break;
        cur = p;
      }
    }
    // Normalise to 0..1 + record congestion (peak load relative to a comfortable
    // capacity ~ 8 trips/tile).
    if (peak > 0) {
      traffic.updateAll((k, v) => (v / peak).clamp(0.0, 1.0));
    }
    congestion = (peak / 8).clamp(0.0, 1.0);
  }

  double trafficAt(int key) => traffic[key] ?? 0;

  /// Orthogonal (4-way) neighbours — used for the road network topology, so a
  /// road only links to a road sharing an edge (no diagonal road jumps).
  Iterable<int> neighbours(int k) sync* {
    final x = k % grid, y = k ~/ grid;
    if (x > 0) yield key(x - 1, y);
    if (x < grid - 1) yield key(x + 1, y);
    if (y > 0) yield key(x, y - 1);
    if (y < grid - 1) yield key(x, y + 1);
  }

  /// 8-way neighbours — used only to attach a BUILDING to the road net. A
  /// building tucked against a road corner (diagonally adjacent) still counts as
  /// road-served, so you don't need a road on every orthogonal side.
  Iterable<int> neighbours8(int k) sync* {
    final x = k % grid, y = k ~/ grid;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = x + dx, ny = y + dy;
        if (nx < 0 || nx >= grid || ny < 0 || ny >= grid) continue;
        yield key(nx, ny);
      }
    }
  }

  // ---- Multi-tile footprints ----

  /// The cells a [spec] anchored at ([ax],[ay]) would cover. The anchor is the
  /// min-x/min-y corner; the footprint extends +X (east) and +Y (south).
  Iterable<int> footCells(int ax, int ay, CityBuildingSpec spec) sync* {
    for (var dy = 0; dy < spec.footH; dy++) {
      for (var dx = 0; dx < spec.footW; dx++) {
        yield key(ax + dx, ay + dy);
      }
    }
  }

  /// Anchor cell of whatever building (single- or multi-tile) covers [k], or
  /// null if [k] is empty. Single-tile buildings are their own anchor.
  int? anchorOf(int k) {
    if (utils.containsKey(k)) return k;
    return footprint[k];
  }

  /// True if a [spec] anchored at ([ax],[ay]) fits on the grid and every covered
  /// cell is free (no road/zone/util/hub).
  bool footprintFree(int ax, int ay, CityBuildingSpec spec, {int? ignoreAnchor}) {
    if (ax + spec.footW > grid || ay + spec.footH > grid) return false;
    for (final c in footCells(ax, ay, spec)) {
      if (c == hubKey) return false;
      if (roads.contains(c) ||
          zones.containsKey(c) ||
          rubble.contains(c) ||
          crystal.contains(c)) {
        return false;
      }
      final a = anchorOf(c);
      if (a != null && a != ignoreAnchor) return false;
    }
    return true;
  }

  /// Every cell a placed building (at anchor [k]) occupies. Single-tile zones &
  /// utils are just [k]; multi-tile utils expand over their footprint.
  Iterable<int> cellsOf(int k) {
    final u = utils[k];
    if (u == null) return [k];
    return footCells(k % grid, k ~/ grid, u);
  }

  /// Road tiles in the BFS tree adjacent (8-way) to ANY cell of the building at
  /// anchor [k] — a multi-tile building is served if a road touches any edge.
  int? roadEntry(int k, bool Function(int) isRoad, Set<int> seen) {
    for (final cell in cellsOf(k)) {
      for (final nb in neighbours8(cell)) {
        if (isRoad(nb) && seen.contains(nb)) return nb;
      }
    }
    return null;
  }

  // ---- Editing ----


  /// Retrofit the building covering [k] to the style the CURRENT environment
  /// calls for (open<->domed; orbital is fixed). Keeps the building's type +
  /// footprint + growth; costs ore scaled by footprint. No-op if already in the
  /// target style or the cell is empty.
  void retrofitCell(int k) {
    // Roads retrofit too: seal an open road into a tube (or unseal it) to match
    // the CURRENT air, for a small ore cost.
    if (roads.contains(k)) {
      final wantSealed = !surface.breathable;
      if (roadSealed.contains(k) == wantSealed) return; // already right
      const cost = 4.0;
      if (stockOf(Commodity.ore) < cost) {
        blocked = 'Need ${cost.toStringAsFixed(0)} ore to retrofit.';
        return;
      }
      stock[Commodity.ore] = stockOf(Commodity.ore) - cost;
      if (wantSealed) {
        roadSealed.add(k);
      } else {
        roadSealed.remove(k);
      }
      return;
    }
    // Zoned/grown buildings live in zones (not utils/footprint), so resolve
    // the anchor for BOTH: a util/footprint cell OR a zone tile.
    final anchor = anchorOf(k) ?? (zones.containsKey(k) ? k : null);
    if (anchor == null) return;
    final target = currentStyle.index;
    if (styleOf(anchor) == target) return;
    final cells = utils[anchor] != null ? utils[anchor]!.cellCount : 1;
    final cost = 12.0 * cells;
    if (stockOf(Commodity.ore) < cost) {
      blocked = 'Need ${cost.toStringAsFixed(0)} ore to retrofit.';
      return;
    }
    stock[Commodity.ore] = stockOf(Commodity.ore) - cost;
    buildStyle[anchor] = target;
  }


  /// Auto-roads: ensure a painted zone tile has road frontage. If no road (incl.
  /// corner) touches it yet, drop a road on the empty neighbour nearest the
  /// network root so the tile becomes connected without manual road-laying.
  void autoRoadAround(int k) {
    // Already road-served? nothing to do.
    for (final nb in neighbours8(k)) {
      if (roads.contains(nb) || netRoots.contains(nb)) return;
    }
    // Pick the orthogonal neighbour closest to the hub and pave it (if empty).
    final hx = hubKey % grid, hy = hubKey ~/ grid;
    int? best;
    double bestD = double.infinity;
    for (final nb in neighbours(k)) {
      if (nb == hubKey || roads.contains(nb)) continue;
      if (zones.containsKey(nb) || anchorOf(nb) != null) continue;
      final nx = nb % grid, ny = nb ~/ grid;
      final d = ((nx - hx) * (nx - hx) + (ny - hy) * (ny - hy)).toDouble();
      if (d < bestD) {
        bestD = d;
        best = nb;
      }
    }
    if (best != null) addRoad(best);
  }

  /// Stamp a multi-tile utility: register the building at its anchor and map all
  /// covered cells back to it. The painter/economy key off the anchor.
  void placeUtil(int anchor, CityBuildingSpec spec) {
    clearCell(anchor, keepSupport: true); // build ON the platform, keep it
    utils[anchor] = spec;
    buildStyle[anchor] = currentStyle.index; // capture the build style
    for (final c in footCells(anchor % grid, anchor ~/ grid, spec)) {
      if (c != anchor) footprint[c] = anchor;
    }
  }

  /// Lay a road tile, capturing whether it's a sealed (tube) road — i.e. it was
  /// built while the air was hostile. The captured style is preserved (it does
  /// NOT flip when the world is later terraformed), mirroring buildings.
  void addRoad(int k) {
    roads.add(k);
    if (surface.breathable) {
      roadSealed.remove(k);
    } else {
      roadSealed.add(k);
    }
  }

  void removeRoad(int k) {
    roads.remove(k);
    roadSealed.remove(k);
  }

  /// Clear a cell. [keepSupport] preserves the platform/truss/lift-frame on the
  /// tile — used when PLACING a building (it builds ON the support), so the
  /// support isn't stripped out from under it (which would instantly doom an
  /// ocean-platform building). Bulldozing leaves it false to remove the support.
  void clearCell(int k, {bool keepSupport = false}) {
    // Resolve to the building's anchor first so clearing ANY covered tile of a
    // multi-tile building removes the whole thing.
    final anchor = anchorOf(k) ?? k;
    if (grown.contains(anchor)) {
      stock[Commodity.ore] =
          stockOf(Commodity.ore) + zoneBuildCost * refundFraction;
    }
    final u = utils[anchor];
    if (u != null) {
      stock[Commodity.ore] =
          stockOf(Commodity.ore) + u.buildCost * refundFraction;
      // Free every cell the footprint covered.
      for (final c in footCells(anchor % grid, anchor ~/ grid, u)) {
        footprint.remove(c);
      }
    }
    zones.remove(anchor);
    utils.remove(anchor);
    roads.remove(k);
    roadSealed.remove(k);
    grown.remove(anchor);
    abandoned.remove(anchor);
    abandonTimer.remove(anchor);
    growProgress.remove(anchor);
    rubble.remove(k); // bulldozing rubble clears it
    fires.remove(k); // bulldozing also kills the fire on it
    crystal.remove(k); // bulldozing clears overgrowth too
    scatter.remove(k); // bulldozing / building clears natural cover
    if (!keepSupport) support.remove(k); // bulldozing removes a support tile
    buildStyle.remove(anchor);
    decompressTimer.remove(anchor);
    deliveries.remove(anchor); // cancel its delivery schedule
    craft.removeWhere((c) => c.anchor == anchor); // its visiting craft leave
    if (landerPad == anchor) landerPad = null; // pad gone -> lander unparked
  }

  void expandLand() {
    if (grid >= maxGrid) return;
    if (funds < landCost) {
      blocked =
          'Need §${landCost.toStringAsFixed(0)} to buy land (have §${funds.toStringAsFixed(0)}).';
      return;
    }
    final old = grid;
    final next = (old + 2).clamp(0, maxGrid);
    int rekey(int k) => (k ~/ old) * next + (k % old);
    Map<int, T> remap<T>(Map<int, T> m) =>
        {for (final e in m.entries) rekey(e.key): e.value};
    Set<int> remapSet(Set<int> s) => {
          for (final k in s) rekey(k)
        };
    {
      funds -= landCost;
      blocked = null;
      final z = remap(zones), u = remap(utils), at = remap(abandonTimer);
      final gp = remap(growProgress);
      final r = remapSet(roads), g = remapSet(grown), ab = remapSet(abandoned);
      final rub = remapSet(rubble);
      final cry = remapSet(crystal);
      final sup = remapSet(support);
      // ScatterKind maps cell -> kind index; rekey only the cell (the value is a kind).
      final scat = {for (final e in scatter.entries) rekey(e.key): e.value};
      final bst = {for (final e in buildStyle.entries) rekey(e.key): e.value};
      // Footprint maps cell->anchor; both ends are cell ids, so rekey both.
      final fp = {for (final e in footprint.entries) rekey(e.key): rekey(e.value)};
      zones..clear()..addAll(z);
      utils..clear()..addAll(u);
      footprint..clear()..addAll(fp);
      rubble..clear()..addAll(rub);
      crystal..clear()..addAll(cry);
      scatter..clear()..addAll(scat);
      buildStyle..clear()..addAll(bst);
      support..clear()..addAll(sup);
      roads..clear()..addAll(r);
      grown..clear()..addAll(g);
      growProgress..clear()..addAll(gp);
      abandoned..clear()..addAll(ab);
      abandonTimer..clear()..addAll(at);
      hubKey = rekey(hubKey);
      if (landerPad != null) landerPad = rekey(landerPad!);
      if (beaconCell != null) beaconCell = rekey(beaconCell!);
      grid = next;
      genElevation(); // re-sculpt terrain for the enlarged grid
      seedScatter(); // dress the newly-bought ring of land
      recompute();
    }
  }

  // ---- Map data (Building bridge for the painter) ----
  // The painter only reads Building.id; we key buildings by '$cellKey' and look
  // the CityBuildingSpec back up via specAt() for colour/height.

  /// The colony's road network and land parcels.
  ///
  /// Parcels — not cells — are what land is measured and built on from here
  /// out: they carry real metric polygons, a frontage, and an orientation, so a
  /// building can be sized and turned to face its street. The legacy cell grid
  /// is still the 2D map's index; [buildingParcels] is the seam that presents
  /// both as one list of real polygons to anything downstream (the 3D scene,
  /// the terrain pad, the lighting pass).
  final CityLayout layout = CityLayout();

  /// Buildings placed directly on a parcel, as parcel id -> spec. Grid-placed
  /// buildings stay in [utils] / [zones] and are converted on demand.
  final Map<String, CityBuildingSpec> parcelBuildings = {};

  /// Keys of the layout features whose terrain edit has already been recorded.
  ///
  /// Terrain brushes compose by ORDERED min/max and are permanent, so each pad,
  /// road segment and pit may only ever be emitted once — re-emitting would
  /// both grow the edit list without bound and make the composed field depend
  /// on how long the session had been running.
  final Set<String> shapedTerrain = {};

  /// Place [spec] on the parcel [parcelId]. Returns false if that parcel is
  /// unknown or already built on.
  bool placeOnParcel(String parcelId, CityBuildingSpec spec) {
    if (parcelBuildings.containsKey(parcelId)) return false;
    final exists = layout.parcels.any((p) => p.id == parcelId);
    if (!exists) return false;
    parcelBuildings[parcelId] = spec;
    return true;
  }

  /// The parcel a GRID-placed building occupies, derived from its cell
  /// footprint. The grid is centred on the colony site (as the snapshot places
  /// it), and a cell is [cellM] metres square.
  Parcel parcelForCell(int anchor, CityBuildingSpec spec) {
    final half = grid / 2.0;
    final gx = (anchor % grid) - half;
    final gy = (anchor ~/ grid) - half;
    // Real site metres, not cell counts: the heavy installations state a true
    // extent that no whole number of cells can express.
    final site = spec.siteMetres(cellM: cellM);
    final e0 = gx * cellM;
    final n0 = gy * cellM;
    final e1 = e0 + site.width;
    final n1 = n0 + site.depth;
    // Front onto the cell's north edge — the 2D map has no road direction to
    // read, so a consistent facing beats an arbitrary one.
    return Parcel(
      id: 'cell-$anchor',
      polygon: [Vec2(e0, n0), Vec2(e1, n0), Vec2(e1, n1), Vec2(e0, n1)],
      frontage: (Vec2(e0, n1), Vec2(e1, n1)),
      use: _useFor(spec),
    );
  }

  static ParcelUse _useFor(CityBuildingSpec spec) => switch (spec.group) {
        'res' => ParcelUse.residential,
        'com' => ParcelUse.commercial,
        'ind' || 'res-x' || 'aero' || 'mil' => ParcelUse.industrial,
        'power' || 'waste' || 'storage' || 'compute' => ParcelUse.utility,
        _ => ParcelUse.civic,
      };

  /// Every building in the colony as a (parcel, spec) pair, whatever placed it.
  ///
  /// One list, real polygons, correct orientation — the single source the 3D
  /// scene, terrain levelling and street lighting all read.
  Iterable<(Parcel, CityBuildingSpec)> buildingParcels() sync* {
    for (final e in parcelBuildings.entries) {
      final parcel = layout.parcels.where((p) => p.id == e.key).firstOrNull;
      if (parcel != null) yield (parcel, e.value);
    }
    for (final e in occupiedCells()) {
      yield (parcelForCell(e.key, e.value), e.value);
    }
  }

  /// The colony's designated landing sites: spaceports, starports, airfields.
  ///
  /// These are what an arriving shuttle's guidance is aimed at, so they are
  /// derived from the same parcels everything else is built on rather than from
  /// a separate table that could drift out of step with what is actually there.
  Iterable<(Parcel, CityBuildingSpec)> landingPads() sync* {
    for (final (parcel, spec) in buildingParcels()) {
      if (spec.siteKind == SiteKind.pad) yield (parcel, spec);
    }
  }

  /// Convert a point in the colony's local east/north plane to body-fixed
  /// metres on the surface of a body of [bodyRadiusM].
  Vector3 localToBodyFixed(
    Vec2 local, {
    required double bodyRadiusM,
    double elevationM = 0,
    SurfacePlacement placement = const SurfacePlacement(),
  }) =>
      placement
          .place(
            radius: bodyRadiusM,
            lat: cityLat * math.pi / 180.0,
            lon: cityLon * math.pi / 180.0,
            east: local.e,
            north: local.n,
            elevation: elevationM,
          )
          .position;

  /// Every cell that carries a building, as (cell key -> spec).
  ///
  /// Grown zone cells and hand-placed utilities both count; a multi-tile
  /// building reports only its ANCHOR cell, so the renderer gets one entry per
  /// structure rather than one per tile it covers.
  Iterable<MapEntry<int, CityBuildingSpec>> occupiedCells() sync* {
    for (final k in grown) {
      final z = zones[k];
      if (z != null) yield MapEntry(k, grownSpec(z));
    }
    yield* utils.entries;
  }

  CityBuildingSpec? specAt(int key) {
    final z = zones[key];
    if (z != null && grown.contains(key)) return grownSpec(z);
    return utils[key];
  }

  Map<int, Building> get mapCells {
    final m = <int, Building>{};
    Building b(int k) => Building(
        id: '$k', spec: const BuildingSpec(type: 'x'), gridX: k % grid, gridY: k ~/ grid);
    for (final k in grown) {
      if (zones[k] != null) m[k] = b(k);
    }
    for (final k in utils.keys) {
      m[k] = b(k);
    }
    return m;
  }

  // ---- Spaceport traffic: relief missions + scheduled deliveries ----

  /// Relief mission cooldown in seconds (between requests).
  static const double reliefCooldownMax = 180.0;
  // Landing timeline: a craft descends over the first 12%, DWELLS on the pad for
  // 30 s (the middle ~76%), then ascends over the last 12%. Total ~38 s.
  static const double craftDwellSec = 30.0;
  static const double craftTotalSec = craftDwellSec / 0.76;

  /// Footprint pad tiles of a spaceport (one craft per tile).
  Iterable<int> padTilesOf(int anchor) =>
      cellsOf(anchor); // every covered cell is a pad

  /// A free pad tile of [anchor] (not occupied by a craft), or null if full.
  int? freePad(int anchor) {
    final taken = {
      for (final c in craft)
        if (c.anchor == anchor) c.padTile
    };
    for (final t in padTilesOf(anchor)) {
      if (!taken.contains(t)) return t;
    }
    return null;
  }

  /// "Request assistance": dispatch a relief craft to [anchor] (a spaceport). It
  /// flies in, lands on a free pad, dwells 30 s and drops a care package of
  /// resources + settlers, then leaves — the anti-soft-lock lifeline.
  void requestRelief(int anchor) {
    if (reliefCooldown > 0) return;
    final pad = freePad(anchor);
    if (pad == null) return; // all pads busy
    craft.add(LandedCraft(anchor: anchor, padTile: pad, isRelief: true));
    reliefCooldown = reliefCooldownMax;
  }

  /// Drop the relief care package: top up life support, add funds + settlers that
  /// stick (raising the population floor so a cut-off colony gets unstuck).
  void grantReliefPayload() {
    final s = (grid * grid) / 400.0; // 1.0 at a 20×20 map
    void give(String c, double amt) =>
        stock[c] = (stockOf(c) + amt).clamp(0.0, stockCap);
    give(Commodity.food, 400 * s);
    give(Commodity.water, 400 * s);
    give(Commodity.oxygen, 300 * s);
    give(Commodity.ore, 300 * s);
    give(Commodity.fuel, 80 * s);
    funds += 2000 * s;
    housing += 8;
    reliefCrew += 8;
    population += 8;
    blocked = 'Relief delivered: supplies + 8 settlers.';
  }

  /// Rough propellant (in delivery-units) a craft needs to climb back to orbit
  /// from THIS world, given the [cargo] it lifted. Heavier worlds (higher surface
  /// gravity vs Earth) cost more; lighter ones (moons) much less. A floor keeps
  /// even a tiny delivery needing a little fuel.
  double returnFuelFor(double cargo) {
    final g = body.mu / (body.radius * body.radius); // surface gravity
    const earthG = 9.80665;
    final gRatio = (g / earthG).clamp(0.1, 3.0);
    return (10 + cargo * 0.25) * gRatio;
  }

  /// Advance all visiting craft + run the recurring delivery schedules.
  void reliefTick(double dt) {
    if (reliefCooldown > 0) reliefCooldown -= dt;

    // Dispatch scheduled deliveries that are due, IN LIST ORDER (priority).
    final spent = <int, List<DeliverySchedule>>{}; // one-time runs to drop
    deliveries.forEach((anchor, list) {
      if (utils[anchor]?.type != 'spaceport' || !isConnected(anchor)) return;
      for (final sched in list) {
        sched.timer -= dt;
        if (sched.timer > 0) continue;
        // Claim its assigned pad (or any free one). If busy, hold the timer at 0
        // so it dispatches the moment a pad opens (no missed cycle).
        final pad = padForSchedule(anchor, sched.padIndex);
        if (pad == null) {
          sched.timer = 0;
          continue;
        }
        dispatchDelivery(anchor, pad, sched);
        if (sched.recurring) {
          sched.timer = sched.intervalSec;
        } else {
          // One-time: fired — remove it from the schedule after this pass.
          (spent[anchor] ??= []).add(sched);
        }
      }
    });
    // Drop spent one-time deliveries (after iterating, so we don't mutate the
    // list we're walking). Clear the anchor entry when its list empties.
    spent.forEach((anchor, runs) {
      final list = deliveries[anchor];
      if (list == null) return;
      list.removeWhere(runs.contains);
      if (list.isEmpty) deliveries.remove(anchor);
    });

    // Advance each craft; drop its payload once, at the start of the dwell.
    final done = <LandedCraft>[];
    for (final c in craft) {
      // Host spaceport gone -> the craft leaves immediately.
      if (utils[c.anchor]?.type != 'spaceport') {
        done.add(c);
        continue;
      }
      // All visiting craft (relief + deliveries) use the simple pad animation:
      // descend -> dwell (drop payload) -> lift off.
      c.phase += dt / craftTotalSec;
      if (!c.granted && c.phase >= 0.12) {
        c.granted = true;
        if (c.isRelief) {
          grantReliefPayload();
        } else if (c.resource == kDeliveryPeople) {
          // Settlers stick: raise housing + the population floor (like relief).
          final n = c.payload.round();
          housing += n;
          reliefCrew += n;
          population += n;
          blocked = 'Settler transport arrived: +$n colonists.';
        } else if (c.resource != null) {
          stock[c.resource!] =
              (stockOf(c.resource!) + c.payload).clamp(0.0, stockCap);
        }
      }
      if (c.phase >= 1.0) done.add(c);
    }
    craft.removeWhere(done.contains);
  }

  /// The pad tile a schedule should use: its PINNED pad (footprint index) if set
  /// and currently free, else any free pad. Null if none available.
  int? padForSchedule(int anchor, int? padIndex) {
    final taken = {
      for (final c in craft)
        if (c.anchor == anchor) c.padTile
    };
    if (padIndex != null) {
      final tiles = padTilesOf(anchor).toList();
      if (padIndex < 0 || padIndex >= tiles.length) return freePad(anchor);
      final tile = tiles[padIndex];
      return taken.contains(tile) ? null : tile;
    }
    return freePad(anchor);
  }

  /// Send one delivery craft to [pad], applying the schedule's fuel rule.
  void dispatchDelivery(int anchor, int pad, DeliverySchedule sched) {
    // People are passengers, not cargo: their count isn't cut by return fuel.
    // Commodities are: self-fuelling shaves the return propellant off the load.
    final isPeople = sched.resource == kDeliveryPeople;
    final returnFuel = returnFuelFor(sched.amount);
    double delivered;
    if (sched.spareFuel) {
      delivered =
          isPeople ? sched.amount : (sched.amount - returnFuel).clamp(0.0, sched.amount);
    } else {
      final half = returnFuel / 2;
      if (stockOf(Commodity.fuel) < half ||
          stockOf(Commodity.oxidizer) < half) {
        blocked =
            'A ${sched.resource} delivery is grounded: not enough fuel/oxidizer to refuel it.';
        sched.timer = 0; // retry next frame
        return;
      }
      stock[Commodity.fuel] = stockOf(Commodity.fuel) - half;
      stock[Commodity.oxidizer] = stockOf(Commodity.oxidizer) - half;
      delivered = sched.amount;
    }
    // A delivery uses the SIMPLE pad animation (like Request Assistance): the
    // craft descends onto its pad, dwells while it unloads, then lifts off — no
    // free-flight autopilot (which missed the pad + looked erratic).
    craft.add(LandedCraft(
        anchor: anchor,
        padTile: pad,
        isRelief: false,
        resource: sched.resource,
        payload: delivered));
  }

  /// Resources that can be flown in on a scheduled delivery. 'people' is a
  /// special run that brings settlers instead of a commodity.
  static const List<String> deliverable = [
    kDeliveryPeople,
    Commodity.food,
    Commodity.water,
    Commodity.oxygen,
    Commodity.ore,
    Commodity.fuel,
    Commodity.oxidizer,
    Commodity.medicine,
    Commodity.steel,
    Commodity.electronics,
  ];
}
