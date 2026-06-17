import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../domain/colony/building.dart';
import '../../../domain/colony/city_network.dart';
import '../../../domain/planetary/atmospheric_composition.dart';
import '../../../domain/planetary/liquid_mix.dart';
import '../../../domain/planetary/planet_surface.dart';
import '../../../domain/planetary/surface_conditions.dart';
import '../../../domain/universe/celestial_body.dart';
import '../../../domain/universe/real_solar_system.dart';
import '../../../domain/vessel/vessel.dart';
import '../../sample_world.dart';
import '../simulation_view.dart';
import 'app_theme.dart';
import 'ascent_screen.dart';
import 'craft_assembly_screen.dart';
import 'city_map_view.dart';
import 'city_model.dart';

/// City builder. You paint RCI **zones** at low/medium/high **density** (buildings
/// grow there on their own under demand) and place **utilities, factories,
/// services, aerospace + military** buildings by hand. A live simulation runs a
/// string-commodity supply chain (food, steel, electronics, compute, guns, ammo,
/// rocket parts, missiles…), staffing + power + compute throttling, a political /
/// social model (crime, corruption, inequality, rebellion, laws, governments),
/// economy types, pollution that degrades the atmosphere, and land expansion.
/// Starting parameters for a colony, chosen on the new-city setup screen. All
/// optional — omitted fields fall back to the screen's defaults (Earth, etc.).
class CityConfig {
  final int gridSize; // cells per side at start
  final String? bodyId; // host CelestialBody id (e.g. 'earth', 'mars')
  final Biome? biome;
  final int? govtIndex; // index into _Govt.values
  final int? economyIndex; // index into _Economy.values
  final int? colonyModeIndex; // index into _ColonyStyle.values (surface/floating/orbital)
  final double? latitude, longitude; // colony site on the host body (degrees)
  final double? complexity, hostility, forgiveness, bounty; // 0..1 each

  const CityConfig({
    this.gridSize = 20,
    this.bodyId,
    this.biome,
    this.govtIndex,
    this.economyIndex,
    this.colonyModeIndex,
    this.latitude,
    this.longitude,
    this.complexity,
    this.hostility,
    this.forgiveness,
    this.bounty,
  });
}

class CityBuilderScreen extends StatefulWidget {
  final CityConfig? config;
  const CityBuilderScreen({super.key, this.config});

  @override
  State<CityBuilderScreen> createState() => _CityBuilderScreenState();
}

enum _Tool { inspect, zone, road, utility, bulldoze, retrofit, support }

/// A craft visiting a spaceport — a relief mission or a scheduled delivery. It
/// descends onto a free pad, dwells ~30 s while loading/unloading (the payload
/// drops once at the start of the dwell), then ascends and departs.
class _LandedCraft {
  final int anchor; // the spaceport it's serving
  final int padTile; // which footprint tile (pad) it sits on
  final bool isRelief; // relief mission (vs a scheduled resource delivery)
  final String? resource; // delivered commodity (deliveries only)
  final double payload; // actual amount delivered (after any spare-fuel cut)
  double phase = 0; // 0..1 PAD timeline (descend / dwell 30 s / ascend)
  bool granted = false; // one-shot payload guard

  _LandedCraft({
    required this.anchor,
    required this.padTile,
    required this.isRelief,
    this.resource,
    this.payload = 0,
  });
}

/// A recurring resource delivery booked at a spaceport: every [intervalSec] a
/// craft brings [amount] of [resource]. [timer] counts down to the next dispatch.
class _DeliverySchedule {
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
  _DeliverySchedule({
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
enum _ColonyStyle { open, domed, orbital }

/// How the zone/road tools apply: one tile per tap, continuous drag-paint, or
/// drag a rectangle and fill it on release.
enum _PaintMode { single, paint, rect }

/// Natural ground cover scattered on empty tiles, themed by biome. The painter
/// draws each kind; bulldozing clears it; it slowly regrows on cleared land.
enum _Scatter { tree, conifer, bush, grass, cactus, rock, boulder, iceShard, fungus, crystalSpire, crater }

/// Biotic scatter kinds (plants/fungus) — present only where there's enough
/// habitability; they die off when the world turns hostile. The rest (rock,
/// boulder, iceShard, crystalSpire, crater) are abiotic and climate-invariant.
const Set<_Scatter> _bioticScatter = {
  _Scatter.tree,
  _Scatter.conifer,
  _Scatter.bush,
  _Scatter.grass,
  _Scatter.cactus,
  _Scatter.fungus,
};

/// Weather + catastrophe events the player can trigger. Each has a duration and
/// simple rendered effect over the map.
enum _Disaster {
  none('None', Icons.wb_sunny, 0),
  rain('Rain', Icons.water_drop, 180),
  thunderstorm('Thunderstorm', Icons.thunderstorm, 150),
  snow('Snow', Icons.ac_unit, 210),
  dustStorm('Dust Storm', Icons.air, 180),
  tornado('Tornado', Icons.cyclone, 120),
  fire('Fire', Icons.local_fire_department, 150),
  meteorShower('Meteor Shower', Icons.stream, 120),
  plague('Plague', Icons.coronavirus, 240),
  famine('Famine', Icons.no_meals, 240),
  solarStorm('Solar Storm', Icons.flare, 180),
  nuke('Nuclear Strike', Icons.dangerous, 120),
  // --- Appended (indices 12+) so the painter's existing case numbers hold. ---
  // Weather escalations / de-escalations.
  hurricane('Hurricane', Icons.cyclone, 150),
  blizzard('Blizzard', Icons.severe_cold, 180),
  // Benign / atmospheric.
  fog('Fog', Icons.foggy, 120),
  acidRain('Acid Rain', Icons.invert_colors, 150),
  // Geophysical.
  earthquake('Earthquake', Icons.vibration, 40),
  // Sci-fi, condition-based per world.
  radiationStorm('Radiation Storm', Icons.bubble_chart, 150),
  glassRain('Glass Rain', Icons.grain, 130), // silicate rain (hot rocky worlds)
  ammoniaStorm('Ammonia Storm', Icons.ac_unit, 160), // ice-giant chemistry
  cryovolcanism('Cryovolcanism', Icons.ac_unit, 90), // icy-moon water volcanism
  miasma('Miasma', Icons.cloud, 140), // rises from unburied corpses
  // --- Wave 2 (indices 22+). Moving fronts, cosmic, bio, exotic, meta. ---
  // Moving fronts (ride the storm track).
  lavaFlow('Lava Flow', Icons.local_fire_department, 100),
  sandworm('Sandworm', Icons.waves, 90),
  grayGoo('Gray Goo', Icons.blur_on, 110),
  crawlingForest('The Crawling Forest', Icons.forest, 120),
  rollingGlitch('Rolling Glitch', Icons.broken_image, 80),
  // Cosmic overlays.
  auroraBloom('Aurora Bloom', Icons.auto_awesome, 120), // benign
  eclipse('Eclipse', Icons.dark_mode, 90),
  gammaRayBurst('Gamma-Ray Burst', Icons.flare, 30),
  fallingStar('Falling Star', Icons.star, 40), // benign rare
  skyCrack('Sky Crack', Icons.bolt, 70),
  // Reality-bending.
  timeDilation('Time Dilation', Icons.hourglass_bottom, 100),
  // Bio / matter.
  sporeBloom('Spore Bloom', Icons.grass, 130),
  crystalGrowth('Crystal Growth', Icons.diamond, 140),
  biolumTide('Bioluminescent Tide', Icons.water, 120), // benign
  chemicalRain('Chemical Rain', Icons.science, 130),
  // Exotic precipitation.
  diamondRain('Diamond Rain', Icons.diamond, 90), // benign-ish (gifts gems)
  ironSnow('Iron Snow', Icons.ac_unit, 110),
  methaneDownpour('Methane Downpour', Icons.local_gas_station, 120),
  bloodRain('Blood Rain', Icons.water_drop, 110),
  blackRain('Black Rain', Icons.grain, 120),
  // Society / meta (no painter — UI/economy only).
  commsBlackout('Comms Blackout', Icons.signal_cellular_off, 100),
  goldRush('Gold Rush', Icons.paid, 120), // positive
  refugeeInflux('Refugee Influx', Icons.groups, 60),
  festival('Festival', Icons.celebration, 80), // benign
  cultUprising('Cult Uprising', Icons.report, 110),
  aiAwakening('AI Awakening', Icons.smart_toy, 120),
  marketCrash('Market Crash', Icons.trending_down, 110),
  // Wildcards.
  alienBeacon('Alien Beacon', Icons.cell_tower, 150),
  rainingFrogs('Raining Frogs', Icons.pets, 50), // benign meme
  glitchInMatrix('Glitch in the Matrix', Icons.replay, 5); // repeats last

  final String label;
  final IconData icon;
  final double duration; // seconds
  const _Disaster(this.label, this.icon, this.duration);
}

enum _Govt {
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
  const _Govt(this.label, this.lawsAutoVoted, this.corruptionBase,
      this.rebellionSensitivity, this.happinessMod);
}

enum _Law {
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
  const _Law(this.label, this.effect);
}

enum _Economy {
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
  const _Economy(this.label, this.fundsMult, this.taxHappinessPenalty,
      this.researchMult, this.happinessFloor, this.taxControllable);
}

class _CityBuilderScreenState extends State<CityBuilderScreen>
    with TickerProviderStateMixin {
  int _grid = 20; // overridden by CityConfig.gridSize
  static const _maxGrid = 48; // ~10x the old 144-tile cap (now up to 2304)
  static const _cellM = 24.0;

  static const double _zoneBuildCost = 20;
  static const double _refundFraction = 0.5;
  static const double _foodPerPersonPerSec = 0.02;
  static const double _waterPerPersonPerSec = 0.03;
  static const double _garbagePerPersonPerSec = 0.015;
  static const double _sewagePerPersonPerSec = 0.02;
  static const double _baseStockCap = 200;
  static const double _taxPerWorkerPerSec = 0.05;
  static const double _researchPerPopPerSec = 0.02;
  static const double _growThreshold = 0.2;
  static const double _abandonDelay = 4.0;
  static const double _landCost = 200;
  static const int _landerCrew = 6; // crew quarters in the landed capsule

  // Placement.
  final Map<int, ZoneType> _zones = {};
  final Set<int> _grown = {};
  // Per grown-zone cell: build/utilisation progress 0..1. 0..0.3 = under
  // construction (scaffold, no economy yet); 0.3..1 ramps occupancy from
  // small -> medium -> large -> max as demand sustains it.
  final Map<int, double> _growProgress = {};
  final Set<int> _abandoned = {};
  final Map<int, double> _abandonTimer = {};
  final Map<int, CitySpec> _utils = {}; // keyed by ANCHOR (top-left) cell
  // For multi-tile buildings: every non-anchor cell they cover -> anchor cell,
  // so taps / occupancy / clearing on any covered tile resolve to the building.
  final Map<int, int> _footprint = {};
  // Rubble left by disasters: cells that held a building flattened by a
  // catastrophe. Cosmetic debris until bulldozed; blocks placement.
  final Set<int> _rubble = {};
  // Active fires: burning building tiles -> burn intensity 0..1. A fire damages
  // its building, SPREADS to adjacent flammable tiles (blocked by roads + a
  // random firebreak chance), and is put out by emergency-service coverage. Map
  // value also gates the flame render's size.
  final Map<int, double> _fires = {};
  final Set<int> _roads = {};
  late int _hubKey;
  Set<int> _connectedCells = {};
  final Map<int, double> _traffic = {}; // road key -> normalised load 0..1
  double _congestion = 0; // peak traffic 0..1 (drags commute efficiency)

  _Tool _tool = _Tool.zone;
  String _zoneKind = 'residential';
  Density _density = Density.low;
  CitySpec _selectedUtil = kUtilCatalog.first;
  // Camera mode (orbit vs pan) + paint-style for the zone/road tools.
  bool _panMode = false;
  double? _drawerHeight; // desktop bottom-drawer height (null = default), drag to resize
  _PaintMode _paintStyle = _PaintMode.paint;
  bool _autoRoads = false; // auto-lay roads beside painted zones
  int? _rectStart; // rect-fill anchor cell (first corner)
  int? _rectHover; // cell under the cursor (rect preview opposite corner)
  int? _hoverCell; // cell under the cursor (placement highlight)

  // Host planet (sets solar + wind effectiveness) + biome (local terrain buffs).
  late final List<CelestialBody> _bodies;
  late CelestialBody _body;
  double _cityLat = 0, _cityLon = 0; // colony site on the host body (degrees)
  Biome _biome = Biome.grassland;

  // Difficulty (0..1 each). Complexity = how many systems are active; Hostility
  // = disaster frequency/severity; Forgiveness = how much slack before people
  // die/leave; Bounty = production-rate multiplier (high = easy/abundant).
  double _complexity = 0.6;
  double _hostility = 0.4;
  double _forgiveness = 1.0; // DEBUG default: max slack
  double _bounty = 1.0; // DEBUG default: max abundance
  // Countdown to the next random disaster, in SIM seconds. Seeded with a long
  // opening grace (~30 min of sim time) so a brand-new colony gets a long, calm
  // start to establish itself before the first event (was 0 = instant disaster).
  double _autoDisasterTimer = 1800;

  // Sim.
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _timeWarp = 4;
  final Map<String, double> _stock = {
    Commodity.ore: 200,
    Commodity.fuel: 40,
    Commodity.oxidizer: 30,
    Commodity.water: 100,
    Commodity.food: 100,
  };
  double _population = 0;
  bool _starved = false;
  double _happiness = 0.5;
  double _foodSecurity = 1.0;
  double _funds = 0;
  double _research = 0;
  double _pollution = 0; // accumulated atmospheric pollution 0..~
  double _computeSupply = 0; // current compute capacity
  double _computeDemand = 0;
  _Economy _economy = _Economy.capitalism;
  double _taxRate = 0.15;
  _Govt _govt = _Govt.democracy;
  final Set<_Law> _laws = {};
  double _crime = 0;
  double _corruption = 0;
  double _inequality = 0;
  int _homeless = 0;
  double _rebellion = 0;
  double _corpses = 0; // unprocessed bodies awaiting deathcare
  double _disease = 0; // 0..1 outbreak level
  double _deathRate = 0; // people/s dying (display)
  double _wasteBacklog = 0; // 0..1 unprocessed garbage+sewage nuisance
  double _radiation = 0; // 0..1 background radiation (nuke/space/disaster)
  double _nuclearWinter = 0; // 0..1 sky-darkening (cuts solar + food + temp)
  double _terraform = 0; // 0..1 terraforming progress (shifts biome toward Earthlike)
  double _waterTable = 1.0; // 0..1 colony aquifer level (pumping dries the ground)
  double _oceanPollution = 0; // 0..1 contaminant fraction injected into the sea
  bool _underground = false; // view/build the subsurface layer
  bool _flagPlanted = false; // a flag planted at the landing site (cosmetic)
  bool _infiniteRes = false; // DEBUG: stockpiles never deplete (show ∞, keep rates)
  bool _infiniteDemand = false; // DEBUG: RCI demand pinned to max (zones keep growing)
  bool _infiniteRobotics = false; // DEBUG/endgame: buildings need no workers (full staffing)
  bool _ignoreUnlocks = false; // DEBUG: build anything regardless of population gate
  String _buildSearch = ''; // BUILD-tab palette filter (lowercased)
  int? _landerPad; // spaceport anchor the lander is parked on (occupied), or null
  // Craft currently visiting spaceports — relief missions (request assistance) +
  // scheduled resource deliveries. Each lands on a free pad of its spaceport,
  // dwells ~30 s while it loads/unloads, then leaves. A spaceport supports one
  // craft PER FOOTPRINT TILE.
  final List<_LandedCraft> _craft = [];
  double _reliefCooldown = 0; // seconds until assistance can be requested again
  int _reliefCrew = 0; // settlers the relief missions have added (population floor)
  // Recurring delivery schedules per spaceport anchor — a LIST so one starport
  // can run several deliveries (each its own resource/interval/pad). A craft is
  // dispatched whenever a schedule is due and its assigned (or any free) pad is
  // open; the list order is the dispatch priority.
  final Map<int, List<_DeliverySchedule>> _deliveries = {};
  // Map camera lives here (not in CityMapView) so orbit/zoom/pan survive the
  // drawer toggle rebuilding the map widget.
  final CityCamController _mapCam = CityCamController();
  bool _paneOpen = true; // side panel open (false = full-screen render)
  // Active disaster + its remaining seconds + an animation phase.
  _Disaster _disaster = _Disaster.none;
  double _disasterTime = 0;
  // Tornado/cyclone track: a moving epicentre (grid-fraction coords 0..grid) the
  // funnel walks across the colony, so it visibly travels + damages where it is.
  double _stormX = 0, _stormY = 0; // current position
  double _stormVX = 0, _stormVY = 0; // velocity (cells/sec)
  bool _stormLeftMap = false; // a sweeping front has drifted off the map -> end
  // Transient modifiers driven by meta/positive events (1.0 = neutral).
  double _eventProductionMult = 1.0; // gold rush boosts, market crash cuts
  double _eventHappyBonus = 0.0; // festival / aurora cheer, cult / blackout gloom
  double _eventSimWarp = 1.0; // time-dilation multiplier on dt
  double _dayPhase = 0.25; // 0..1 around the body's rotation (0.25 = morning)
  bool _commsDown = false; // comms blackout: no immigration this event
  _Disaster _lastDisaster = _Disaster.none; // for "glitch in the matrix" replay
  int? _beaconCell; // grid cell the alien-beacon monolith stands on
  final Set<int> _crystal = {}; // tiles overgrown by crystal/spore (block build)
  // Tiles around waste-producing buildings (housing/commercial) where litter
  // piles up — so garbage/sewage appears NEXT TO where people live, not on
  // empty streets. Recomputed when the layout changes.
  final List<int> _wasteSites = [];
  // Natural ground cover (trees/rocks/etc) per empty tile -> _Scatter.index.
  // Bulldozable; slowly regrows on cleared land. Themed by the host biome.
  final Map<int, int> _scatter = {};
  double _regrowTimer = 0; // countdown to the next scatter regrowth step
  // Per-tile terrain elevation in metres above the local datum (rolling hills +
  // basins). Tiles BELOW the sea/lava level are liquid. Generated once at start.
  final Map<int, double> _elevation = {};
  // Rolling-hills relief is OPT-IN. Off (default) -> flat land (oceans/coastlines
  // still form, just without lumpy ground). On -> the biome's full height field.
  bool _terrainRelief = false;
  double _seaLevel = -1e9; // datum (m); tiles with elevation < this are liquid
  // Cells that are standing liquid (ocean / lava). Computed in _genElevation
  // BEFORE the sea floor is flattened, so membership survives clamping.
  final Set<int> _liquidTiles = {};
  // Per-building architecture style (anchor cell -> _ColonyStyle.index), captured
  // at placement. Environment changes don't auto-reskin; the Retrofit tool does.
  final Map<int, int> _buildStyle = {};
  // Road tiles laid while the air was NOT breathable -> rendered as sealed
  // pressurised TRANSPORT TUBES (like the buildings, the style is captured at
  // BUILD time and preserved; terraforming later doesn't flip them — Retrofit
  // does). A tile absent here is an open-air asphalt road.
  final Set<int> _roadSealed = {};
  // Colony mode chosen at founding (surface vs floating vs orbital). Drives the
  // DEFAULT style for new buildings + the support requirement.
  _ColonyStyle _colonyMode = _ColonyStyle.open;
  // Open-style buildings exposed to hostile air accumulate a decompression timer;
  // past the grace they're destroyed (not just abandoned). anchor -> seconds.
  final Map<int, double> _decompressTimer = {};
  // Structural support layer (Platform over water / Truss in vacuum / Lift-frame
  // in atmosphere). Placed like roads; a building needs support adjacency. Loss
  // of support DESTROYS the building it held.
  final Set<int> _support = {};
  String? _revoltMsg;
  // Cached aggregate readouts (recomputed each tick from active buildings).
  int _housing = 0, _jobs = 0;
  double _staffing = 1.0; // filled jobs / required jobs (0..1)
  double _throttle = 1.0; // min(power, compute, staffing) production scaler
  double _powerOut = 0, _powerDraw = 0;
  double _resTarget = 0, _comTarget = 0, _indTarget = 0; // RCI demand
  final Map<String, double> _services = {};
  String? _blocked;

  int _key(int x, int y) => y * _grid + x;

  // Earth references for normalising solar flux + air density to 1.0.
  static const double _earthFlux = 1361; // W/m^2
  static const double _earthDensity = 1.225; // kg/m^3

  /// Solar effectiveness: ∝ irradiance at this body (closer to the Sun = more,
  /// farther = less), normalised so Earth = 1.0.
  double get _solarFactor => (_body.solarFlux / _earthFlux).clamp(0.05, 4.0);

  /// Wind effectiveness: ∝ atmospheric density (airless bodies = ~0, thick
  /// atmospheres = more), normalised so Earth = 1.0 and capped.
  double get _windFactor {
    final d = _body.atmosphere?.seaLevelDensity ?? 0;
    return (d / _earthDensity).clamp(0.0, 3.0);
  }

  /// Daylight level 0 (deep night) .. 1 (noon), a smooth sun curve over the day
  /// phase. Sunrise ~0.25, noon 0.5, sunset ~0.75. Used to tint the map + switch
  /// building lights on at night.
  double get _daylight {
    // sin peaks at phase 0.5 (noon), zero at 0/1 (midnight). Clamp the night to
    // a soft floor so it's dusk-dark, not pitch black.
    final s = math.sin(_dayPhase * math.pi); // 0 at midnight, 1 at noon
    return (s * s).clamp(0.0, 1.0);
  }

  /// O2 mole fraction of the host atmosphere (0 if airless / no data).
  double get _o2Fraction =>
      _body.composition?.fractions[AtmosphereGas.oxygen] ?? 0;

  /// Breathable worlds (Earth-like O2 + real atmosphere) supply oxygen for free
  /// — no city oxygen production needed.
  bool get _breathable =>
      (_body.atmosphere?.seaLevelDensity ?? 0) > 0.3 && _o2Fraction >= 0.15;

  /// Can an atmospheric harvester pull O2 here? (Some breathable-enough O2 in a
  /// real atmosphere, but not free-breathable.)
  bool get _o2Harvestable =>
      (_body.atmosphere?.seaLevelDensity ?? 0) > 0.05 && _o2Fraction >= 0.02;

  /// Per-biome economic buffs/debuffs. Multipliers on food/water/ore/solar
  /// production + a flat happiness + pollution-scrub modifier.
  ({
    double food,
    double water,
    double ore,
    double solar,
    double happy,
    double scrub, // pollution decay bonus
  }) get _biomeFx => switch (_biome) {
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
  SurfaceConditions get _surface => SurfaceConditions.of(
        _body,
        biome: _biome,
        waterTable: _waterTable,
        terraform: _terraform,
        pollution: _pollution,
        nuclearWinter: _nuclearWinter,
        radiationLevel: _radiation,
      );

  /// The colony's surface liquid (ocean / aquifer / lava lake) as a molecular
  /// mix, derived from the body's conditions and then CONTAMINATED by the
  /// colony's own ocean pollution. Drives the water/lava tile colour + what the
  /// aquifer yields.
  LiquidMix get _liquid {
    final s = _surface;
    // A volcano biome's "sea" is always a molten lava lake, regardless of the
    // global climate; otherwise derive the dominant liquid from conditions.
    var mix = _biome == Biome.volcano
        ? LiquidMix.lava()
        : LiquidMix.forConditions(
            temperatureK: s.temperatureK,
            co2Fraction: _co2Fraction,
            methaneFraction:
                _body.composition?.fractions[AtmosphereGas.methane] ?? 0,
          );
    if (_oceanPollution > 0.01) mix = mix.contaminated('oil', _oceanPollution);
    return mix;
  }

  /// The architecture style a NEWLY placed building takes, from the colony mode
  /// + live conditions: orbital stations are always orbital; on a surface/
  /// floating colony you build open where the air is breathable, domed where it
  /// isn't (or where it's a floating cloud deck). Existing buildings keep their
  /// own captured style until retrofitted.
  _ColonyStyle get _currentStyle {
    if (_colonyMode == _ColonyStyle.orbital) return _ColonyStyle.orbital;
    if (_colonyMode == _ColonyStyle.domed) {
      // Floating cloud deck: open only if the surrounding air is breathable.
      return _surface.breathable ? _ColonyStyle.open : _ColonyStyle.domed;
    }
    return _surface.breathable ? _ColonyStyle.open : _ColonyStyle.domed;
  }

  int _styleOf(int anchor) =>
      _buildStyle[anchor] ?? _currentStyle.index;

  // ---- Structural support ----
  /// Whether this colony needs a support structure under/beside buildings:
  /// orbital stations (vacuum) + floating colonies (no solid ground). Surface
  /// colonies don't (except over water — handled per-tile in [_tileSupported]).
  bool get _colonyNeedsSupport => _colonyMode != _ColonyStyle.open;

  /// Support-structure name for this colony mode (UI).
  String get _supportLabel => switch (_colonyMode) {
        _ColonyStyle.orbital => 'Truss',
        _ColonyStyle.domed => 'Lift-frame', // floating colony
        _ColonyStyle.open => 'Platform', // over water
      };

  /// A colony that has any standing surface liquid (ocean/coastal/wetland/lava):
  /// some tiles are below the sea level and need Platforms to build on.
  bool get _isOceanColony =>
      _colonyMode == _ColonyStyle.open && _seaLevel > -1e8;

  /// True if [k] is a liquid tile (below the sea/lava level) needing a Platform.
  bool _isWaterTile(int k) => _isLiquidTile(k);

  /// Is a building footprint at these cells structurally supported? On solid
  /// land this is always true; on orbital/floating colonies (and over OCEAN
  /// water) every covered cell must BE a support tile or be adjacent to one
  /// (orbital/floating) or directly ON one (water platforms).
  bool _footprintSupported(int ax, int ay, int fw, int fh) {
    for (var dy = 0; dy < fh; dy++) {
      for (var dx = 0; dx < fw; dx++) {
        final k = _key(ax + dx, ay + dy);
        if (_isWaterTile(k)) {
          // Water: the tile itself must be platformed (no adjacency shortcut —
          // you can't hang a building over open water off a neighbour's pier).
          if (!_support.contains(k)) return false;
        } else if (_colonyNeedsSupport) {
          if (!_cellSupported(k)) return false;
        }
      }
    }
    return true;
  }

  bool _cellSupported(int k) {
    if (_support.contains(k)) return true;
    for (final nb in _neighbours(k)) {
      if (_support.contains(nb)) return true;
    }
    return false;
  }

  /// Which natural ground cover grows on the current biome (+ density 0..1 of
  /// how much of the open land it carpets). Airless/barren worlds are sparse;
  /// lush biomes are dense. The exotic kinds appear off-world.
  ({List<_Scatter> kinds, double density}) get _biomeScatter {
    final s = _surface;
    final flora = s.floraDensity; // climate × biome flora potential × wetness
    final cold = s.temperatureK < 268;
    final warm = s.temperatureK > 288;
    final dry = s.surfaceMoisture < 0.35;
    final isMoon = _body.parent != null && !_inEarthSystem; // a moon, off-world
    final airless = s.pressureAtm < 0.05;

    // --- Abiotic (climate-invariant geology): always present. ---
    final abiotic = <_Scatter>[_Scatter.rock, _Scatter.boulder];
    if (cold || airless) abiotic.add(_Scatter.iceShard);
    if (isMoon || airless) abiotic.add(_Scatter.crater); // cratered surfaces
    if (!_inEarthSystem && s.pressureAtm < 0.2 && s.temperatureK < 200) {
      abiotic.add(_Scatter.crystalSpire); // exotic frozen worlds
    }

    // --- Biotic: how lush is the surface? Driven by floraDensity (so a living
    //     Earth forest is dense + green, a dry desert sparse, raw Mars empty). ---
    final biotic = <_Scatter>[];
    if (flora > 0.08) {
      if (warm && dry) biotic.add(_Scatter.cactus); // wet air, dry ground = scrub
      if (!cold) {
        biotic.add(_Scatter.grass);
        if (flora > 0.25) biotic.add(_Scatter.bush);
        if (flora > 0.4) biotic.add(_Scatter.tree);
      }
      if (cold && flora > 0.2) biotic.add(_Scatter.conifer);
      if (flora > 0.5 && s.surfaceMoisture > 0.6) biotic.add(_Scatter.fungus);
    }

    // Weight the mix toward biotic on lush worlds, abiotic on dead ones.
    final kinds = <_Scatter>[
      ...abiotic,
      for (final b in biotic) ...[b, b],
      if (flora > 0.6) ...biotic, // extra greenery on lush worlds
    ];
    // Density: abiotic baseline + biotic bonus from the flora cover.
    final density = (0.18 + flora * 0.6).clamp(0.1, 0.85);
    return (kinds: kinds, density: density);
  }

  /// Pick a scatter kind for a cell deterministically (so it doesn't reshuffle).
  int _scatterKindFor(int k) {
    final kinds = _biomeScatter.kinds;
    if (kinds.isEmpty) return _Scatter.rock.index;
    final h = (k * 2654435761) & 0x7fffffff;
    return kinds[h % kinds.length].index;
  }

  /// True if a cell is bare ground available for scatter to grow on. Liquid tiles
  /// (ocean/lava) are excluded — nothing scatters on water.
  bool _cellOpen(int k) =>
      k != _hubKey &&
      !_roads.contains(k) &&
      !_zones.containsKey(k) &&
      _anchorOf(k) == null &&
      !_rubble.contains(k) &&
      !_crystal.contains(k) &&
      !_isLiquidTile(k) &&
      !_scatter.containsKey(k);

  /// Seed the initial natural cover across the open map (called once at start +
  /// after buying land). Density + kinds come from the biome.
  /// Smooth value-noise elevation (metres) for a cell — deterministic per body +
  /// biome so terrain is stable. Combines two octaves for rolling hills.
  double _elevNoise(int gx, int gy) {
    final seed = _body.id.value.hashCode ^ (_biome.index * 0x9E3779B1);
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
  void _genElevation() {
    _elevation.clear();
    final relief = switch (_biome) {
      Biome.mountains => 60.0,
      Biome.volcano || Biome.volcanic => 40.0,
      Biome.wetland => 8.0, // flat swamp
      Biome.ocean => 30.0,
      Biome.coastal => 35.0,
      _ => 22.0,
    };
    // Stations / cloud decks are flat platforms.
    final flat = _colonyMode != _ColonyStyle.open;
    // Coastal worlds get ONE ocean edge: land ramps DOWN toward the +Y (bottom)
    // edge into a single flat sea, instead of noise that makes scattered
    // islands. The ramp dominates; noise only roughens the land above water.
    final coastal = !flat && _biome == Biome.coastal;
    // Ocean / volcano (lava lake) worlds are FULLY flooded — open water all the
    // way out (no land islands poking up); the colony lives on platforms. The
    // seabed sits well below the datum everywhere.
    final fullyFlooded =
        !flat && (_biome == Biome.ocean || _biome == Biome.volcano);
    var minE = 1e9, maxE = -1e9;
    for (var k = 0; k < _grid * _grid; k++) {
      final gx = k % _grid, gy = k ~/ _grid;
      // Relief is opt-in: when off, the lumpy land NOISE is dropped (flat ground),
      // but the structural flood geometry (coastal ramp, seabed) is KEPT so
      // oceans/coastlines still form. [noiseAmp] gates only the bumpy part.
      final noiseAmp = _terrainRelief ? 1.0 : 0.0;
      double e;
      if (flat) {
        e = 0.0;
      } else if (fullyFlooded) {
        // Below the waterline everywhere: flat seabed, gently undulating only
        // when relief is on.
        e = -relief * (0.6 + _elevNoise(gx, gy) * 0.4 * noiseAmp);
      } else if (coastal) {
        // 0 at the far (top) inland edge .. 1 at the near (bottom) sea edge.
        final t = _grid > 1 ? gy / (_grid - 1) : 0.0;
        // Ramp downward toward the shore (kept regardless of relief so the single
        // ocean edge always forms); bumpy inland noise only when relief is on.
        final ramp = (0.55 - t) * relief * 1.6;
        e = ramp + _elevNoise(gx, gy) * relief * 0.25 * (1 - t) * noiseAmp;
      } else {
        // Dry inland biomes: flat unless relief is enabled.
        e = _elevNoise(gx, gy) * relief * noiseAmp;
      }
      // The hub pad is always dry land (the colony's founding platform), even on
      // fully-flooded worlds where everything around it is sea.
      if (k == _hubKey && fullyFlooded) e = 0.0;
      _elevation[k] = e;
      if (e < minE) minE = e;
      if (e > maxE) maxE = e;
    }
    // Sea/lava level: a fraction of the relief range, by how watery the biome is.
    final waterFrac = switch (_biome) {
      Biome.ocean => 0.75,
      Biome.coastal => 0.3,
      Biome.wetland => 0.35,
      Biome.volcano => 0.5, // lava lake
      _ => -1.0, // dry biomes: no standing liquid
    };
    _seaLevel = waterFrac < 0 ? -1e9 : minE + (maxE - minE) * waterFrac;
    // Record which tiles are standing liquid (below the datum), THEN flatten the
    // sea floor to the datum so ocean reads as a single flat sheet (no lumpy
    // submerged hills). Membership is captured before clamping so it survives.
    _liquidTiles.clear();
    if (waterFrac >= 0) {
      _elevation.forEach((k, e) {
        if (e < _seaLevel && k != _hubKey) _liquidTiles.add(k);
      });
      _elevation.updateAll((k, e) => e < _seaLevel ? _seaLevel : e);
    }
    // Clear any pre-existing scatter that now sits on water (e.g. after a land
    // expansion re-floods tiles) — nothing grows on the sea.
    _scatter.removeWhere((k, _) => _liquidTiles.contains(k));
  }

  /// True if a tile is standing liquid (ocean/lava) — needs a platform. Reads the
  /// set captured at generation, since the sea floor is flattened to the datum
  /// afterward (so an elevation compare would no longer detect it).
  bool _isLiquidTile(int k) =>
      _colonyMode == _ColonyStyle.open && _liquidTiles.contains(k);

  void _seedScatter() {
    if (_colonyMode != _ColonyStyle.open) return; // stations/cloud decks: no flora
    final sc = _biomeScatter;
    final rnd = math.Random();
    for (var k = 0; k < _grid * _grid; k++) {
      if (!_cellOpen(k)) continue;
      if (rnd.nextDouble() < sc.density) _scatter[k] = _scatterKindFor(k);
    }
  }

  /// Natural cover responds to LIVE habitability. When the world is alive,
  /// biotic cover (plants) regrows on cleared land; when it turns hostile
  /// (a ruined atmosphere, nuclear winter), the plants DIE OFF, leaving only the
  /// climate-invariant rocks/craters. Terraforming a dead world grows life;
  /// nuking a living one kills it.
  void _regrowScatter(double dt) {
    if (_colonyMode != _ColonyStyle.open) return; // no terrain on stations/decks
    _regrowTimer -= dt;
    if (_regrowTimer > 0) return;
    _regrowTimer = 4.0; // a step every ~4 sim-seconds
    final sc = _biomeScatter;
    final flora = _surface.floraDensity;

    // 1) Die-off: when the surface can't sustain its current greenery (low flora
    //    density — a ruined atmosphere, a pumped-dry water table, nuclear winter)
    //    plants die back. Rocks stay. Lower flora = faster die-off.
    if (flora < 0.4) {
      final biotic = _scatter.entries
          .where((e) => _bioticScatter.contains(_Scatter.values[e.value]))
          .map((e) => e.key)
          .toList();
      if (biotic.isNotEmpty) {
        biotic.shuffle(math.Random());
        final kill = (1 + (0.4 - flora) * 10).round().clamp(1, 6);
        for (var i = 0; i < biotic.length && i < kill; i++) {
          _scatter.remove(biotic[i]);
        }
      }
    }

    // 2) Regrowth: sprout new cover on cleared open land, up to the surface's
    //    supported density (which already scales with habitability).
    if (sc.density <= 0 || sc.kinds.isEmpty) return;
    final open = <int>[];
    for (var k = 0; k < _grid * _grid; k++) {
      if (_cellOpen(k)) open.add(k);
    }
    if (open.isEmpty) return;
    final target = (open.length + _scatter.length) * sc.density;
    if (_scatter.length >= target) return;
    open.shuffle(math.Random());
    for (var i = 0; i < open.length && i < 3; i++) {
      _scatter[open[i]] = _scatterKindFor(open[i]);
    }
  }

  /// Open-style buildings need breathable ambient air. When the surface air is
  /// NOT breathable (raw hostile world, or a once-Earth atmosphere ruined by a
  /// nuke), any OPEN building that hasn't been retrofitted to a sealed (domed/
  /// orbital) style decompresses — after a short grace it is DESTROYED into
  /// rubble (not merely abandoned). Domed/orbital buildings ride it out.
  void _decompressTick(double dt) {
    // Structural failure is for VACUUM/anoxia only — near-zero pressure or no
    // oxygen. Pollution (dirty but thick, oxygenated air) hurts health, not the
    // building, so it must NOT trigger demolition even when it makes the air
    // "un-breathable". Recover: when the air can hold structure, timers reset.
    if (!_surface.vacuumHostile) {
      if (_decompressTimer.isNotEmpty) _decompressTimer.clear();
      return;
    }
    const grace = 12.0; // seconds of exposure before structural failure
    final doomed = <int>[];
    for (final anchor in [..._grown, ..._utils.keys]) {
      if (_styleOf(anchor) != _ColonyStyle.open.index) continue; // sealed = safe
      final t = (_decompressTimer[anchor] ?? 0) + dt;
      if (t >= grace) {
        doomed.add(anchor);
      } else {
        _decompressTimer[anchor] = t;
      }
    }
    for (final k in doomed) {
      _decompressTimer.remove(k);
      _flattenAt(k); // structural failure -> rubble
    }
  }

  /// Aquifer pumps draw the colony's water table DOWN; rain/snow + a water-rich
  /// biome recharge it. A falling table dries the surface (via _surface's
  /// waterTable input → lower flora density → die-off), so over-pumping a forest
  /// or grassland slowly turns it to scrub. Bounded 0..1.
  void _waterTableTick(double dt) {
    var pumps = 0;
    for (final e in _activeSpecs) {
      if (e.value.type == 'aquifer') pumps++;
    }
    // Drawdown scales with pumps; recharge from natural seepage (faster on wet
    // biomes) + a big boost during rain/snow.
    final drawdown = pumps * 0.006 * dt;
    final raining =
        _disaster == _Disaster.rain || _disaster == _Disaster.snow ||
            _disaster == _Disaster.thunderstorm;
    final recharge =
        (_biomeFx.water * 0.002 + (raining ? 0.02 : 0.0)) * dt;
    _waterTable = (_waterTable - drawdown + recharge).clamp(0.0, 1.0);
  }

  /// On orbital stations + floating colonies, a building whose footprint is no
  /// longer supported (its truss / lift-frame was removed) loses its anchor and
  /// is DESTROYED — it falls / drifts away. Surface colonies are unaffected.
  void _supportTick() {
    if (!_colonyNeedsSupport && !_isOceanColony) return;
    final doomed = <int>[];
    for (final anchor in [..._grown, ..._utils.keys]) {
      final gx = anchor % _grid, gy = anchor ~/ _grid;
      final fw = _specAt(anchor)?.footW ?? 1, fh = _specAt(anchor)?.footH ?? 1;
      if (!_footprintSupported(gx, gy, fw, fh)) doomed.add(anchor);
    }
    for (final k in doomed) {
      _flattenAt(k);
    }
  }

  /// Biome multiplier on a produced commodity (food/water/ore boosted or hurt
  /// by terrain). Other commodities = 1.0.
  double _biomeMult(String commodity) => switch (commodity) {
        // Nuclear winter freezes crops.
        Commodity.food => _biomeFx.food * (1 - _nuclearWinter * 0.7),
        Commodity.water => _biomeFx.water,
        Commodity.ore => _biomeFx.ore,
        _ => 1.0,
      };

  /// Ground tint for the host planet's surface, tinted by the chosen biome.
  Color get _groundTint {
    final base = _bodyGroundTint;
    final biomeCol = switch (_biome) {
      Biome.ocean => Color(_liquid.colorArgb), // tint by what the sea IS made of
      Biome.iceCap => const Color(0xFFAFC6D6),
      Biome.tundra => const Color(0xFF6B7464),
      Biome.desert => const Color(0xFF9C7B3E),
      Biome.grassland => const Color(0xFF3E6B2E),
      Biome.forest => const Color(0xFF234A24),
      Biome.mountains => const Color(0xFF5A5046),
      Biome.volcanic => const Color(0xFF4A2A24),
      Biome.barren => const Color(0xFF44413E),
      Biome.wetland => const Color(0xFF35402A),
      Biome.coastal => const Color(0xFF4A6B5E),
      Biome.volcano => Color(_liquid.colorArgb), // lava-lake colour
    };
    // Blend the planet's base tone with the biome colour.
    return Color.lerp(base, biomeCol, 0.6) ?? base;
  }

  Color get _bodyGroundTint => switch (_body.id.value) {
        'earth' => const Color(0xFF1E3A24), // green-brown soil
        'mars' => const Color(0xFF6E3B2A), // rusty regolith
        'moon' => const Color(0xFF3A3A40), // grey dust
        'venus' => const Color(0xFF6B5A2E), // yellow-brown
        'mercury' => const Color(0xFF44413E), // dark grey
        'titan' => const Color(0xFF6B5A2A), // orange organic
        'europa' || 'enceladus' => const Color(0xFF35506B), // icy blue
        'io' => const Color(0xFF7A6B2E), // sulphur yellow
        _ => const Color(0xFF2C3A30),
      };

  /// Planet-dependent multiplier on a power building's nameplate output: solar
  /// scales with sun distance, wind with air density; everything else = 1.0.
  double _powerFactor(String type) => switch (type) {
        // Nuclear winter / heavy dust blots out the sun.
        'solar' => _solarFactor * _biomeFx.solar * (1 - _nuclearWinter * 0.9),
        'wind' => _windFactor,
        _ => 1.0,
      };

  @override
  void initState() {
    super.initState();
    final system = RealSolarSystem.build();
    _bodies = system.all.where((b) => !b.isStar).toList()
      ..sort((a, b) => a.solarFlux.compareTo(b.solarFlux));
    // Apply the chosen new-city config (or sensible defaults).
    final cfg = widget.config;
    _grid = (cfg?.gridSize ?? _grid).clamp(8, _maxGrid);
    final wantBody = cfg?.bodyId ?? 'earth';
    _body = _bodies.firstWhere((b) => b.id.value == wantBody,
        orElse: () => _bodies.firstWhere((b) => b.id.value == 'earth',
            orElse: () => _bodies.first));
    if (cfg?.biome != null) _biome = cfg!.biome!;
    // Colony mode: from config, but a gas giant forces a non-surface mode.
    if (cfg?.colonyModeIndex != null) {
      _colonyMode = _ColonyStyle.values[cfg!.colonyModeIndex!];
    }
    if (_body.isGasGiant && _colonyMode == _ColonyStyle.open) {
      _colonyMode = _ColonyStyle.domed; // floating cloud city
    }
    if (cfg?.govtIndex != null) _govt = _Govt.values[cfg!.govtIndex!];
    if (cfg?.economyIndex != null) {
      _economy = _Economy.values[cfg!.economyIndex!];
    }
    _complexity = cfg?.complexity ?? _complexity;
    _hostility = cfg?.hostility ?? _hostility;
    _forgiveness = cfg?.forgiveness ?? _forgiveness;
    _bounty = cfg?.bounty ?? _bounty;
    // Colony site lat/long: from config, else a deterministic spot per world
    // (stable across launches; biased toward mid-latitudes, not the poles).
    final seed = _body.id.value.hashCode;
    _cityLat = cfg?.latitude ?? (((seed % 1000) / 1000) * 100 - 50); // -50..50
    _cityLon = cfg?.longitude ?? ((((seed ~/ 1000) % 1000) / 1000) * 360 - 180);
    _hubKey = _key(_grid ~/ 2, _grid ~/ 2);
    _roads.add(_hubKey);
    _genElevation(); // sculpt rolling terrain + the sea/lava level
    _seedScatter(); // dress the virgin land in biome-appropriate flora/rocks
    _recompute();
    _tabs = TabController(length: 5, vsync: this);
    _ticker = createTicker(_onTick)..start();
  }

  late final TabController _tabs;

  @override
  void dispose() {
    _ticker.dispose();
    _tabs.dispose();
    _drawerScroll.dispose();
    super.dispose();
  }

  // ---- Building enumeration ----

  CitySpec _grownSpec(ZoneType z) => kZoneSpecs[z.kind]![z.density]!;

  bool _isConnected(int key) => _connectedCells.contains(key);

  /// (key, spec) for every building that is connected + occupied (the economy).
  Iterable<MapEntry<int, CitySpec>> get _activeSpecs sync* {
    for (final k in _grown) {
      final z = _zones[k];
      if (z != null && _isConnected(k) && !_abandoned.contains(k)) {
        yield MapEntry(k, _grownSpec(z));
      }
    }
    for (final e in _utils.entries) {
      if (_isConnected(e.key) && !_abandoned.contains(e.key)) yield e;
    }
  }

  /// 0..1 ramp for the disaster weather overlay so it fades IN at onset + OUT
  /// near the end instead of popping. Driven by how far through the event we are.
  double get _weatherFade {
    if (_disaster == _Disaster.none) return 0;
    const ramp = 1.5; // seconds to fade in / out
    final dur = _disaster.duration;
    final elapsed = dur - _disasterTime; // counts up from 0
    final fadeIn = (elapsed / ramp).clamp(0.0, 1.0);
    final fadeOut = (_disasterTime / ramp).clamp(0.0, 1.0);
    return math.min(fadeIn, fadeOut);
  }

  bool get _hasSpaceport =>
      _utils.entries.any((e) => e.value.type == 'spaceport' && _isConnected(e.key));

  /// True once the colony has built at least one spaceport — so if it later has
  /// none we can say it was DEMOLISHED rather than never built.
  bool _everHadSpaceport = false;

  /// A spaceport exists somewhere but isn't road-connected to the hub.
  bool get _spaceportDisconnected =>
      !_hasSpaceport &&
      _utils.values.any((s) => s.type == 'spaceport');

  /// Why there's no working spaceport, for the status readout.
  /// 0 = never built, 1 = built but disconnected, 2 = demolished (had one, now none).
  int get _noSpaceportReason {
    if (_spaceportDisconnected) return 1;
    if (_everHadSpaceport) return 2;
    return 0;
  }

  /// Connected launch sites for the VAB: spaceports (rockets) + airfields
  /// (spaceplanes). Only road-connected ones can dispatch a launch.
  List<LaunchSite> get _launchSites => [
        for (final e in _utils.entries)
          if (_isConnected(e.key) &&
              (e.value.type == 'spaceport' || e.value.type == 'airfield'))
            LaunchSite(
                name: e.value.label,
                acceptsPlane: e.value.type == 'airfield',
                pads: e.value.cellCount), // one launch tower per footprint tile
      ];

  /// Open the VAB to design a craft, then launch it from one of this colony's
  /// pads/runways (gated by craft type) on THIS world.
  void _openVab() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CraftAssemblyScreen(
        bodyId: _body.id.value,
        launchSites: _launchSites,
        latitude: _cityLat,
        longitude: _cityLon,
      ),
    ));
  }

  /// Pilot a manual descent over the colony onto [anchor]'s pads. A clean pad
  /// landing parks a delivery craft there; coming down on the city flattens a
  /// random building (the craft is lost too).
  void _pilotLanding(int anchor) {
    final pads = (_specAt(anchor)?.cellCount ?? 1);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AscentScreen(
        bodyId: _body.id.value,
        descent: true,
        pads: pads,
        onLand: (padIndex) {
          // Touched down on a pad -> drop a small supply payload there.
          if (padIndex == null) return;
          setState(() {
            final pad = _freePad(anchor);
            if (pad != null) {
              _craft.add(_LandedCraft(
                  anchor: anchor,
                  padTile: pad,
                  isRelief: false,
                  resource: Commodity.fuel,
                  payload: 60));
            }
          });
        },
        onCrashIntoCity: () {
          // Came down on the city -> destroy a random building.
          setState(_flattenOne);
        },
      ),
    ));
  }

  /// Fly an ascent in the REAL 3D solar-system sim: spawn a multi-stage launch
  /// vehicle on THIS world's surface (at the colony's lat/long) and hand off to
  /// SimulationView — the spherical planet renderer, orbit camera, and STAGE /
  /// decouple controls. (Lat/long default to 0,0 until the colony tracks one.)
  void _fly3DAscent() {
    final craft = SampleWorld.buildSurfaceCraft(
      _body,
      latDeg: _cityLat,
      lonDeg: _cityLon,
      name: '${_body.name} Ascent',
    );
    // Bridge the colony's live cargo traffic into the sim as named craft on
    // their own orbits, so they appear with real trajectories — one shuttle per
    // active scheduled delivery, plus a couple of other-player shuttles.
    final traffic = <Vessel>[];
    var i = 0;
    for (final c in _craft.where((c) => !c.isRelief && c.resource != null)) {
      traffic.add(SampleWorld.buildTrafficVessel(
        _body,
        id: 'cargo-$i',
        name: '${c.resource} shuttle',
        ownerId: 'logistics',
        altitude: 300000 + i * 40000,
        phase: i * 0.7,
      ));
      i++;
    }
    // A neighbouring player's freighter so multiplayer traffic is visible.
    traffic.add(SampleWorld.buildTrafficVessel(
      _body,
      id: 'rival-1',
      name: 'Rival Freighter',
      ownerId: 'rival',
      altitude: 450000,
      phase: 2.2,
    ));
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SimulationView(injectedVessel: craft, trafficVessels: traffic),
    ));
  }

  double get _stockCap {
    var cap = _baseStockCap;
    for (final e in _utils.entries) {
      if (_isConnected(e.key)) cap += e.value.storageBonus;
    }
    return cap;
  }

  double _stockOf(String c) => _stock[c] ?? 0;

  double _effectiveTax() => _economy.taxControllable ? _taxRate : 0.5;

  bool _unlocked(CitySpec s) => _ignoreUnlocks || _population >= s.unlockPop;

  // --- Difficulty-derived modifiers ---
  /// Bounty: production rate multiplier. 0 -> 0.5×, 1 -> 2×.
  double get _bountyMult => 0.5 + _bounty * 1.5;

  /// Forgiveness: scales down the punishments (death + emigration rates). 0 ->
  /// harsh (×1.6), 1 -> gentle (×0.4).
  double get _forgiveMult => 1.6 - _forgiveness * 1.2;

  /// Whether a system is enabled at the current complexity level. Higher
  /// complexity unlocks more systems to manage.
  bool _systemOn(double threshold) => _complexity >= threshold;

  // ---- Simulation tick ----

  void _onTick(Duration elapsed) {
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // _eventSimWarp (set by a time-dilation event last tick) speeds/slows time.
    dt = (dt * _timeWarp * _eventSimWarp).clamp(0.0, 0.5);
    if (dt <= 0) return;

    // Day/night: advance the day phase by the body's rotation rate. A reference
    // Earth-day (~86400 s sidereal) is compressed to ~120 s of play; faster
    // spinners get proportionally shorter days, slow/tidELocked ones longer.
    const refDaySeconds = 120.0; // an Earth day, in real seconds of play
    final rot = _body.siderealRotationPeriod.abs();
    final dayLen = rot <= 1 ? refDaySeconds : refDaySeconds * (rot / 86400.0);
    _dayPhase = (_dayPhase + dt / dayLen.clamp(20.0, 1200.0)) % 1.0;

    final active = _activeSpecs.toList();

    // Aggregate power, compute, jobs, housing, services.
    _powerOut = 0;
    _powerDraw = 0;
    _housing = 0;
    _jobs = 0;
    _computeSupply = 0;
    _computeDemand = 0;
    _services.clear();
    for (final e in active) {
      final s = e.value;
      // Grown zones contribute in proportion to their utilisation (small/med/
      // large/max). Still-under-construction cells contribute 0. Utils = full.
      final uf = _utilFactor(e.key);
      _powerOut += s.powerOutput * _powerFactor(s.type);
      _powerDraw += s.powerDraw * (s.housing > 0 || s.jobs > 0 ? uf : 1.0);
      _housing += (s.housing * uf).round();
      _jobs += (s.jobs * uf).round();
      _computeSupply += s.computeOutput;
      _computeDemand += s.computeDraw;
      s.services.forEach((k, v) => _services[k] = (_services[k] ?? 0) + v * uf);
    }
    // The lander itself is a tiny residential building: its crew live in the
    // capsule and count toward population, so a colony has a starter housing of
    // a few people from the moment it touches down — no spaceport needed yet.
    _housing += _landerCrew;
    final powerRatio = _powerDraw <= 0 ? 1.0 : (_powerOut / _powerDraw).clamp(0.0, 1.0);
    final computeRatio =
        _computeDemand <= 0 ? 1.0 : (_computeSupply / _computeDemand).clamp(0.0, 1.0);
    final workforce = math.min(_population.floor(), _jobs);
    // Staffing: a building runs at full only if the city has the workers. Global
    // staffing ratio = filled jobs / required jobs.
    // Commute efficiency: heavy road congestion means workers spend longer
    // travelling, so fewer effective worker-hours reach the jobs. Up to a 40%
    // staffing penalty at full gridlock.
    final commuteEff = 1 - _congestion * 0.4;
    // Infinite Robotics: automated labour fills every job — buildings run at full
    // staffing with no workers (demo aid + foreshadows the endgame where robotics
    // + compute progressively replace human labour).
    final staffing = _infiniteRobotics
        ? 1.0
        : (_jobs <= 0 ? 1.0 : (workforce / _jobs * commuteEff).clamp(0.0, 1.0));
    // Overall throttle on production = the weakest of power / compute / staffing.
    final throttle = math.min(powerRatio, math.min(computeRatio, staffing));
    // Stash for the UI (net-rate display + understaffed icons).
    _staffing = staffing;
    _throttle = throttle;

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
          (_stockOf(Commodity.medicine) / (medDemand + 0.01)).clamp(0.0, 1.0);
      _services['health'] = (_services['health'] ?? 0) * medCov;
    }

    // 1. Production: inputs drain, outputs fill, scaled by throttle. Skip a
    //    building's outputs if its inputs can't be met (no free lunch).
    var pollutionRate = 0.0;
    final emissionCut = _has(_Law.emissionsCap) ? 0.5 : 1.0;
    for (final e in active) {
      final s = e.value;
      // Can we afford this building's inputs this tick?
      var canRun = true;
      s.inputs.forEach((k, v) {
        if (_stockOf(k) < v * throttle * dt) canRun = false;
      });
      final run = canRun ? throttle : 0.0;
      s.inputs.forEach(
          (k, v) => _stock[k] = (_stockOf(k) - v * run * dt).clamp(0, 1e12));
      s.outputs.forEach((k, v) => _stock[k] = _stockOf(k) +
          v * run * _biomeMult(k) * _bountyMult * _eventProductionMult * dt);
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
    final scrub = _biomeFx.scrub;
    final scrubDecay = (parks / 200 + 1.5 + math.max(0.0, scrub)) * dt;
    // OCEAN SINK: open water absorbs air pollution (gas exchange + runoff), and
    // it does so PROPORTIONALLY to how dirty the air is — so the more polluted,
    // the faster the sea scrubs it. This pins the equilibrium low: pollution
    // settles at ~emissions/sinkRate, so on a watery world (Earth) you'd need a
    // huge, map-filling industrial output to ever push toxicity up. A non-molten
    // sea only. Sink strength scales with how much of the map is water.
    final waterTiles =
        _liquid.isMolten ? 0 : _liquidTiles.length;
    final waterFrac = (waterTiles / (_grid * _grid)).clamp(0.0, 1.0);
    // Up to ~8%/s drain at a fully-oceanic map; a small lake still helps.
    final oceanSink = (0.02 + 0.6 * waterFrac).clamp(0.0, 0.9);
    final proportionalDrain = _pollution * oceanSink * dt;
    // Dirty-biome baseline the smog settles AT (volcanic -1 -> ~20, volcano -2
    // -> ~40). Pollution eases toward it instead of accumulating without bound.
    final dirtyFloor = scrub < 0 ? -scrub * 20.0 : 0.0;
    var p = _pollution - scrubDecay - proportionalDrain; // green + ocean scrub
    if (p < dirtyFloor) {
      // Below the biome's smog floor: relax UP toward it (slowly), not snap.
      p += (dirtyFloor - p) * (0.2 * dt).clamp(0.0, 1.0);
    }
    _pollution = (p + pollutionRate * dt).clamp(0.0, 1e6);

    // Ocean pollution: heavy air pollution seeps into the surface liquid (runoff)
    // and lingers — it discolours the sea + degrades what the aquifer yields. It
    // creeps toward the current pollution level and decays slowly when clean.
    final oceanTarget = (_pollution / 250).clamp(0.0, 1.0);
    _oceanPollution = _oceanPollution +
        (oceanTarget - _oceanPollution) * (0.05 * dt).clamp(0.0, 1.0) -
        0.002 * dt;
    _oceanPollution = _oceanPollution.clamp(0.0, 1.0);

    // 1.5 Life support. Population eats food + drinks water. Food SECURITY is
    //     measured as how many SECONDS of runway the stockpile holds at the
    //     current consumption rate, mapped to 0..1 over a target runway. This is
    //     population-INDEPENDENT in shape, so it no longer snaps to "1.0" the
    //     instant population dips toward zero (the cause of the starve sawtooth):
    //     a small steady food import keeps a small population's runway high and
    //     stable instead of toggling the flag every frame.
    final foodPerSec = _population * _foodPerPersonPerSec;
    final waterPerSec = _population * _waterPerPersonPerSec;
    _stock[Commodity.food] =
        (_stockOf(Commodity.food) - foodPerSec * dt).clamp(0, 1e12);
    _stock[Commodity.water] =
        (_stockOf(Commodity.water) - waterPerSec * dt).clamp(0, 1e12);
    // Oxygen: FREE on breathable worlds (Earth); elsewhere the city must produce
    // it (electrolysis / atmospheric harvester) or shuttle it in, or the
    // population suffocates. We keep the stockpile topped on breathable worlds so
    // the security calc treats O2 as a non-constraint there.
    // Oxygen is a managed system only at COMPLEXITY >= 0.3 (and off breathable
    // worlds). Below that, life support ignores it for a gentler game.
    final o2Managed = _systemOn(0.3) && !_breathable;
    final o2PerSec = o2Managed ? _population * _waterPerPersonPerSec : 0.0;
    if (!o2Managed) {
      _stock[Commodity.oxygen] = _stockCap; // free / not tracked
    } else {
      _stock[Commodity.oxygen] =
          (_stockOf(Commodity.oxygen) - o2PerSec * dt).clamp(0, 1e12);
    }
    // Runway (seconds) = stock / consumption. With ~zero consumption (tiny pop)
    // any stock = effectively infinite runway -> full security, but it gets there
    // smoothly via the ease, not by a hard pop<=0 branch.
    const targetRunway = 30.0; // 30 s buffer = "secure"
    double runwaySec(double stock, double perSec) =>
        perSec < 1e-6 ? targetRunway : stock / perSec;
    final secTarget = [
      runwaySec(_stockOf(Commodity.food), foodPerSec) / targetRunway,
      runwaySec(_stockOf(Commodity.water), waterPerSec) / targetRunway,
      runwaySec(_stockOf(Commodity.oxygen), o2PerSec) / targetRunway,
    ].map((v) => v.clamp(0.0, 1.0)).reduce(math.min);
    // Ease slowly so transient dips don't whip the flag.
    _foodSecurity =
        (_foodSecurity + (secTarget - _foodSecurity) * (0.6 * dt).clamp(0.0, 1.0))
            .clamp(0.0, 1.0);
    // Wide hysteresis band: only declare starving when really empty (<0.12),
    // recover only when comfortably stocked (>0.6).
    if (_foodSecurity < 0.12) {
      _starved = true;
    } else if (_foodSecurity > 0.6) {
      _starved = false;
    }

    // 1.53 Waste: the population generates GARBAGE + SEWAGE; landfills /
    //      recyclers / sewage plants consume them (handled in the production
    //      loop). Whatever isn't processed PILES UP — a big backlog leaks
    //      pollution + disease + drags happiness. Only active at higher
    //      COMPLEXITY (one of the systems the player opts into).
    if (_systemOn(0.5)) {
      _stock[Commodity.garbage] = _stockOf(Commodity.garbage) +
          _population * _garbagePerPersonPerSec * dt;
      _stock[Commodity.sewage] = _stockOf(Commodity.sewage) +
          _population * _sewagePerPersonPerSec * dt;
      _wasteBacklog = _population <= 0
          ? 0.0
          : ((_stockOf(Commodity.garbage) + _stockOf(Commodity.sewage)) /
                  (_population * 2))
              .clamp(0.0, 1.0);
      _pollution += _wasteBacklog * 3 * dt; // rotting waste pollutes
    } else {
      _wasteBacklog = 0;
    }

    // 1.55 Society + politics.
    _socialTick(workforce, dt);

    // 1.51 Environment: disasters, radiation, nuclear winter, terraforming.
    _envTick(dt);
    _regrowScatter(dt); // natural cover slowly reclaims cleared land
    _decompressTick(dt); // open buildings fail when the air turns hostile
    _supportTick(); // unsupported buildings on stations/floating colonies fall
    _reliefTick(dt); // relief craft animation + care-package grant
    _fireTick(dt); // per-tile fires spread + are fought (outlive the disaster)
    _waterTableTick(dt); // aquifer pumps draw the table down; rain recharges it
    // A molten lava lake (volcano biome) bakes the colony: extra pollution +
    // heat radiating off the surface. Bounded — it tops up the smog toward a
    // ceiling rather than climbing forever.
    if (_liquid.isMolten && _seaLevel > -1e8 && _pollution < 60) {
      _pollution += 1.5 * dt;
    }

    // 1.52 Mortality + deathcare. People die of HUNGER (low food security),
    //      DISEASE (poor health coverage + pollution + corpse backlog), and WAR
    //      (a small attrition while military bases operate). Deaths add to the
    //      CORPSE backlog; deathcare buildings process it. Unprocessed corpses
    //      breed disease + drag happiness — a feedback loop.
    final pop = _population;
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
        : (1 - ((_services['health'] ?? 0) / needHealth)).clamp(0.0, 1.0);
    final corpseFrac = pop > 0 ? (_corpses / pop).clamp(0.0, 1.0) : 0.0;
    final diseaseTarget = (0.35 * uncovered +
            0.2 * (_pollution / 200).clamp(0.0, 1.0) +
            0.25 * corpseFrac +
            0.3 * _radiation + // radiation sickness
            0.2 * _wasteBacklog) // filth breeds disease
        .clamp(0.0, 1.0);
    _disease = _ease(_disease, diseaseTarget, dt, 0.25);
    // Death rate (people/s). Only ACUTE radiation (above the harmless space
    // background) kills directly — a thin-atmosphere world's faint background
    // shouldn't quietly wipe out the starter crew.
    final radDeaths = pop * math.max(0.0, _radiation - 0.25) * 0.013;
    final hungerDeaths = _starved ? pop * 0.02 : 0.0;
    final diseaseDeaths = pop * _disease * 0.01;
    var warDeaths = 0.0;
    for (final e in _activeSpecs) {
      if (e.value.type == 'base' || e.value.type == 'airfield') {
        warDeaths += pop * 0.0008; // standing-army attrition
      }
    }
    _deathRate =
        (hungerDeaths + diseaseDeaths + warDeaths + radDeaths) * _forgiveMult;
    final died = _deathRate * dt;
    _population = (pop - died).clamp(0, double.infinity);
    _corpses += died;
    // Deathcare processing.
    var careRate = 0.0;
    for (final e in _activeSpecs) {
      careRate += e.value.deathcareRate;
    }
    _corpses = (_corpses - careRate * dt).clamp(0, double.infinity);

    // 1.6 Happiness. Pollution now also drags it.
    final coverage = _serviceCoverage();
    final tax = _effectiveTax();
    final pollutionDrag = (_pollution / 200).clamp(0.0, 0.4);
    final corpseDrag = _population > 0
        ? (_corpses / _population).clamp(0.0, 1.0) * 0.4
        : 0.0;
    final socialDrag = _crime * 0.35 +
        _inequality * 0.3 +
        (_population > 0 ? (_homeless / _population).clamp(0.0, 1.0) : 0) * 0.4 +
        _corruption * 0.2 +
        _disease * 0.3 +
        _wasteBacklog * 0.2 + // stinking streets
        corpseDrag +
        pollutionDrag;
    var happyTarget = _starved
        ? 0.0
        : (coverage - tax * _economy.taxHappinessPenalty - socialDrag +
                _govt.happinessMod +
                _lawHappiness() +
                _transitBonus() +
                _biomeFx.happy +
                _eventHappyBonus) // festival/aurora cheer or cult/blackout gloom
            .clamp(_economy.happinessFloor, 1.0);
    if (_starved) happyTarget = 0.0;
    _happiness =
        (_happiness + (happyTarget - _happiness) * (0.4 * dt).clamp(0.0, 1.0))
            .clamp(0.0, 1.0);

    // 1.7 Payoff: tax (funds) + research.
    final taxIncome = workforce *
        _happiness *
        tax *
        _taxPerWorkerPerSec *
        _economy.fundsMult *
        (1 - _corruption * 0.6);
    _funds += (taxIncome + _lawFundsRate()) * dt;
    _research += _population *
        _happiness *
        _researchPerPopPerSec *
        _economy.researchMult *
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
    final liveHousing = math.max(0.0, _housing - _corpses);
    final cap = liveHousing * (0.4 + 0.6 * _happiness);
    // The lander always seeds its crew; relief settlers add to that floor; a
    // spaceport unlocks growth beyond them.
    final floor = (_landerCrew + _reliefCrew).toDouble();
    final target = (_hasSpaceport ? math.max(cap, floor) : floor) * _foodSecurity;
    // Migration BOTH ways needs a working (road-connected) spaceport — it's the
    // only way on or off the world. A comms blackout also halts arrivals.
    // Without a spaceport the colony is stuck with exactly its landed crew: no
    // immigration in, no emigration out (people can still DIE, handled above).
    if (_hasSpaceport) {
      if (_population < target && !_commsDown) {
        _population =
            (_population + (1.5 + 3.0 * _happiness) * dt).clamp(0, target);
      } else if (_population > target) {
        // Leave faster the bigger the shortfall, but bounded so it can't whip.
        final shortfall = (1 - _foodSecurity);
        final leaveRate =
            (1.0 + (1 - _happiness) * 1.5 + shortfall * 2.0) * _forgiveMult;
        _population =
            (_population - leaveRate * dt).clamp(target, double.infinity);
      }
    }

    // 3. RCI demand eases toward targets (no sawtooth).
    final jobsD = _jobs.toDouble();
    final housingD = _housing.toDouble();
    // DEBUG infinite demand: pin every RCI target to max so zones always grow.
    final rTgt = _infiniteDemand
        ? 1.0
        : (_hasSpaceport ? (0.2 + (jobsD - housingD) / 120).clamp(0.1, 1.0) : 0.0);
    final leisure = _services['leisure'] ?? 0;
    final cTgt = _infiniteDemand
        ? 1.0
        : (_population > 0 ? (1 - leisure / _population).clamp(0.0, 1.0) : 0.0);
    final iTgt = _infiniteDemand
        ? 1.0
        : (_population > 0 ? (_population / 500).clamp(0.0, 1.0) : 0.0);
    double ease(double cur, double tgt) =>
        cur + (tgt - cur) * (dt * 1.2).clamp(0.0, 1.0);
    _resTarget = ease(_resTarget, rTgt);
    _comTarget = ease(_comTarget, cTgt);
    _indTarget = ease(_indTarget, iTgt);

    // 4. Growth: connected un-grown zoned tile grows once demand clears threshold
    //    and there's ore. (Density of the zone sets the grown spec.)
    var built = 0;
    for (final e in _zones.entries) {
      final k = e.key;
      if (_grown.contains(k) || !_isConnected(k)) continue;
      if (built >= 2) break;
      if (_demandFor(e.value.kind) > _growThreshold &&
          _stockOf(Commodity.ore) >= _zoneBuildCost) {
        _grown.add(k);
        _buildStyle[k] = _currentStyle.index; // capture the build style
        _growProgress[k] = 0; // starts under construction
        _abandonTimer[k] = 0;
        _stock[Commodity.ore] = _stockOf(Commodity.ore) - _zoneBuildCost;
        built++;
      }
    }

    // 4b. Construction + utilisation ramp. Each grown, healthy zone cell builds
    //     up (through the construction phase) then fills toward an occupancy
    //     target set by its demand — so a building gradually grows small -> max
    //     when wanted, and slowly empties (shrinks utilisation) when demand dies.
    for (final k in _grown) {
      final z = _zones[k];
      if (z == null) continue;
      final p = _growProgress[k] ?? 1.0;
      // "Healthy" drives the occupancy target — so it must use the DELAYED
      // _abandoned flag, NOT the raw instantaneous powerRatio. A borderline power
      // ratio (hovering near the cutoff) would otherwise flip the target between
      // full and empty every tick, jittering the building's height. Sustained
      // failure already trips _abandoned (with a grace delay) below.
      final healthy = _isConnected(k) && !_abandoned.contains(k);
      // Occupancy target: full while still building (so it always finishes),
      // then tracks demand once occupied. Unhealthy cells decay to empty.
      // A FINISHED building never sits exactly at _constructFrac (the
      // construction<->built render boundary) — it's floored a little above it,
      // so float jitter can't flip it between scaffold and box ("bouncing").
      const occupiedFloor = _constructFrac + 0.08;
      final demand = _demandFor(z.kind);
      final target = !healthy
          ? 0.0
          : (p <= _constructFrac
              ? 1.0
              : (occupiedFloor + (1 - occupiedFloor) * demand)
                  .clamp(occupiedFloor, 1.0));
      // Construction is brisk; utilisation grows/shrinks more slowly.
      final rate = p <= _constructFrac ? 0.35 : 0.12;
      final step = (rate * dt).clamp(0.0, 1.0);
      _growProgress[k] =
          (p + (target - p).clamp(-step, step)).clamp(0.0, 1.0);
    }

    // 5. Abandonment on infrastructure failure (disconnect / unpowered).
    final removed = <int>[];
    for (final k in _grown) {
      if (_zones[k] == null) {
        removed.add(k);
        continue;
      }
      final failed = !_isConnected(k) || powerRatio < 0.35;
      if (failed) {
        _abandonTimer[k] = (_abandonTimer[k] ?? 0) + dt;
        if ((_abandonTimer[k] ?? 0) >= _abandonDelay) _abandoned.add(k);
      } else {
        _abandonTimer[k] = 0;
        _abandoned.remove(k);
      }
    }
    for (final k in removed) {
      _grown.remove(k);
      _abandoned.remove(k);
      _abandonTimer.remove(k);
      _growProgress.remove(k);
    }

    // 6. Storage cap.
    final sc = _stockCap;
    for (final t in _stock.keys.toList()) {
      if (_stockOf(t) > sc) _stock[t] = sc;
    }

    // DEBUG infinite resources: top every input commodity back up so nothing
    // ever runs dry. Production/consumption (and thus the displayed rates) still
    // happen above this; this only refills the tanks. Waste backlogs are left
    // alone so the colony still has something to manage.
    if (_infiniteRes) {
      for (final c in Commodity.ordered) {
        if (c == Commodity.garbage || c == Commodity.sewage) continue;
        _stock[c] = sc;
      }
    }

    setState(() {});
  }

  double _demandFor(String kind) => switch (kind) {
        'residential' => _resTarget,
        'commercial' => _comTarget,
        _ => _indTarget,
      };

  // --- Zone utilisation / construction ---
  static const double _constructFrac = 0.3; // progress below this = building

  /// Occupancy fraction (0..1) of a grown zone cell: ramps in only AFTER the
  /// construction phase. Utils are always 1.0 (no construction model for them).
  double _utilFactor(int k) {
    if (!_grown.contains(k)) return 1.0;
    final p = _growProgress[k] ?? 1.0;
    if (p <= _constructFrac) return 0.0; // still under construction
    return ((p - _constructFrac) / (1 - _constructFrac)).clamp(0.0, 1.0);
  }

  /// True while a grown zone cell is still being built (scaffold render, no
  /// economic output yet).
  bool _underConstruction(int k) =>
      _grown.contains(k) && (_growProgress[k] ?? 1.0) <= _constructFrac;

  /// Utilisation stage name for a grown zone cell (UI / tooltips).
  String _utilStage(int k) {
    if (_underConstruction(k)) return 'Building';
    final u = _utilFactor(k);
    if (u < 0.3) return 'Small';
    if (u < 0.6) return 'Medium';
    if (u < 0.9) return 'Large';
    return 'Max';
  }

  bool _has(_Law l) => _laws.contains(l);

  /// Transit relieves commuting: each connected transit stop serves ~150 people;
  /// full coverage gives a happiness bonus (cheaper commutes, less congestion).
  double _transitBonus() {
    final stops = _utils.entries
        .where((e) => e.value.type == 'transit' && _isConnected(e.key))
        .length;
    if (stops == 0 || _population <= 0) return 0;
    final coverage = (stops * 150 / _population).clamp(0.0, 1.0);
    return coverage * 0.1; // up to +10% happiness at full transit coverage
  }

  double _lawHappiness() {
    var h = 0.0;
    if (_has(_Law.freeHealthcare)) h += 0.12;
    if (_has(_Law.freePublicTransit)) h += 0.08;
    if (_has(_Law.homelessShelters)) h += 0.05;
    if (_has(_Law.curfew)) h -= 0.06;
    if (_has(_Law.industrialSubsidy)) h -= 0.05;
    if (_has(_Law.wealthTax)) h -= 0.04;
    if (_has(_Law.robotTax)) h += 0.06; // UBI cushions the displaced
    return h;
  }

  double _lawFundsRate() {
    final scale = (_population / 100).clamp(0.2, 5.0);
    var f = 0.0;
    if (_has(_Law.freeHealthcare)) f -= 0.6 * scale;
    if (_has(_Law.freePublicTransit)) f -= 0.5 * scale;
    if (_has(_Law.homelessShelters)) f -= 0.4 * scale;
    if (_has(_Law.antiCorruption)) f -= 0.5 * scale;
    if (_has(_Law.wealthTax)) f += 0.8 * scale;
    if (_has(_Law.industrialSubsidy)) f -= 0.3 * scale;
    if (_has(_Law.robotTax)) f -= 0.5 * scale; // UBI payouts cost the treasury
    return f;
  }

  void _socialTick(int workforce, double dt) {
    final pop = _population;
    _homeless = math.max(0, (pop - _housing)).round();
    final homelessFrac = pop > 0 ? (_homeless / pop).clamp(0.0, 1.0) : 0.0;
    final shelterRelief = _has(_Law.homelessShelters) ? 0.5 : 1.0;
    // Automation displaces labour: with Infinite Robotics, machines fill the
    // jobs people would have worked, so human unemployment climbs unless the
    // state shares the gains (a Robot Tax / UBI softens it). This is the
    // political cost of automation — inequality + unrest if left unaddressed.
    final autoDisplaced =
        _infiniteRobotics ? (1.0 - (_has(_Law.robotTax) ? 0.6 : 0.0)) : 0.0;
    final unemployedFrac = pop > 0
        ? math.max(((pop - workforce) / pop).clamp(0.0, 1.0), autoDisplaced)
        : 0.0;
    final safety = _services['safety'] ?? 0;
    final safetyCov = pop > 0 ? (safety / pop).clamp(0.0, 1.0) : 1.0;
    var crimeTarget = (0.5 * unemployedFrac +
            0.4 * homelessFrac * shelterRelief +
            0.3 * (1 - safetyCov))
        .clamp(0.0, 1.0);
    if (_has(_Law.curfew)) crimeTarget *= 0.6;
    _crime = _ease(_crime, crimeTarget, dt, 0.5);

    var corrTarget =
        (_govt.corruptionBase + (pop / 1500).clamp(0.0, 0.4)).clamp(0.0, 1.0);
    if (_has(_Law.antiCorruption)) corrTarget *= 0.4;
    _corruption = _ease(_corruption, corrTarget, dt, 0.3);

    final tax = _effectiveTax();
    var ineqTarget = (0.4 * unemployedFrac +
            0.3 * _corruption +
            0.3 * (tax * (1 - _serviceCoverage())))
        .clamp(0.0, 1.0);
    if (_has(_Law.wealthTax)) ineqTarget *= 0.5;
    _inequality = _ease(_inequality, ineqTarget, dt, 0.3);

    if (_govt.lawsAutoVoted) _autoVote();

    final unrest = (0.5 * (1 - _happiness) +
            0.2 * _crime +
            0.2 * _inequality +
            0.1 * _corruption) *
        _govt.rebellionSensitivity;
    _rebellion =
        (_rebellion + (unrest - 0.4 - _rebellion) * 0.15 * dt).clamp(0.0, 1.0);
    if (_rebellion >= 1.0 && pop > 0) {
      final lost = (pop * 0.3).round();
      _population = (pop - lost).clamp(0, double.infinity);
      _funds *= 0.6;
      _rebellion = 0.3;
      _revoltMsg =
          'REVOLT! $lost citizens fled, treasury raided. Fix crime, inequality + happiness.';
    }
  }

  void _autoVote() {
    // Hysteresis: enact a law once a metric crosses the HIGH threshold, repeal
    // it only when it drops back below a LOWER one. Without the dead band a law
    // that fixes the very metric it reacts to (curfew lowers crime, which then
    // repeals the curfew, which lets crime climb again) flip-flops forever.
    void band(_Law l, double value, double onAt, double offAt) {
      if (_laws.contains(l)) {
        if (value < offAt) _laws.remove(l);
      } else {
        if (value > onAt) _laws.add(l);
      }
    }

    band(_Law.homelessShelters, _population > 0 ? _homeless / _population : 0,
        0.10, 0.04);
    band(_Law.freeHealthcare, 1 - _happiness, 0.55, 0.40); // low happiness -> on
    band(_Law.antiCorruption, _corruption, 0.40, 0.25);
    band(_Law.curfew, _crime, 0.50, 0.30);
    band(_Law.wealthTax, _inequality, 0.50, 0.35);
    band(_Law.emissionsCap, _pollution, 120, 80);
    band(_Law.freePublicTransit, _population.toDouble(), 200, 150);
    // Voters demand a robot tax / UBI once automation drives unemployment up.
    band(_Law.robotTax, _infiniteRobotics ? _inequality : 0.0, 0.45, 0.25);
  }

  double _ease(double cur, double tgt, double dt, double rate) =>
      cur + (tgt - cur) * (rate * dt).clamp(0.0, 1.0);

  /// Count connected terraformers (utility type 'terraformer').
  int get _terraformers => _utils.entries
      .where((e) => e.value.type == 'terraformer' && _isConnected(e.key))
      .length;

  int _countUtil(String type) => _utils.entries
      .where((e) => e.value.type == type && _isConnected(e.key))
      .length;

  /// Disaster severity multiplier (<1 = better protected). Emergency services +
  /// bunkers cut the harm; floors at 0.3.
  double get _mitigate {
    final prep = _countUtil('emergency') * 0.15 + _countUtil('bunker') * 0.08;
    return (1 - prep).clamp(0.3, 1.0);
  }

  bool get _hasWarning => _countUtil('warning') > 0;

  /// Environment tick: disasters, radiation, nuclear winter, terraforming.
  /// Whether the host body has a real (weather-bearing) atmosphere — required
  /// for wind/precip-type events. Airless/near-vacuum worlds get no weather.
  bool get _hasWeatherAir => (_body.atmosphere?.seaLevelDensity ?? 0) > 0.05;

  // --- World-condition flags driving the exotic, condition-based disasters. ---
  /// Scorching world (close to the Sun / runaway greenhouse) — Venus, Mercury.
  bool get _isHot => _solarFactor > 1.6 || (_co2Fraction > 0.5 && _hasWeatherAir);
  /// Cryogenic world (very far from the Sun, icy) — outer moons, Pluto-likes.
  bool get _isFrozen => _solarFactor < 0.15;
  /// Hydrogen/methane/ammonia-rich reducing atmosphere — gas/ice giants & moons.
  bool get _hasReducingAtmo {
    final f = _body.composition?.fractions;
    if (f == null) return false;
    return (f[AtmosphereGas.hydrogen] ?? 0) +
            (f[AtmosphereGas.methane] ?? 0) >
        0.2;
  }
  double get _co2Fraction =>
      _body.composition?.fractions[AtmosphereGas.carbonDioxide] ?? 0;
  /// Tectonically/volcanically active — quakes + ground hazards.
  bool get _isTectonic =>
      _biome == Biome.volcanic || _biome == Biome.mountains;
  /// Magnetosphere shielding (airless + no field = bathed in radiation).
  bool get _isUnshielded =>
      (_body.dipoleMoment <= 0) && !_hasWeatherAir;

  /// Earth + its moons (Luna): the home system. We keep this grounded — only
  /// real-world disasters here; the exotic/sci-fi events are reserved for the
  /// stranger worlds out in the rest of the solar system.
  bool get _inEarthSystem =>
      _body.id.value == 'earth' || _body.parent?.value == 'earth';

  /// The fantastical / hard-sci-fi events that should NOT occur in the Earth
  /// system (they need exotic worlds + chemistry, or are pure sci-fi).
  static const Set<_Disaster> _exoticDisasters = {
    _Disaster.glassRain,
    _Disaster.ammoniaStorm,
    _Disaster.cryovolcanism,
    _Disaster.diamondRain,
    _Disaster.methaneDownpour,
    _Disaster.grayGoo,
    _Disaster.crawlingForest,
    _Disaster.rollingGlitch,
    _Disaster.timeDilation,
    _Disaster.skyCrack,
    _Disaster.gammaRayBurst,
    _Disaster.alienBeacon,
    _Disaster.glitchInMatrix,
    _Disaster.crystalGrowth,
    _Disaster.sporeBloom,
  };

  /// True if a disaster is physically plausible on the CURRENT planet + biome.
  /// Airless worlds get no wind/rain; deserts don't snow; oceans don't burn, etc.
  bool _disasterPossible(_Disaster d) {
    // In the Earth system, exotic/sci-fi events are off the table.
    if (_inEarthSystem && _exoticDisasters.contains(d)) return false;
    final cold = _biome == Biome.iceCap ||
        _biome == Biome.tundra ||
        _biome == Biome.mountains;
    final wet = _biome == Biome.ocean ||
        _biome == Biome.grassland ||
        _biome == Biome.forest ||
        _biome == Biome.tundra ||
        _biome == Biome.wetland ||
        _biome == Biome.coastal;
    final dusty = _biome == Biome.desert ||
        _biome == Biome.barren ||
        _biome == Biome.volcanic ||
        _biome == Biome.volcano ||
        _biome == Biome.mountains;
    return switch (d) {
      _Disaster.none => false,
      // Precip needs air + moisture.
      _Disaster.rain || _Disaster.thunderstorm => _hasWeatherAir && wet,
      _Disaster.snow => _hasWeatherAir && cold,
      // Wind events need an atmosphere.
      _Disaster.dustStorm => _hasWeatherAir && dusty,
      _Disaster.tornado => _hasWeatherAir && !cold,
      // Fire needs oxygen + something to burn (not ocean/ice).
      _Disaster.fire =>
        _breathable && _biome != Biome.ocean && _biome != Biome.iceCap,
      // Crops to fail anywhere people farm.
      _Disaster.famine => true,
      // Outbreaks need people (always possible once populated).
      _Disaster.plague => true,
      // Space hazards — worse with a thin/absent atmosphere, possible anywhere.
      _Disaster.meteorShower || _Disaster.solarStorm => true,
      // War: always possible.
      _Disaster.nuke => true,
      // Hurricane: big warm-ocean storm — needs thick air + a wet/ocean world.
      _Disaster.hurricane =>
        _hasWeatherAir && (_biome == Biome.ocean || _biome == Biome.grassland),
      // Blizzard: extreme snow — cold biome OR a frozen world, with air.
      _Disaster.blizzard => _hasWeatherAir && (cold || _isFrozen),
      // Fog: any world with a real atmosphere.
      _Disaster.fog => _hasWeatherAir,
      // Acid rain: sulphur/CO2 haze — Venus-like or polluted thick atmospheres.
      _Disaster.acidRain =>
        _hasWeatherAir && (_co2Fraction > 0.3 || _pollution > 40),
      // Earthquake: volcanic/tectonic ground (no atmosphere required).
      _Disaster.earthquake => _isTectonic,
      // Radiation storm: unshielded worlds (no magnetosphere + thin air) or near
      // a flaring sun.
      _Disaster.radiationStorm => _isUnshielded || _solarFactor > 1.3,
      // Glass rain: molten-silicate rain on scorching rocky worlds.
      _Disaster.glassRain => _isHot && !_hasReducingAtmo,
      // Ammonia storm: hydrogen/methane/ammonia chemistry (giant-moon worlds).
      _Disaster.ammoniaStorm => _hasReducingAtmo,
      // Cryovolcanism: water/ammonia volcanism on frozen icy bodies.
      _Disaster.cryovolcanism => _isFrozen,
      // Miasma: rises from unburied bodies — only when the corpse backlog is high.
      _Disaster.miasma => _corpses > 3,
      // --- Wave 2 ---
      // Moving fronts, mostly world-gated.
      _Disaster.lavaFlow => _biome == Biome.volcanic || _isHot,
      _Disaster.sandworm => _biome == Biome.desert || _biome == Biome.barren,
      _Disaster.grayGoo => true, // nanites anywhere
      _Disaster.crawlingForest =>
        _biome == Biome.forest || _biome == Biome.grassland || _biome == Biome.ocean,
      _Disaster.rollingGlitch => true, // sim glitch — anywhere
      // Cosmic — anywhere, but bursts/eclipses make sense everywhere.
      _Disaster.auroraBloom => true,
      _Disaster.eclipse => true,
      _Disaster.gammaRayBurst => true,
      _Disaster.fallingStar => true,
      _Disaster.skyCrack => true,
      _Disaster.timeDilation => true,
      // Bio / matter.
      _Disaster.sporeBloom =>
        _biome == Biome.forest || _biome == Biome.grassland || _hasWeatherAir,
      _Disaster.crystalGrowth => true,
      _Disaster.biolumTide => _biome == Biome.ocean,
      _Disaster.chemicalRain => _hasWeatherAir,
      // Exotic precip — strongly per-world.
      _Disaster.diamondRain => _hasReducingAtmo, // ice/gas-giant chemistry
      _Disaster.ironSnow => _isHot,
      _Disaster.methaneDownpour => _hasReducingAtmo && _isFrozen, // Titan-like
      _Disaster.bloodRain => _hasWeatherAir && (_biome == Biome.desert ||
          _biome == Biome.barren || _biome == Biome.volcanic),
      _Disaster.blackRain => _hasWeatherAir && _radiation > 0.2, // fallout
      // Meta — society events, possible anywhere with people.
      _Disaster.commsBlackout => true,
      _Disaster.goldRush => true,
      _Disaster.refugeeInflux => _hasSpaceport,
      _Disaster.festival => true,
      _Disaster.cultUprising => true,
      _Disaster.aiAwakening => _computeSupply > 20,
      _Disaster.marketCrash => true,
      // Wildcards.
      _Disaster.alienBeacon => true,
      _Disaster.rainingFrogs => _hasWeatherAir,
      _Disaster.glitchInMatrix => _lastDisaster != _Disaster.none,
    };
  }

  /// Which disasters can strike at the current hostility — mild weather at low
  /// hostility, escalating to catastrophes at high — filtered to those that make
  /// sense on the current planet + biome.
  List<_Disaster> _hostilityPool() {
    final pool = <_Disaster>[
      // Benign / mild — always in the mix (most filter out as impossible).
      _Disaster.rain,
      _Disaster.snow,
      _Disaster.thunderstorm,
      _Disaster.dustStorm,
      _Disaster.fog,
      _Disaster.acidRain,
      // Exotic but condition-gated, so safe to always offer.
      _Disaster.glassRain,
      _Disaster.ammoniaStorm,
      _Disaster.cryovolcanism,
      _Disaster.miasma, // gated on corpse backlog
      // Wave 2: benign + positive + condition-gated flavour (mostly low-weight).
      _Disaster.auroraBloom,
      _Disaster.fallingStar,
      _Disaster.biolumTide,
      _Disaster.festival,
      _Disaster.goldRush,
      _Disaster.eclipse,
      _Disaster.diamondRain,
      _Disaster.ironSnow,
      _Disaster.methaneDownpour,
      _Disaster.bloodRain,
      _Disaster.blackRain,
      _Disaster.chemicalRain,
      _Disaster.crystalGrowth,
      _Disaster.sporeBloom,
      _Disaster.rainingFrogs,
      _Disaster.commsBlackout,
      _Disaster.refugeeInflux,
      _Disaster.timeDilation,
      _Disaster.rollingGlitch,
      _Disaster.alienBeacon,
    ];
    if (_hostility > 0.35) {
      pool.addAll([
        _Disaster.fire,
        _Disaster.tornado,
        _Disaster.famine,
        _Disaster.blizzard,
        _Disaster.earthquake,
        _Disaster.lavaFlow,
        _Disaster.sandworm,
        _Disaster.cultUprising,
        _Disaster.marketCrash,
      ]);
    }
    if (_hostility > 0.6) {
      pool.addAll([
        _Disaster.plague,
        _Disaster.solarStorm,
        _Disaster.meteorShower,
        _Disaster.hurricane,
        _Disaster.radiationStorm,
        _Disaster.grayGoo,
        _Disaster.crawlingForest,
        _Disaster.skyCrack,
        _Disaster.aiAwakening,
      ]);
    }
    if (_hostility > 0.85) {
      pool.addAll([_Disaster.nuke, _Disaster.gammaRayBurst]);
    }
    // Glitch in the Matrix can sneak in once there's a prior disaster to repeat.
    if (_lastDisaster != _Disaster.none) pool.add(_Disaster.glitchInMatrix);
    final filtered = pool.where(_disasterPossible).toList();
    // Fall back to space hazards if nothing weather-y fits (e.g. airless world).
    return filtered.isEmpty ? [_Disaster.meteorShower] : filtered;
  }

  /// Relative likelihood of a disaster GIVEN it's already possible here. Weights
  /// by the real environment: solar storms scale with proximity to the Sun + a
  /// thin atmosphere (less shielding); meteors with a thin atmosphere (less
  /// burn-up); dust storms dominate deserts; fire favours hot/dry O₂-rich worlds;
  /// snow the cold biomes; rain the wet ones; plague with crowding; famine on
  /// barren ground. 1.0 = baseline.
  double _disasterWeight(_Disaster d) {
    // Atmosphere shielding: 1 (airless) -> 0 (thick air).
    final airThin = 1 - _windFactor.clamp(0.0, 1.0);
    final hot = _biome == Biome.desert || _biome == Biome.volcanic;
    final cold = _biome == Biome.iceCap ||
        _biome == Biome.tundra ||
        _biome == Biome.mountains;
    final wet = _biome == Biome.ocean ||
        _biome == Biome.grassland ||
        _biome == Biome.forest ||
        _biome == Biome.wetland ||
        _biome == Biome.coastal;
    final dusty = _biome == Biome.desert ||
        _biome == Biome.barren ||
        _biome == Biome.volcanic ||
        _biome == Biome.volcano;
    final crowding = _housing <= 0 ? 0.0 : (_population / _housing).clamp(0.0, 1.0);
    return switch (d) {
      // Closer to the Sun (solarFactor up) + thin air => far more solar storms.
      _Disaster.solarStorm => 0.4 + _solarFactor * 1.2 + airThin * 1.5,
      // Less air = meteors reach the ground instead of burning up.
      _Disaster.meteorShower => 0.4 + airThin * 2.0,
      _Disaster.dustStorm => dusty ? 3.0 : 0.6,
      _Disaster.fire => (hot ? 2.5 : 1.0) * (_breathable ? 1.5 : 0.3),
      _Disaster.snow => cold ? 2.5 : 0.5,
      _Disaster.rain || _Disaster.thunderstorm => wet ? 2.0 : 0.6,
      // Crops fail more readily on poor ground.
      _Disaster.famine =>
        (_biomeFx.food < 1.0 ? 2.0 : 0.8) * (1 + _nuclearWinter),
      // Outbreaks scale with how crowded the housing is.
      _Disaster.plague => 0.5 + crowding * 2.0,
      _Disaster.tornado => wet ? 1.5 : 1.0,
      _Disaster.nuke => 1.0,
      // Benign weather is common where conditions allow.
      _Disaster.fog => _hasWeatherAir ? 1.5 : 0.0,
      _Disaster.acidRain => _co2Fraction > 0.3 ? 2.0 : 0.8,
      // Escalations are rarer than their base weather.
      _Disaster.hurricane => wet ? 1.2 : 0.3,
      _Disaster.blizzard => cold ? 1.8 : 0.4,
      _Disaster.earthquake => _isTectonic ? 2.0 : 0.2,
      // Condition-based exotics — strongly favoured where they fit.
      _Disaster.radiationStorm => 0.5 + _solarFactor + airThin * 1.0,
      _Disaster.glassRain => _isHot ? 2.5 : 0.2,
      _Disaster.ammoniaStorm => _hasReducingAtmo ? 2.5 : 0.2,
      _Disaster.cryovolcanism => _isFrozen ? 2.0 : 0.2,
      // Likelier the more bodies pile up (corpses per 100 pop).
      _Disaster.miasma =>
        _population <= 0 ? 0.0 : (_corpses / _population * 100).clamp(0.0, 4.0),
      // --- Wave 2: most are rare flavour (low base weight) so they sprinkle in. ---
      _Disaster.lavaFlow => _biome == Biome.volcanic ? 2.0 : 0.5,
      _Disaster.sandworm => _biome == Biome.desert ? 1.5 : 0.6,
      _Disaster.grayGoo => 0.4,
      _Disaster.crawlingForest => _biome == Biome.forest ? 1.5 : 0.5,
      _Disaster.rollingGlitch => 0.3,
      _Disaster.auroraBloom => 0.8,
      _Disaster.eclipse => 0.6,
      _Disaster.gammaRayBurst => 0.15,
      _Disaster.fallingStar => 0.5,
      _Disaster.skyCrack => 0.3,
      _Disaster.timeDilation => 0.3,
      _Disaster.sporeBloom => _biome == Biome.forest ? 1.5 : 0.5,
      _Disaster.crystalGrowth => 0.5,
      _Disaster.biolumTide => 1.0,
      _Disaster.chemicalRain => 0.6,
      _Disaster.diamondRain => 0.6,
      _Disaster.ironSnow => 0.8,
      _Disaster.methaneDownpour => 1.0,
      _Disaster.bloodRain => 0.5,
      _Disaster.blackRain => _radiation > 0.2 ? 1.5 : 0.0,
      _Disaster.commsBlackout => 0.5,
      _Disaster.goldRush => 0.6,
      _Disaster.refugeeInflux => 0.5,
      _Disaster.festival => 0.7,
      _Disaster.cultUprising => 0.3 + _rebellion,
      _Disaster.aiAwakening => 0.2,
      _Disaster.marketCrash => 0.4,
      _Disaster.alienBeacon => 0.25,
      _Disaster.rainingFrogs => 0.3,
      _Disaster.glitchInMatrix => 0.1,
      _Disaster.none => 0.0,
    };
  }

  /// Weighted random pick from the eligible pool using [_disasterWeight].
  _Disaster _pickDisaster(List<_Disaster> pool) {
    final weights = [for (final d in pool) math.max(0.01, _disasterWeight(d))];
    final total = weights.fold(0.0, (a, b) => a + b);
    var r = math.Random().nextDouble() * total;
    for (var i = 0; i < pool.length; i++) {
      r -= weights[i];
      if (r <= 0) return pool[i];
    }
    return pool.last;
  }

  void _envTick(double dt) {
    // --- Auto-disasters (driven by HOSTILITY) ---
    if (_hostility > 0.02 && _disaster == _Disaster.none && _population > 5) {
      _autoDisasterTimer -= dt;
      if (_autoDisasterTimer <= 0) {
        // Calm spell between strikes. Much longer than before (disasters were
        // firing back-to-back). Higher hostility shortens it; there's always a
        // generous floor so the colony gets clear weather to recover.
        _autoDisasterTimer =
            (260 - _hostility * 180) + math.Random().nextDouble() * 120;
        final pool = _hostilityPool();
        _disaster = _pickDisaster(pool); // weighted by planet + biome
        _disasterTime = _disaster.duration;
        _initStormTrack();
        _onDisasterStart();
      }
    }

    // --- Active disaster ---
    // Event modifiers are transient — reset to neutral each tick and re-apply
    // below for whatever event is running.
    _eventProductionMult = 1.0;
    _eventHappyBonus = 0.0;
    _eventSimWarp = 1.0;
    _commsDown = false;
    if (_disaster != _Disaster.none) {
      _disasterTime -= dt;
      switch (_disaster) {
        case _Disaster.rain:
          _stock[Commodity.water] = _stockOf(Commodity.water) + 3 * dt; // refill
        case _Disaster.snow:
          _stock[Commodity.water] = _stockOf(Commodity.water) + 1.5 * dt;
        case _Disaster.thunderstorm:
          _stock[Commodity.water] = _stockOf(Commodity.water) + 2 * dt;
          _damageBuildings(0.006, dt); // genuinely RARE lightning strike
        case _Disaster.fire:
          // ONE blaze is lit at the start (_onDisasterStart); it spreads on its
          // own (_fireTick). The event is over the moment every fire is out —
          // whether burned through, contained by roads, or put out by emergency
          // services.
          _pollution += 1 * dt;
          if (_fires.isEmpty) _disasterTime = 0; // all fires gone -> event ends
        case _Disaster.tornado:
          // A tornado wanders VERY slowly across the map; once it drifts off the
          // edge the disaster is over (handled by the shared off-map check).
          _moveStorm(dt, 0.4);
          _damageNearStorm(0.6, dt, 1.4); // only hits buildings near the funnel
        case _Disaster.hurricane:
          _moveStorm(dt, 1.6);
          _stock[Commodity.water] = _stockOf(Commodity.water) + 2 * dt;
          _damageNearStorm(0.5, dt, 3.0); // wider eye, slower
        case _Disaster.blizzard:
          _stock[Commodity.water] = _stockOf(Commodity.water) + 1.0 * dt;
          // Heavy cold strains the colony: a little extra emigration.
          _population = (_population - _population * 0.002 * dt * _forgiveMult)
              .clamp(0, 1e9);
        case _Disaster.fog:
          break; // benign — just reduced visibility (visual only)
        case _Disaster.acidRain:
          // Corrodes a little — light pollution + a trickle of building wear.
          _pollution += 1.5 * dt;
          _damageBuildings(0.02, dt);
        case _Disaster.earthquake:
          // Sharp ground shaking: brief but flattens structures.
          _damageBuildings(0.35, dt);
        case _Disaster.radiationStorm:
          _radiation = (_radiation + 0.3 * dt * _mitigate).clamp(0.0, 1.0);
        case _Disaster.glassRain:
          // Molten silicate shards: pollution + steady building damage.
          _pollution += 2 * dt;
          _damageBuildings(0.06, dt);
        case _Disaster.ammoniaStorm:
          // Toxic reducing-atmo storm: pollution + mild casualties.
          _pollution += 2 * dt;
          _population = (_population - _population * 0.002 * dt * _mitigate)
              .clamp(0, 1e9);
        case _Disaster.cryovolcanism:
          // Cryolava + venting: water gain but pollution + some damage.
          _stock[Commodity.water] = _stockOf(Commodity.water) + 1.5 * dt;
          _damageBuildings(0.04, dt);
        case _Disaster.miasma:
          // Decay gas from corpses: disease climbs (scaled by the backlog) +
          // pollution; clears when deathcare catches up. Drives a little death.
          final load = _population <= 0
              ? 0.5
              : (_corpses / _population * 20).clamp(0.2, 1.0);
          _disease = (_disease + 0.08 * load * dt * _mitigate).clamp(0.0, 1.0);
          _pollution += 1.5 * load * dt;
          _population = (_population - _population * 0.004 * load * dt * _mitigate)
              .clamp(0, 1e9);
        case _Disaster.meteorShower:
          _damageBuildings(0.08, dt);
          _population = (_population - _population * 0.003 * dt).clamp(0, 1e9);
        case _Disaster.dustStorm:
          _pollution += 3 * dt; // sky dims (cuts solar via pollution path)
        case _Disaster.nuke:
          // One-shot devastation: huge radiation + nuclear winter, mass casualty,
          // buildings flattened, fires.
          _radiation = (_radiation + 0.5 * dt / _Disaster.nuke.duration)
              .clamp(0.0, 1.0);
          _nuclearWinter = (_nuclearWinter + 0.4 * dt / _Disaster.nuke.duration)
              .clamp(0.0, 1.0);
          _population = (_population - _population * 0.02 * dt).clamp(0, 1e9);
          _pollution += 12 * dt;
          _damageBuildings(0.5, dt); // worst case, still spread over time
        case _Disaster.plague:
          // Outbreak: disease soars; emergency services + medicine soften it.
          _disease = (_disease + 0.15 * dt * _mitigate).clamp(0.0, 1.0);
          _population =
              (_population - _population * 0.015 * dt * _mitigate).clamp(0, 1e9);
        case _Disaster.famine:
          // Crops fail: drain the food stockpile fast.
          _stock[Commodity.food] =
              (_stockOf(Commodity.food) - _population * 0.05 * dt).clamp(0, 1e12);
        case _Disaster.solarStorm:
          // Geomagnetic storm: radiation up, electronics/power disrupted.
          _radiation = (_radiation + 0.25 * dt * _mitigate).clamp(0.0, 1.0);
          _stock[Commodity.compute] =
              (_stockOf(Commodity.compute) - 5 * dt).clamp(0, 1e12);
        // ===== Wave 2 =====
        // --- Moving fronts (ride the storm track) ---
        case _Disaster.lavaFlow:
          _moveStorm(dt, 1.2);
          _pollution += 4 * dt;
          _damageNearStorm(0.7, dt, 1.6); // flattens a path of buildings
        case _Disaster.sandworm:
          _moveStorm(dt, 4.0); // fast burrower
          _damageNearStorm(0.5, dt, 1.0); // narrow, swallows what's on its line
        case _Disaster.grayGoo:
          _moveStorm(dt, 1.0);
          _damageNearStorm(0.6, dt, 1.8); // consumes buildings
          _pollution += 1 * dt;
        case _Disaster.crawlingForest:
          _moveStorm(dt, 0.8); // creeps slowly
          _overgrowNearStorm(dt, 1.6); // covers tiles in vegetation (block build)
        case _Disaster.rollingGlitch:
          _moveStorm(dt, 3.0);
          // Buildings it covers are temporarily disabled, not destroyed — handled
          // visually; here it just adds a flicker of lost compute.
          _stock[Commodity.compute] =
              (_stockOf(Commodity.compute) - 2 * dt).clamp(0, 1e12);
        // --- Cosmic overlays ---
        case _Disaster.auroraBloom:
          _eventHappyBonus = 0.06; // a cheering light show
        case _Disaster.eclipse:
          // Sun blotted out -> solar power craters (via the nuclear-winter path
          // used by _powerFactor); model as a temporary winter-like dimming.
          _nuclearWinter = math.max(_nuclearWinter, 0.6);
        case _Disaster.gammaRayBurst:
          // Brief, lethal radiation that ignores the atmosphere.
          _radiation = (_radiation + 1.2 * dt / _Disaster.gammaRayBurst.duration)
              .clamp(0.0, 1.0);
          _population = (_population - _population * 0.02 * dt * _mitigate)
              .clamp(0, 1e9);
        case _Disaster.fallingStar:
          _eventHappyBonus = 0.04;
          _research += 4 * dt; // make a wish — a little inspiration
        case _Disaster.skyCrack:
          _eventHappyBonus = -0.05; // unsettling
          if (math.Random().nextDouble() < 0.1 * dt) _flattenOne();
        case _Disaster.timeDilation:
          // Warp the sim clock erratically for the duration.
          _eventSimWarp = 0.4 + (0.6 + 0.6 * math.sin(_disasterTime * 2)) * 1.5;
        // --- Bio / matter ---
        case _Disaster.sporeBloom:
          _moveStorm(dt, 0.6);
          _overgrowNearStorm(dt, 1.4);
          _stock[Commodity.food] =
              (_stockOf(Commodity.food) - _population * 0.01 * dt).clamp(0, 1e12);
        case _Disaster.crystalGrowth:
          _moveStorm(dt, 0.5);
          _overgrowNearStorm(dt, 1.2); // crystallises tiles
          _stock[Commodity.ore] = _stockOf(Commodity.ore) + 1.5 * dt; // mineable
        case _Disaster.biolumTide:
          _eventHappyBonus = 0.07; // glowing shores -> tourism cheer
        case _Disaster.chemicalRain:
          // Mutagenic/chemical: pollution + a coin-flip health swing.
          _pollution += 2 * dt;
          _disease = (_disease + 0.03 * dt * _mitigate).clamp(0.0, 1.0);
        // --- Exotic precipitation ---
        case _Disaster.diamondRain:
          _stock[Commodity.ore] = _stockOf(Commodity.ore) + 3 * dt; // precious
          _eventHappyBonus = 0.03;
        case _Disaster.ironSnow:
          _stock[Commodity.ore] = _stockOf(Commodity.ore) + 2 * dt; // free metal
          _damageBuildings(0.03, dt); // metallic precip dents roofs
        case _Disaster.methaneDownpour:
          _stock[Commodity.fuel] = _stockOf(Commodity.fuel) + 2 * dt; // hydrocarbons
        case _Disaster.bloodRain:
          _eventHappyBonus = -0.04; // ominous
          _stock[Commodity.food] =
              (_stockOf(Commodity.food) - _population * 0.005 * dt).clamp(0, 1e12);
        case _Disaster.blackRain:
          // Fallout precip: radiation + pollution.
          _radiation = (_radiation + 0.1 * dt * _mitigate).clamp(0.0, 1.0);
          _pollution += 3 * dt;
        // --- Society / meta ---
        case _Disaster.commsBlackout:
          _commsDown = true; // no immigration (applied in pop step)
        case _Disaster.goldRush:
          _eventProductionMult = 1.6; // boom
          _eventHappyBonus = 0.03;
        case _Disaster.refugeeInflux:
          // A wave of arrivals: population jumps toward housing.
          _population = (_population + 2.0 * dt).clamp(0, 1e9);
        case _Disaster.festival:
          _eventHappyBonus = 0.10; // big morale boost
          _eventProductionMult = 0.85; // everyone's off work
        case _Disaster.cultUprising:
          _rebellion = (_rebellion + 0.05 * dt).clamp(0.0, 1.0);
          _eventHappyBonus = -0.06;
        case _Disaster.aiAwakening:
          // The data centres wake up: research windfall, but unsettling.
          _research += 12 * dt;
          _eventHappyBonus = -0.03;
        case _Disaster.marketCrash:
          _funds = math.max(0, _funds - _funds * 0.02 * dt);
          _eventProductionMult = 0.8;
        // --- Wildcards ---
        case _Disaster.alienBeacon:
          _research += 6 * dt; // studying the monolith
          _eventHappyBonus = -0.02;
        case _Disaster.rainingFrogs:
          _eventHappyBonus = -0.02; // "ew"
        case _Disaster.glitchInMatrix:
          break; // handled on expiry (replays the last disaster)
        case _Disaster.none:
          break;
      }
      // A sweeping front (tornado, hurricane, lava flow, sandworm, …) is OVER the
      // moment it drifts off the map — end the disaster regardless of its timer.
      if (_stormLeftMap) {
        _stormLeftMap = false;
        _disasterTime = 0;
      }
      if (_disasterTime <= 0) _evolveDisaster();
    }

    // --- Radiation: a small space-background on thin-atmosphere worlds, plus
    //     lingering fallout. Decays slowly. Drives disease/mortality.
    final spaceBg = (1 - _windFactor.clamp(0.0, 1.0)) * 0.15; // less air = more
    _radiation = math.max(spaceBg, _radiation - 0.04 * dt).clamp(0.0, 1.0);

    // --- Nuclear winter: decays naturally; terraformers clear it faster. Cuts
    //     solar + food + raises cold (handled where _nuclearWinter is read).
    final clear = 0.02 + _terraformers * 0.03;
    _nuclearWinter = (_nuclearWinter - clear * dt).clamp(0.0, 1.0);

    // --- Terraforming (FAST for the demo): connected terraformers push progress;
    //     progress nudges the biome toward a green/breathable state + clears
    //     nuclear winter. (Real-world this would take ages.)
    if (_terraformers > 0) {
      _terraform = (_terraform + _terraformers * 0.05 * dt).clamp(0.0, 1.0);
      // At full terraform, flip a harsh biome to grassland (greened the world).
      if (_terraform >= 1.0 &&
          (_biome == Biome.barren ||
              _biome == Biome.desert ||
              _biome == Biome.volcanic)) {
        _biome = Biome.grassland;
        _terraform = 0;
      }
    }
  }

  /// Flatten one random building into rubble (disasters). Its footprint cells
  /// become rubble (cosmetic debris, blocks placement) rather than vanishing, so
  /// damage is visible and recoverable (bulldoze to clear). No refund.
  void _flattenOne() {
    final keys = [..._grown, ..._utils.keys];
    if (keys.isEmpty) return;
    _flattenAt(keys[math.Random().nextInt(keys.length)]);
  }

  /// Flatten the building at anchor [k] into rubble over its whole footprint.
  void _flattenAt(int k) {
    for (final c in _cellsOf(k)) {
      _rubble.add(c);
      _fires.remove(c); // a flattened building stops burning
    }
    _footprint.removeWhere((cell, anchor) => anchor == k);
    _grown.remove(k);
    _utils.remove(k);
    _zones.remove(k);
    _abandoned.remove(k);
    _growProgress.remove(k);
    _buildStyle.remove(k);
    _decompressTimer.remove(k);
    if (_landerPad == k) _landerPad = null;
    _recompute();
  }

  /// Probabilistic disaster damage: at [perSec] expected buildings/second, flatten
  /// at most one per tick (gentler + spread out over the now-long disasters).
  void _damageBuildings(double perSec, double dt) {
    if (math.Random().nextDouble() < (perSec * dt).clamp(0.0, 1.0)) {
      _flattenOne();
    }
  }

  // ---- Fire: a per-tile, spreading hazard ----

  /// A tile that can CATCH fire: a standing building (zoned or utility) that
  /// isn't already rubble or burning. Roads/empty ground/water don't burn — they
  /// act as firebreaks.
  bool _flammable(int k) =>
      !_rubble.contains(k) &&
      (_grown.contains(k) || _anchorOf(k) != null);

  /// Local fire-suppression strength at a tile, 0..~1+: nearby CONNECTED
  /// emergency-service / police stations fight the blaze. Falls off with
  /// Chebyshev distance up to a small response radius.
  double _suppressionAt(int k) {
    final x = k % _grid, y = k ~/ _grid;
    var s = 0.0;
    for (final e in _activeSpecs) {
      final t = e.value.type;
      if (t != 'emergency' && t != 'police') continue;
      final ax = e.key % _grid, ay = e.key ~/ _grid;
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
  void _igniteRandom() {
    final candidates = [
      for (final k in {..._grown, ..._utils.keys})
        if (_flammable(k) && !_fires.containsKey(k)) k
    ];
    if (candidates.isEmpty) return;
    _fires[candidates[math.Random().nextInt(candidates.length)]] = 0.4;
  }

  /// Advance every active fire: grow intensity, damage the building (destroying
  /// it at full burn), SPREAD to flammable orthogonal neighbours (roads + a
  /// random firebreak chance stop it), and let emergency services PUT IT OUT.
  /// Fires also self-extinguish without fuel/air.
  void _fireTick(double dt) {
    if (_fires.isEmpty) return;
    final rnd = math.Random();
    final destroyed = <int>[];
    final extinguished = <int>[];
    final ignite = <int>[];
    // Fire can't burn without oxygen (sealed/airless worlds smother it).
    final canBurn = _surface.o2Fraction >= 0.05;

    _fires.forEach((k, intensity) {
      // Suppression eats intensity; without responders it climbs.
      final suppress = _suppressionAt(k);
      var i = intensity + (0.18 - suppress * 0.6) * dt;
      if (!canBurn) i -= 0.5 * dt; // smothered
      if (!_flammable(k)) {
        extinguished.add(k); // building already gone
        return;
      }
      if (i <= 0.02) {
        extinguished.add(k);
        return;
      }
      i = i.clamp(0.0, 1.0);
      _fires[k] = i;
      // Burning damages the building; at full burn it collapses to rubble.
      if (i >= 1.0) {
        destroyed.add(k);
        return;
      }
      // Spread: a hot fire reaches into flammable orthogonal neighbours. Roads
      // (and empty/water tiles) aren't flammable, so they break the spread; a
      // random chance also halts it (firebreak / a building that doesn't catch).
      if (canBurn && i > 0.55) {
        for (final nb in _neighbours(k)) {
          if (!_flammable(nb) || _fires.containsKey(nb)) continue;
          final spreadChance = (0.5 - _suppressionAt(nb) * 0.4) * dt;
          if (rnd.nextDouble() < spreadChance.clamp(0.0, 1.0)) {
            ignite.add(nb);
          }
        }
      }
    });
    for (final k in ignite) {
      _fires[k] = 0.35;
    }
    for (final k in extinguished) {
      _fires.remove(k);
    }
    for (final k in destroyed) {
      _fires.remove(k);
      _flattenAt(k); // burned to the ground
      _pollution += 4; // smoke
    }
  }

  /// When a disaster expires it may EVOLVE into a related one rather than just
  /// clearing: rain ⇄ thunderstorm ⇄ hurricane, snow → blizzard. Escalation is
  /// likelier at high hostility; otherwise it de-escalates or clears. The
  /// successor only takes hold if it's possible on this world.
  void _evolveDisaster() {
    // The disaster that's ENDING becomes the "previous" one a future "glitch in
    // the matrix" can replay (never record glitch itself). Captured before it
    // changes below.
    final ending = _disaster;
    if (ending != _Disaster.glitchInMatrix) _lastDisaster = ending;
    // Candidate successors per disaster: (next, chance). Picked top-down.
    final chains = <_Disaster, List<(_Disaster, double)>>{
      _Disaster.rain: [
        (_Disaster.thunderstorm, 0.25 + _hostility * 0.35),
      ],
      _Disaster.thunderstorm: [
        (_Disaster.hurricane, 0.12 + _hostility * 0.3),
        (_Disaster.rain, 0.4), // devolve to plain rain
      ],
      _Disaster.hurricane: [
        (_Disaster.thunderstorm, 0.6), // always winds down
      ],
      _Disaster.snow: [
        (_Disaster.blizzard, 0.2 + _hostility * 0.4),
      ],
      _Disaster.blizzard: [
        (_Disaster.snow, 0.7),
      ],
    };
    // Glitch in the Matrix: déjà-vu — instantly re-run the disaster before it.
    if (_disaster == _Disaster.glitchInMatrix &&
        _lastDisaster != _Disaster.none &&
        _lastDisaster != _Disaster.glitchInMatrix &&
        _disasterPossible(_lastDisaster)) {
      _disaster = _lastDisaster;
      _disasterTime = _lastDisaster.duration;
      _initStormTrack();
      return;
    }
    final next = chains[_disaster];
    if (next != null) {
      for (final (cand, chance) in next) {
        if (_disasterPossible(cand) && math.Random().nextDouble() < chance) {
          _disaster = cand;
          _disasterTime = cand.duration;
          _initStormTrack();
          return;
        }
      }
    }
    _disaster = _Disaster.none; // otherwise the weather clears
    _beaconCell = null; // the monolith departs with the event
  }

  /// Tools that support the single / paint / rect placement styles (Utility is
  /// tap-only since it costs ore + is single-placement).
  bool get _toolPaintable =>
      _tool == _Tool.zone ||
      _tool == _Tool.road ||
      _tool == _Tool.bulldoze ||
      _tool == _Tool.retrofit ||
      _tool == _Tool.support;

  /// Disasters that travel across the map as a tracked epicentre (the painter
  /// draws their front at [_stormX]/[_stormY]).
  bool get _isMovingFront => const {
        _Disaster.tornado,
        _Disaster.hurricane,
        _Disaster.lavaFlow,
        _Disaster.sandworm,
        _Disaster.grayGoo,
        _Disaster.crawlingForest,
        _Disaster.rollingGlitch,
        _Disaster.sporeBloom,
        _Disaster.crystalGrowth,
      }.contains(_disaster);

  /// One-shot setup when a new disaster begins. Currently: drop the alien-beacon
  /// monolith onto an empty grid tile so it's a real object on the map, not a
  /// screen overlay. Cleared again when the event ends.
  void _onDisasterStart() {
    if (_disaster == _Disaster.alienBeacon) {
      _beaconCell = _randomEmptyCell();
    }
    // Fire starts as a SINGLE blaze; it spreads from there (and the event ends
    // once every fire is out).
    if (_disaster == _Disaster.fire) {
      _igniteRandom();
    }
  }

  /// A random empty, in-bounds cell (no road/zone/util/rubble/crystal/hub), or
  /// null if the grid is full.
  int? _randomEmptyCell() {
    final free = <int>[];
    for (var k = 0; k < _grid * _grid; k++) {
      if (k == _hubKey) continue;
      if (_roads.contains(k) ||
          _zones.containsKey(k) ||
          _anchorOf(k) != null ||
          _rubble.contains(k) ||
          _crystal.contains(k)) {
        continue;
      }
      free.add(k);
    }
    if (free.isEmpty) return null;
    return free[math.Random().nextInt(free.length)];
  }

  /// Seed a moving-storm track (tornado/hurricane): drop it at a random edge and
  /// send it across the grid on a random heading, so it walks over the colony.
  void _initStormTrack() {
    _stormLeftMap = false;
    final r = math.Random();
    final fromLeft = r.nextBool();
    _stormX = fromLeft ? 0 : _grid.toDouble();
    _stormY = r.nextDouble() * _grid;
    final ang = (fromLeft ? 0 : math.pi) + (r.nextDouble() - 0.5) * 1.2;
    final speed = 1.5 + r.nextDouble() * 1.5; // cells/sec base
    _stormVX = math.cos(ang) * speed;
    _stormVY = math.sin(ang) * speed;
  }

  /// Advance the storm epicentre. By default it [bounce]s softly off the grid
  /// edges to stay on the map for the disaster's duration. With [bounce] false it
  /// drifts straight off; returns TRUE once it has fully left the map (a margin
  /// past the edge) so the caller can end the disaster.
  bool _moveStorm(double dt, double speedMul, {bool bounce = false}) {
    _stormX += _stormVX * speedMul * dt;
    _stormY += _stormVY * speedMul * dt;
    if (bounce) {
      if (_stormX < 0 || _stormX > _grid) _stormVX = -_stormVX;
      if (_stormY < 0 || _stormY > _grid) _stormVY = -_stormVY;
      _stormX = _stormX.clamp(0.0, _grid.toDouble());
      _stormY = _stormY.clamp(0.0, _grid.toDouble());
      return false;
    }
    // No bounce: it's gone once it's a couple of cells past any edge. Record it
    // so the tick can END the disaster (a sweeping front is over when it leaves).
    const margin = 2.0;
    final gone = _stormX < -margin ||
        _stormX > _grid + margin ||
        _stormY < -margin ||
        _stormY > _grid + margin;
    if (gone) _stormLeftMap = true;
    return gone;
  }

  /// Flatten a building only if it lies within [radius] cells of the storm
  /// epicentre — so a tornado damages what it actually passes over, not random
  /// tiles across the whole colony.
  void _damageNearStorm(double perSec, double dt, double radius) {
    if (math.Random().nextDouble() >= (perSec * dt).clamp(0.0, 1.0)) return;
    final r2 = radius * radius;
    final near = <int>[];
    for (final k in [..._grown, ..._utils.keys]) {
      final cx = k % _grid + 0.5, cy = k ~/ _grid + 0.5;
      final dx = cx - _stormX, dy = cy - _stormY;
      if (dx * dx + dy * dy <= r2) near.add(k);
    }
    if (near.isEmpty) return;
    _flattenAt(near[math.Random().nextInt(near.length)]);
  }

  /// Overgrow tiles near the storm epicentre (spore bloom / crawling forest /
  /// crystal growth): empty cells within [radius] get covered (added to
  /// [_crystal]), blocking placement until bulldozed. A building it reaches is
  /// flattened first, then its rubble overgrows.
  void _overgrowNearStorm(double dt, double radius) {
    if (math.Random().nextDouble() >= (0.8 * dt).clamp(0.0, 1.0)) return;
    final cx = _stormX.round(), cy = _stormY.round();
    final r = radius.ceil();
    for (var dy = -r; dy <= r; dy++) {
      for (var dx = -r; dx <= r; dx++) {
        if (dx * dx + dy * dy > radius * radius) continue;
        final x = cx + dx, y = cy + dy;
        if (x < 0 || x >= _grid || y < 0 || y >= _grid) continue;
        final k = _key(x, y);
        if (k == _hubKey) continue;
        // Cover only a fraction per pass so it spreads visibly over time.
        if (math.Random().nextDouble() < 0.25) _crystal.add(k);
      }
    }
    _recompute();
  }

  static const _required = ['safety', 'health', 'leisure'];
  double _serviceCoverage() {
    final pop = _population <= 0 ? 1.0 : _population;
    var minCov = 1.0;
    for (final t in _required) {
      final cov = ((_services[t] ?? 0) / pop).clamp(0.0, 1.0);
      if (cov < minCov) minCov = cov;
    }
    return minCov;
  }

  // ---- Network ----

  /// Network roots: the landing-site marker (hub) PLUS every spaceport. The hub
  /// is no longer special — a colony works off any road-connected spaceport, so
  /// you can bulldoze the landing pad once a real spaceport anchors the network.
  Set<int> get _netRoots => {
        _hubKey,
        for (final e in _utils.entries)
          if (e.value.type == 'spaceport') ..._cellsOf(e.key),
      };

  void _recompute() {
    // A virtual 'root' node bridges to the hub cell + every spaceport cell, so
    // anything road-connected to ANY of them counts as connected.
    final net = CityNetwork(hub: 'root');
    final roots = _netRoots;
    bool isNet(int k) => _roads.contains(k) || roots.contains(k);
    for (final r in roots) {
      net.addRoad('root', '$r');
    }
    for (final k in {..._roads, ...roots}) {
      for (final nb in _neighbours(k)) {
        if (isNet(nb)) net.addRoad('$k', '$nb');
      }
    }
    for (final k in [..._zones.keys, ..._utils.keys]) {
      // 8-way over the building's whole footprint: it's road-served if a road
      // touches ANY of its cells (corner included). The anchor is the node.
      for (final cell in _cellsOf(k)) {
        for (final nb in _neighbours8(cell)) {
          if (isNet(nb)) net.addRoad('$k', '$nb');
        }
      }
    }
    _connectedCells = net
        .connectedSet()
        .where((s) => s != 'root')
        .map(int.parse)
        .toSet();
    _computeTraffic();
    _computeWasteSites();
    // Remember we ever had a working spaceport, so a later 0-count reads as
    // "demolished" rather than "never built".
    if (_hasSpaceport) _everHadSpaceport = true;
  }

  /// Litter tiles = the cells ON and immediately AROUND each waste-producing
  /// building (anything with housing, plus commercial zones — people generate
  /// rubbish where they live + shop). Empty streets far from buildings stay
  /// clean. The painter renders garbage/sewage only on these tiles.
  void _computeWasteSites() {
    _wasteSites.clear();
    final seen = <int>{};
    void addAround(int anchor) {
      for (final cell in _cellsOf(anchor)) {
        if (seen.add(cell)) _wasteSites.add(cell);
        for (final nb in _neighbours8(cell)) {
          // Litter spills onto the kerb/yard, but never onto a road lane.
          if (!_roads.contains(nb) && nb != _hubKey && seen.add(nb)) {
            _wasteSites.add(nb);
          }
        }
      }
    }

    for (final k in _grown) {
      final z = _zones[k];
      if (z == null || !_isConnected(k) || _abandoned.contains(k)) continue;
      // Residential + commercial zones produce household waste.
      if (z.kind == 'residential' || z.kind == 'commercial') addAround(k);
    }
    for (final e in _utils.entries) {
      if (!_isConnected(e.key) || _abandoned.contains(e.key)) continue;
      if (e.value.housing > 0) addAround(e.key); // e.g. the spaceport crew
    }
  }

  /// Per-road traffic load: BFS the road network from the hub to get each road
  /// tile's shortest path back, then every connected BUILDING routes its trips
  /// along the road path to the hub, adding load to each tile it crosses. Roads
  /// not on ANY building's route (spurs, roads-to-nowhere) stay at zero, so no
  /// commuters are drawn on them. Normalised to 0..1; the peak is the congestion.
  void _computeTraffic() {
    _traffic.clear();
    // Multi-source BFS from EVERY network root (hub + spaceports) over the road
    // cells -> parent pointers. Each tile thus routes to its NEAREST root.
    final roots = _netRoots;
    final parent = <int, int>{};
    final seen = <int>{...roots};
    final q = <int>[...roots];
    var qi = 0;
    bool isRoad(int k) => _roads.contains(k) || roots.contains(k);
    while (qi < q.length) {
      final n = q[qi++];
      for (final nb in _neighbours(n)) {
        if (isRoad(nb) && seen.add(nb)) {
          parent[nb] = n;
          q.add(nb);
        }
      }
    }
    // Each connected building enters at an adjacent road tile and walks the
    // parent chain to its nearest root, loading every road tile on the way.
    final buildings = [
      ..._grown.where((k) => _isConnected(k) && !_abandoned.contains(k)),
      ..._utils.keys.where((k) => _isConnected(k) && !_abandoned.contains(k)),
    ];
    var peak = 0.0;
    for (final b in buildings) {
      // Adjacent road tile (incl. diagonal/corner, across the whole footprint).
      final entry = _roadEntry(b, isRoad, seen);
      if (entry == null) continue;
      var cur = entry;
      while (true) {
        if (!roots.contains(cur)) {
          final t = (_traffic[cur] ?? 0) + 1;
          _traffic[cur] = t;
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
      _traffic.updateAll((k, v) => (v / peak).clamp(0.0, 1.0));
    }
    _congestion = (peak / 8).clamp(0.0, 1.0);
  }

  double _trafficAt(int key) => _traffic[key] ?? 0;

  /// Orthogonal (4-way) neighbours — used for the road network topology, so a
  /// road only links to a road sharing an edge (no diagonal road jumps).
  Iterable<int> _neighbours(int k) sync* {
    final x = k % _grid, y = k ~/ _grid;
    if (x > 0) yield _key(x - 1, y);
    if (x < _grid - 1) yield _key(x + 1, y);
    if (y > 0) yield _key(x, y - 1);
    if (y < _grid - 1) yield _key(x, y + 1);
  }

  /// 8-way neighbours — used only to attach a BUILDING to the road net. A
  /// building tucked against a road corner (diagonally adjacent) still counts as
  /// road-served, so you don't need a road on every orthogonal side.
  Iterable<int> _neighbours8(int k) sync* {
    final x = k % _grid, y = k ~/ _grid;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = x + dx, ny = y + dy;
        if (nx < 0 || nx >= _grid || ny < 0 || ny >= _grid) continue;
        yield _key(nx, ny);
      }
    }
  }

  // ---- Multi-tile footprints ----

  /// The cells a [spec] anchored at ([ax],[ay]) would cover. The anchor is the
  /// min-x/min-y corner; the footprint extends +X (east) and +Y (south).
  Iterable<int> _footCells(int ax, int ay, CitySpec spec) sync* {
    for (var dy = 0; dy < spec.footH; dy++) {
      for (var dx = 0; dx < spec.footW; dx++) {
        yield _key(ax + dx, ay + dy);
      }
    }
  }

  /// Anchor cell of whatever building (single- or multi-tile) covers [k], or
  /// null if [k] is empty. Single-tile buildings are their own anchor.
  int? _anchorOf(int k) {
    if (_utils.containsKey(k)) return k;
    return _footprint[k];
  }

  /// True if a [spec] anchored at ([ax],[ay]) fits on the grid and every covered
  /// cell is free (no road/zone/util/hub).
  bool _footprintFree(int ax, int ay, CitySpec spec, {int? ignoreAnchor}) {
    if (ax + spec.footW > _grid || ay + spec.footH > _grid) return false;
    for (final c in _footCells(ax, ay, spec)) {
      if (c == _hubKey) return false;
      if (_roads.contains(c) ||
          _zones.containsKey(c) ||
          _rubble.contains(c) ||
          _crystal.contains(c)) {
        return false;
      }
      final a = _anchorOf(c);
      if (a != null && a != ignoreAnchor) return false;
    }
    return true;
  }

  /// Every cell a placed building (at anchor [k]) occupies. Single-tile zones &
  /// utils are just [k]; multi-tile utils expand over their footprint.
  Iterable<int> _cellsOf(int k) {
    final u = _utils[k];
    if (u == null) return [k];
    return _footCells(k % _grid, k ~/ _grid, u);
  }

  /// Road tiles in the BFS tree adjacent (8-way) to ANY cell of the building at
  /// anchor [k] — a multi-tile building is served if a road touches any edge.
  int? _roadEntry(int k, bool Function(int) isRoad, Set<int> seen) {
    for (final cell in _cellsOf(k)) {
      for (final nb in _neighbours8(cell)) {
        if (isRoad(nb) && seen.contains(nb)) return nb;
      }
    }
    return null;
  }

  // ---- Editing ----

  void _onTapCell(int x, int y) {
    final k = _key(x, y);
    // The hub IS the lander/landing site — tapping it always opens its menu,
    // whatever tool is held (it can't be zoned/bulldozed away).
    if (k == _hubKey) {
      _showLanderMenu();
      return;
    }
    // Inspect tool: tap a building (or any covered tile) for its context menu.
    if (_tool == _Tool.inspect) {
      final anchor = _anchorOf(k);
      if (anchor != null && _utils.containsKey(anchor)) {
        _showBuildingMenu(anchor, _utils[anchor]!);
      }
      return;
    }
    // Rect style (Zone/Road tools): first tap sets a corner, second fills the
    // rectangle between them.
    if (_paintStyle == _PaintMode.rect && _toolPaintable) {
      setState(() {
        if (_rectStart == null) {
          _rectStart = k;
          _rectHover = k;
        } else {
          _fillRect(_rectStart!, k);
          _rectStart = null;
          _rectHover = null;
        }
      });
      return;
    }
    setState(() {
      _blocked = null;
      switch (_tool) {
        case _Tool.inspect:
          break; // handled above
        case _Tool.retrofit:
          _retrofitCell(k);
        case _Tool.support:
          if (_support.contains(k)) {
            _support.remove(k);
          } else {
            _clearCell(k);
            _support.add(k);
          }
        case _Tool.bulldoze:
          _clearCell(k);
        case _Tool.road:
          if (_roads.contains(k)) {
            _removeRoad(k);
          } else {
            _clearCell(k, keepSupport: true); // road runs ON the platform
            _addRoad(k);
          }
        case _Tool.utility:
          final anchor = _anchorOf(k);
          if (anchor != null && _utils[anchor]?.type == _selectedUtil.type) {
            // Tapping any tile of an existing same-type building removes it.
            _clearCell(anchor);
          } else if (_selectedUtil.type == 'o2harvester' && !_o2Harvestable) {
            _blocked =
                '${_body.name} has no harvestable oxygen — use Electrolysis instead.';
          } else if (_selectedUtil.type == 'mine' &&
              _colonyMode != _ColonyStyle.open) {
            // No ground to dig on a cloud city / orbital station.
            _blocked = _colonyMode == _ColonyStyle.orbital
                ? 'No surface to mine in orbit.'
                : 'No ground to mine on a cloud city.';
          } else if (!_unlocked(_selectedUtil)) {
            _blocked =
                '${_selectedUtil.label} unlocks at population ${_selectedUtil.unlockPop}.';
          } else if (!_footprintFree(x, y, _selectedUtil)) {
            _blocked = _selectedUtil.cellCount > 1
                ? 'No room — ${_selectedUtil.label} needs a clear ${_selectedUtil.footW}×${_selectedUtil.footH} area here.'
                : 'Cell occupied.';
          } else if (!_footprintSupported(
              x, y, _selectedUtil.footW, _selectedUtil.footH)) {
            _blocked = 'Needs $_supportLabel support here — build the structure first.';
          } else if (_stockOf(Commodity.ore) < _selectedUtil.buildCost) {
            _blocked =
                'Need ${_selectedUtil.buildCost.toStringAsFixed(0)} ore for ${_selectedUtil.label}.';
          } else {
            _stock[Commodity.ore] =
                _stockOf(Commodity.ore) - _selectedUtil.buildCost;
            _placeUtil(k, _selectedUtil);
          }
        case _Tool.zone:
          final z = ZoneType(_zoneKind, _density);
          final cur = _zones[k];
          if (cur != null && cur.kind == z.kind && cur.density == z.density) {
            _clearCell(k);
          } else if (!_footprintSupported(x, y, 1, 1)) {
            _blocked = 'Needs $_supportLabel support here — build the structure first.';
          } else {
            _clearCell(k, keepSupport: true); // build ON the platform, keep it
            _zones[k] = z;
            if (_autoRoads) _autoRoadAround(k);
          }
      }
      _recompute();
    });
  }

  /// Cells to highlight under the cursor for the active placement tool. Empty
  /// for inspect/no-hover. For the Utility tool it's the selected building's
  /// footprint anchored at the hover cell; for zone/road/support/bulldoze it's
  /// the single hovered cell.
  Set<int> _hoverHighlight() {
    final h = _hoverCell;
    if (h == null) return const {};
    final hx = h % _grid, hy = h ~/ _grid;
    if (_tool == _Tool.utility) {
      final spec = _selectedUtil;
      final out = <int>{};
      for (var dy = 0; dy < spec.footH; dy++) {
        for (var dx = 0; dx < spec.footW; dx++) {
          final x = hx + dx, y = hy + dy;
          if (x < _grid && y < _grid) out.add(_key(x, y));
        }
      }
      return out;
    }
    if (_tool == _Tool.zone ||
        _tool == _Tool.road ||
        _tool == _Tool.support ||
        _tool == _Tool.bulldoze ||
        _tool == _Tool.retrofit) {
      return {h};
    }
    return const {};
  }

  /// Drag-paint a cell: like a tap but SETs rather than toggles (so dragging
  /// across already-placed tiles never erases them). Road/zone/bulldoze only —
  /// utilities cost ore and are single-placement, so they stay tap-only.
  void _onPaintCell(int x, int y) {
    final k = _key(x, y);
    if (k == _hubKey) return;
    setState(() {
      _blocked = null;
      switch (_tool) {
        case _Tool.bulldoze:
          _clearCell(k);
        case _Tool.road:
          if (!_roads.contains(k)) {
            _clearCell(k, keepSupport: true); // road runs ON the platform
            _addRoad(k);
          }
        case _Tool.zone:
          final z = ZoneType(_zoneKind, _density);
          final cur = _zones[k];
          if (cur == null || cur.kind != z.kind || cur.density != z.density) {
            _clearCell(k, keepSupport: true); // build ON the platform, keep it
            _zones[k] = z;
            if (_autoRoads) _autoRoadAround(k);
          }
        case _Tool.retrofit:
          _retrofitCell(k);
        case _Tool.support:
          if (!_support.contains(k)) {
            _clearCell(k);
            _support.add(k);
          }
        case _Tool.utility:
        case _Tool.inspect:
          break; // tap-only
      }
      _recompute();
    });
  }

  /// Retrofit the building covering [k] to the style the CURRENT environment
  /// calls for (open<->domed; orbital is fixed). Keeps the building's type +
  /// footprint + growth; costs ore scaled by footprint. No-op if already in the
  /// target style or the cell is empty.
  void _retrofitCell(int k) {
    // Roads retrofit too: seal an open road into a tube (or unseal it) to match
    // the CURRENT air, for a small ore cost.
    if (_roads.contains(k)) {
      final wantSealed = !_surface.breathable;
      if (_roadSealed.contains(k) == wantSealed) return; // already right
      const cost = 4.0;
      if (_stockOf(Commodity.ore) < cost) {
        _blocked = 'Need ${cost.toStringAsFixed(0)} ore to retrofit.';
        return;
      }
      _stock[Commodity.ore] = _stockOf(Commodity.ore) - cost;
      if (wantSealed) {
        _roadSealed.add(k);
      } else {
        _roadSealed.remove(k);
      }
      return;
    }
    // Zoned/grown buildings live in _zones (not _utils/_footprint), so resolve
    // the anchor for BOTH: a util/footprint cell OR a zone tile.
    final anchor = _anchorOf(k) ?? (_zones.containsKey(k) ? k : null);
    if (anchor == null) return;
    final target = _currentStyle.index;
    if (_styleOf(anchor) == target) return;
    final cells = _utils[anchor] != null ? _utils[anchor]!.cellCount : 1;
    final cost = 12.0 * cells;
    if (_stockOf(Commodity.ore) < cost) {
      _blocked = 'Need ${cost.toStringAsFixed(0)} ore to retrofit.';
      return;
    }
    _stock[Commodity.ore] = _stockOf(Commodity.ore) - cost;
    _buildStyle[anchor] = target;
  }

  /// Fill the rectangle spanning two corner cells with the active Zone or Road
  /// tool (used by the Rect paint style). Bounded to keep the loop cheap.
  void _fillRect(int a, int b) {
    final ax = a % _grid, ay = a ~/ _grid;
    final bx = b % _grid, by = b ~/ _grid;
    final x0 = math.min(ax, bx), x1 = math.max(ax, bx);
    final y0 = math.min(ay, by), y1 = math.max(ay, by);
    _blocked = null;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final k = _key(x, y);
        if (k == _hubKey) continue;
        if (_tool == _Tool.retrofit) {
          _retrofitCell(k);
        } else if (_tool == _Tool.support) {
          if (!_support.contains(k)) {
            _clearCell(k);
            _support.add(k);
          }
        } else if (_tool == _Tool.bulldoze) {
          _clearCell(k);
        } else if (_tool == _Tool.road) {
          if (!_roads.contains(k)) {
            _clearCell(k, keepSupport: true); // road runs ON the platform
            _addRoad(k);
          }
        } else {
          final z = ZoneType(_zoneKind, _density);
          _clearCell(k, keepSupport: true); // build ON the platform, keep it
          _zones[k] = z;
          if (_autoRoads) _autoRoadAround(k);
        }
      }
    }
    _recompute();
  }

  /// Auto-roads: ensure a painted zone tile has road frontage. If no road (incl.
  /// corner) touches it yet, drop a road on the empty neighbour nearest the
  /// network root so the tile becomes connected without manual road-laying.
  void _autoRoadAround(int k) {
    // Already road-served? nothing to do.
    for (final nb in _neighbours8(k)) {
      if (_roads.contains(nb) || _netRoots.contains(nb)) return;
    }
    // Pick the orthogonal neighbour closest to the hub and pave it (if empty).
    final hx = _hubKey % _grid, hy = _hubKey ~/ _grid;
    int? best;
    double bestD = double.infinity;
    for (final nb in _neighbours(k)) {
      if (nb == _hubKey || _roads.contains(nb)) continue;
      if (_zones.containsKey(nb) || _anchorOf(nb) != null) continue;
      final nx = nb % _grid, ny = nb ~/ _grid;
      final d = ((nx - hx) * (nx - hx) + (ny - hy) * (ny - hy)).toDouble();
      if (d < bestD) {
        bestD = d;
        best = nb;
      }
    }
    if (best != null) _addRoad(best);
  }

  /// Stamp a multi-tile utility: register the building at its anchor and map all
  /// covered cells back to it. The painter/economy key off the anchor.
  void _placeUtil(int anchor, CitySpec spec) {
    _clearCell(anchor, keepSupport: true); // build ON the platform, keep it
    _utils[anchor] = spec;
    _buildStyle[anchor] = _currentStyle.index; // capture the build style
    for (final c in _footCells(anchor % _grid, anchor ~/ _grid, spec)) {
      if (c != anchor) _footprint[c] = anchor;
    }
  }

  /// Lay a road tile, capturing whether it's a sealed (tube) road — i.e. it was
  /// built while the air was hostile. The captured style is preserved (it does
  /// NOT flip when the world is later terraformed), mirroring buildings.
  void _addRoad(int k) {
    _roads.add(k);
    if (_surface.breathable) {
      _roadSealed.remove(k);
    } else {
      _roadSealed.add(k);
    }
  }

  void _removeRoad(int k) {
    _roads.remove(k);
    _roadSealed.remove(k);
  }

  /// Clear a cell. [keepSupport] preserves the platform/truss/lift-frame on the
  /// tile — used when PLACING a building (it builds ON the support), so the
  /// support isn't stripped out from under it (which would instantly doom an
  /// ocean-platform building). Bulldozing leaves it false to remove the support.
  void _clearCell(int k, {bool keepSupport = false}) {
    // Resolve to the building's anchor first so clearing ANY covered tile of a
    // multi-tile building removes the whole thing.
    final anchor = _anchorOf(k) ?? k;
    if (_grown.contains(anchor)) {
      _stock[Commodity.ore] =
          _stockOf(Commodity.ore) + _zoneBuildCost * _refundFraction;
    }
    final u = _utils[anchor];
    if (u != null) {
      _stock[Commodity.ore] =
          _stockOf(Commodity.ore) + u.buildCost * _refundFraction;
      // Free every cell the footprint covered.
      for (final c in _footCells(anchor % _grid, anchor ~/ _grid, u)) {
        _footprint.remove(c);
      }
    }
    _zones.remove(anchor);
    _utils.remove(anchor);
    _roads.remove(k);
    _roadSealed.remove(k);
    _grown.remove(anchor);
    _abandoned.remove(anchor);
    _abandonTimer.remove(anchor);
    _growProgress.remove(anchor);
    _rubble.remove(k); // bulldozing rubble clears it
    _fires.remove(k); // bulldozing also kills the fire on it
    _crystal.remove(k); // bulldozing clears overgrowth too
    _scatter.remove(k); // bulldozing / building clears natural cover
    if (!keepSupport) _support.remove(k); // bulldozing removes a support tile
    _buildStyle.remove(anchor);
    _decompressTimer.remove(anchor);
    _deliveries.remove(anchor); // cancel its delivery schedule
    _craft.removeWhere((c) => c.anchor == anchor); // its visiting craft leave
    if (_landerPad == anchor) _landerPad = null; // pad gone -> lander unparked
  }

  void _expandLand() {
    if (_grid >= _maxGrid) return;
    if (_funds < _landCost) {
      setState(() => _blocked =
          'Need §${_landCost.toStringAsFixed(0)} to buy land (have §${_funds.toStringAsFixed(0)}).');
      return;
    }
    final old = _grid;
    final next = (old + 2).clamp(0, _maxGrid);
    int rekey(int k) => (k ~/ old) * next + (k % old);
    Map<int, T> remap<T>(Map<int, T> m) =>
        {for (final e in m.entries) rekey(e.key): e.value};
    Set<int> remapSet(Set<int> s) => {for (final k in s) rekey(k)};
    setState(() {
      _funds -= _landCost;
      _blocked = null;
      final z = remap(_zones), u = remap(_utils), at = remap(_abandonTimer);
      final gp = remap(_growProgress);
      final r = remapSet(_roads), g = remapSet(_grown), ab = remapSet(_abandoned);
      final rub = remapSet(_rubble);
      final cry = remapSet(_crystal);
      final sup = remapSet(_support);
      // Scatter maps cell -> kind index; rekey only the cell (the value is a kind).
      final scat = {for (final e in _scatter.entries) rekey(e.key): e.value};
      final bst = {for (final e in _buildStyle.entries) rekey(e.key): e.value};
      // Footprint maps cell->anchor; both ends are cell ids, so rekey both.
      final fp = {for (final e in _footprint.entries) rekey(e.key): rekey(e.value)};
      _zones..clear()..addAll(z);
      _utils..clear()..addAll(u);
      _footprint..clear()..addAll(fp);
      _rubble..clear()..addAll(rub);
      _crystal..clear()..addAll(cry);
      _scatter..clear()..addAll(scat);
      _buildStyle..clear()..addAll(bst);
      _support..clear()..addAll(sup);
      _roads..clear()..addAll(r);
      _grown..clear()..addAll(g);
      _growProgress..clear()..addAll(gp);
      _abandoned..clear()..addAll(ab);
      _abandonTimer..clear()..addAll(at);
      _hubKey = rekey(_hubKey);
      if (_landerPad != null) _landerPad = rekey(_landerPad!);
      if (_beaconCell != null) _beaconCell = rekey(_beaconCell!);
      _grid = next;
      _genElevation(); // re-sculpt terrain for the enlarged grid
      _seedScatter(); // dress the newly-bought ring of land
      _recompute();
    });
  }

  Color _cellColor(int key) {
    final z = _zones[key];
    if (z != null) return _grownSpec(z).color;
    final u = _utils[key];
    if (u != null) return u.color;
    return const Color(0xFF6FB4FF);
  }

  // ---- Map data (Building bridge for the painter) ----
  // The painter only reads Building.id; we key buildings by '$cellKey' and look
  // the CitySpec back up via _specAt() for colour/height.

  CitySpec? _specAt(int key) {
    final z = _zones[key];
    if (z != null && _grown.contains(key)) return _grownSpec(z);
    return _utils[key];
  }

  Map<int, Building> get _mapCells {
    final m = <int, Building>{};
    Building b(int k) => Building(
        id: '$k', spec: const BuildingSpec(type: 'x'), gridX: k % _grid, gridY: k ~/ _grid);
    for (final k in _grown) {
      if (_zones[k] != null) m[k] = b(k);
    }
    for (final k in _utils.keys) {
      m[k] = b(k);
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: 'CITY BUILDER',
      accentColor: AppTheme.accent2,
      actions: [
        if (_zones.isNotEmpty || _utils.isNotEmpty || _roads.length > 1)
          IconButton(
            icon: const Icon(Icons.delete_sweep, color: AppTheme.danger),
            tooltip: 'Clear',
            onPressed: () => setState(() {
              _zones.clear();
              _utils.clear();
              _footprint.clear();
              _rubble.clear();
              _crystal.clear();
              _scatter.clear();
              _buildStyle.clear();
              _support.clear();
              _landerPad = null;
              _grown.clear();
              _growProgress.clear();
              _abandoned.clear();
              _roads
                ..clear()
                ..add(_hubKey);
              _recompute();
            }),
          ),
      ],
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 760;
        if (wide) {
          // Desktop: render fills the screen, the panel is a BOTTOM drawer with
          // horizontally-scrolling content (more natural with a mouse than a
          // tall right-hand column).
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _mapPane()),
              if (_paneOpen) ...[
                _drawerHandle(c.maxHeight),
                SizedBox(
                    height: (_drawerHeight ?? c.maxHeight * 0.42)
                        .clamp(160.0, c.maxHeight - 140),
                    child: _sidePane(horizontal: true)),
              ],
            ],
          );
        }
        // Narrow: the side panel collapses to full-screen render too.
        if (!_paneOpen) {
          return _mapPane();
        }
        // Narrow open: NO outer page scroll. A bounded Column gives the map a
        // fixed slice and the side panel the rest; the panel's tab body scrolls
        // INTERNALLY (single scroll). Avoids the double-scroll/overflow from
        // nesting the tab ListView inside an outer page ListView.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 320, child: _mapPane()),
            const Divider(height: 1, color: Color(0xFF223247)),
            Expanded(child: _sidePane()),
          ],
        );
      }),
    );
  }

  // ---- Map pane ----

  Widget _mapPane() => Container(
        color: const Color(0xFF080D0A),
        child: Column(
          children: [
            _stockChips(),
            Expanded(
              child: Stack(children: [
              Positioned.fill(
              child: CityMapView(
                grid: _grid,
                cell: _cellM,
                cells: _mapCells,
                groundTint: _underground
                    ? Color.lerp(_groundTint, const Color(0xFF120E0A), 0.7)!
                    : _groundTint,
                zoneTint: {for (final e in _zones.entries) e.key: _grownSpec(e.value).color},
                roads: _roads,
                rubble: _rubble,
                fires: _fires,
                scatter: _scatter,
                support: _support,
                colonyMode: _colonyMode.index,
                liquidColor: _liquid.colorArgb,
                liquidMolten: _liquid.isMolten,
                elevation: _elevation,
                liquidTiles: {
                  for (var k = 0; k < _grid * _grid; k++)
                    if (_isLiquidTile(k)) k
                },
                roadSealed: _roadSealed,
                hubs: {_hubKey},
                connected: _isConnected,
                occupied: (k) => !_abandoned.contains(k),
                colorOf: (b) {
                  final key = int.tryParse(b.id) ?? -1;
                  if (_abandoned.contains(key)) return const Color(0xFF555B63);
                  return _cellColor(key);
                },
                heightOf: (b) {
                  final key = int.tryParse(b.id) ?? -1;
                  return _specAt(key)?.height() ?? 10;
                },
                kindOf: (b) {
                  final key = int.tryParse(b.id) ?? -1;
                  return _specAt(key)?.type ?? '';
                },
                footOf: (key) {
                  final s = _specAt(key);
                  return (s?.footW ?? 1, s?.footH ?? 1);
                },
                styleOf: _styleOf,
                growthOf: (key) =>
                    _grown.contains(key) ? (_growProgress[key] ?? 1.0) : 1.0,
                // Traffic intensity = how much of the population is employed +
                // active; transit stops light up the network.
                commuters: _population > 0
                    ? (math.min(_population.floor(), _jobs) / _population)
                        .clamp(0.0, 1.0)
                    : 0.0,
                trafficAt: _trafficAt,
                transitStops: {
                  for (final e in _utils.entries)
                    if (e.value.type == 'transit' && _isConnected(e.key)) e.key
                },
                corpseDensity: _population > 0
                    ? (_corpses / _population).clamp(0.0, 1.0)
                    : (_corpses > 1 ? 0.5 : 0.0),
                // Garbage/sewage litter density from each backlog (relative to a
                // tolerable level scaled by population).
                garbageDensity: _population > 0
                    ? (_stockOf(Commodity.garbage) / (_population * 1.5))
                        .clamp(0.0, 1.0)
                    : 0.0,
                sewageDensity: _population > 0
                    ? (_stockOf(Commodity.sewage) / (_population * 1.5))
                        .clamp(0.0, 1.0)
                    : 0.0,
                wasteTiles: _wasteSites.toSet(),
                // A building flags understaffed when the city can't fill jobs
                // (global staffing < 95%) and this building actually needs them.
                understaffed: (k) =>
                    _staffing < 0.95 && (_specAt(k)?.jobs ?? 0) > 0,
                disaster: _disaster.index,
                weatherFade: _weatherFade,
                nuclearWinter: _nuclearWinter,
                radiation: _radiation,
                daylight: _daylight,
                flag: _flagPlanted,
                stormX: _isMovingFront ? _stormX : -1,
                stormY: _isMovingFront ? _stormY : -1,
                landerPad: _landerPad,
                landedCraft: [
                  for (final c in _craft)
                    // All craft use the simple pad animation now (no free flight),
                    // so they report no altitude/downrange — always on their pad.
                    (
                      tile: c.padTile,
                      phase: c.phase,
                      relief: c.isRelief,
                      altM: 0.0,
                      downrange: 0.0,
                    )
                ],
                beaconCell: _beaconCell,
                controller: _mapCam,
                panMode: _panMode,
                // Rect-select preview (anchor -> cursor), only while a rect is
                // in progress with the rect paint style.
                rectStart: _rectStart,
                rectEnd: _rectStart != null ? _rectHover : null,
                onHoverCell: (k) {
                  if (k != _hoverCell ||
                      (_rectStart != null && k != _rectHover)) {
                    setState(() {
                      _hoverCell = k;
                      if (_rectStart != null) _rectHover = k;
                    });
                  }
                },
                // Highlight the tile(s) under the cursor while a placement tool
                // is active — single cell, or the footprint of a large building.
                hoverCells: _hoverHighlight(),
                hoverDestructive: _tool == _Tool.bulldoze,
                onTapCell: _onTapCell,
                // Drag-paint for Zone/Road/Bulldoze in PAINT style; single + rect
                // styles use taps so the drag stays free for the camera.
                paintMode: !_panMode &&
                    _paintStyle == _PaintMode.paint &&
                    _toolPaintable,
                onPaintCell: _onPaintCell,
              ),
              ),
              // Status popup, top-right, over the render.
              Positioned(
                top: 8,
                right: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _statusPopup(),
                    if (_disaster != _Disaster.none) ...[
                      const SizedBox(height: 6),
                      _weatherPopup(),
                    ],
                  ],
                ),
              ),
              // Panel drawer toggle, top-left, over the render.
              Positioned(
                top: 8,
                left: 8,
                child: Material(
                  color: const Color(0xE60E1622),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: Color(0xFF223247))),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => _paneOpen = !_paneOpen),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                          _paneOpen
                              ? Icons.fullscreen
                              : Icons.fullscreen_exit,
                          size: 20,
                          color: AppTheme.accent2),
                    ),
                  ),
                ),
              ),
              // Camera-mode toggle (orbit <-> pan), below the drawer toggle.
              Positioned(
                top: 52,
                left: 8,
                child: Material(
                  color: const Color(0xE60E1622),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(
                          color: _panMode ? AppTheme.accent : const Color(0xFF223247))),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => _panMode = !_panMode),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                          _panMode ? Icons.pan_tool : Icons.threed_rotation,
                          size: 20,
                          color: _panMode ? AppTheme.accent : AppTheme.accent2),
                    ),
                  ),
                ),
              ),
              // Rect-fill anchor hint.
              if (_rectStart != null)
                Positioned(
                  bottom: 8,
                  left: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xE60E1622),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.accent),
                    ),
                    child: Text('Tap the opposite corner to fill',
                        style: AppTheme.dim.copyWith(color: AppTheme.accent)),
                  ),
                ),
            ]),
            ),
            _toolBar(),
          ],
        ),
      );

  /// Compact city-status popup overlaid on the map (was the inline sim banner).
  /// All the status alerts that currently apply, most severe first. Each is a
  /// chip in the status stack; tapping one opens its explanation. An empty list
  /// means the colony is healthy.
  List<({IconData icon, String msg, Color color, VoidCallback tap})>
      get _notifications {
    final out = <({IconData icon, String msg, Color color, VoidCallback tap})>[];
    if (_starved) {
      out.add((
        icon: Icons.no_food,
        msg: 'STARVING — pop leaving',
        color: AppTheme.danger,
        tap: () => _explainAlert('starving'),
      ));
    }
    if (!_hasSpaceport) {
      out.add((
        icon: Icons.block,
        msg: switch (_noSpaceportReason) {
          1 => 'Spaceport cut off — reconnect it',
          2 => 'Spaceport demolished — rebuild',
          _ => 'No spaceport — build one',
        },
        color: AppTheme.warn,
        tap: () => _explainAlert('spaceport'),
      ));
    }
    if (_fires.isNotEmpty) {
      out.add((
        icon: Icons.local_fire_department,
        msg: '${_fires.length} building${_fires.length == 1 ? "" : "s"} on fire',
        color: AppTheme.danger,
        tap: () => _explainAlert('fire'),
      ));
    }
    if (_pollution > 120) {
      out.add((
        icon: Icons.cloud,
        msg: 'Air pollution critical',
        color: AppTheme.danger,
        tap: () => _explainAlert('pollution'),
      ));
    } else if (_pollution > 70) {
      out.add((
        icon: Icons.cloud,
        msg: 'Air pollution rising',
        color: AppTheme.warn,
        tap: () => _explainAlert('pollution'),
      ));
    }
    if (_disease > 0.4) {
      out.add((
        icon: Icons.coronavirus,
        msg: 'Disease outbreak',
        color: AppTheme.danger,
        tap: () => _explainAlert('disease'),
      ));
    }
    if (_powerDraw > 0 && _powerOut < _powerDraw * 0.9) {
      out.add((
        icon: Icons.bolt,
        msg: 'Power shortage',
        color: AppTheme.warn,
        tap: () => _explainAlert('power'),
      ));
    }
    return out;
  }

  Widget _statusPopup() {
    final notes = _notifications;
    // Healthy: a single calm chip with the population.
    if (notes.isEmpty) {
      return _statusChip(
          Icons.rocket_launch,
          'Pop ${_population.round()} · growing',
          AppTheme.accent2,
          () => _explainAlert('healthy'));
    }
    // Otherwise stack every active alert (most severe first).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final n in notes) ...[
          _statusChip(n.icon, n.msg, n.color, n.tap),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  Widget _statusChip(IconData icon, String msg, Color color, VoidCallback tap) {
    return GestureDetector(
      onTap: tap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xE60E1622),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 1.5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Flexible(
              child: Text(msg,
                  style: AppTheme.body.copyWith(color: color, fontSize: 12))),
          const SizedBox(width: 6),
          Icon(Icons.info_outline, size: 13, color: color.withValues(alpha: 0.7)),
        ]),
      ),
    );
  }

  /// Active-weather popup, same chip style as the status popup, stacked under
  /// it. Shows the disaster name + a countdown; tap for what it does + how to
  /// mitigate it.
  Widget _weatherPopup() {
    final d = _disaster;
    // Storms/precip are amber warnings; the catastrophes (nuke/plague/famine/
    // meteor/tornado/fire/solar) read as danger.
    const severe = {
      _Disaster.nuke,
      _Disaster.plague,
      _Disaster.famine,
      _Disaster.meteorShower,
      _Disaster.tornado,
      _Disaster.fire,
      _Disaster.solarStorm,
      _Disaster.hurricane,
      _Disaster.blizzard,
      _Disaster.earthquake,
      _Disaster.radiationStorm,
      _Disaster.glassRain,
      _Disaster.ammoniaStorm,
      _Disaster.miasma,
      // Wave 2 harmful ones.
      _Disaster.lavaFlow,
      _Disaster.sandworm,
      _Disaster.grayGoo,
      _Disaster.gammaRayBurst,
      _Disaster.skyCrack,
      _Disaster.blackRain,
      _Disaster.cultUprising,
      _Disaster.marketCrash,
      _Disaster.bloodRain,
    };
    // Positive / benign events get a friendly accent instead of a warning.
    const good = {
      _Disaster.auroraBloom,
      _Disaster.fallingStar,
      _Disaster.biolumTide,
      _Disaster.festival,
      _Disaster.goldRush,
      _Disaster.diamondRain,
      _Disaster.refugeeInflux,
      _Disaster.rainingFrogs,
    };
    final accent = good.contains(d)
        ? AppTheme.accent2
        : (severe.contains(d) ? AppTheme.danger : AppTheme.warn);
    final secs = _disasterTime.ceil();
    return GestureDetector(
      onTap: () => _showExplain(
          d.label,
          _disasterWhat(d),
          _disasterFix(d),
          accent),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xE60E1622),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent, width: 1.5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(d.icon, size: 16, color: accent),
          const SizedBox(width: 8),
          Flexible(
              child: Text('${d.label} · ${secs}s',
                  style: AppTheme.body.copyWith(color: accent, fontSize: 12))),
          const SizedBox(width: 6),
          Icon(Icons.info_outline, size: 13, color: accent.withValues(alpha: 0.7)),
        ]),
      ),
    );
  }

  String _disasterWhat(_Disaster d) => switch (d) {
        _Disaster.rain => 'Steady rain — tops up your water stockpile, no harm.',
        _Disaster.thunderstorm =>
          'Thunderstorm — rain plus the odd lightning strike that can flatten a building.',
        _Disaster.snow => 'Snowfall — refills water slowly; cosmetic chill.',
        _Disaster.dustStorm =>
          'Dust storm — airborne grit dims the sun, cutting solar output and adding pollution.',
        _Disaster.tornado =>
          'Tornado — periodically tears a building into rubble as it tracks across the colony.',
        _Disaster.fire =>
          'Wildfire — burns buildings to rubble and pumps out pollution.',
        _Disaster.meteorShower =>
          'Meteor shower — impacts flatten buildings and cause casualties.',
        _Disaster.plague =>
          'Plague — disease soars and people die until it burns out.',
        _Disaster.famine => 'Famine — crops fail and the food stockpile drains fast.',
        _Disaster.solarStorm =>
          'Solar storm — radiation spikes and compute/power get disrupted.',
        _Disaster.nuke =>
          'Nuclear strike — radiation, nuclear winter, mass casualties and flattened buildings.',
        _Disaster.hurricane =>
          'Hurricane — a slow, wide cyclone that tracks across the colony, '
              'flattening what it passes over (and dumping rain).',
        _Disaster.blizzard =>
          'Blizzard — extreme cold + whiteout; some people leave, water trickles in.',
        _Disaster.fog => 'Fog — reduced visibility only. Harmless.',
        _Disaster.acidRain =>
          'Acid rain — corrosive precip: light pollution and slow building wear.',
        _Disaster.earthquake =>
          'Earthquake — sharp ground shaking flattens buildings, but it is brief.',
        _Disaster.radiationStorm =>
          'Radiation storm — background radiation spikes; shelter your population.',
        _Disaster.glassRain =>
          'Glass rain — molten silicate shards fall, damaging structures and '
              'fouling the air (scorching rocky worlds).',
        _Disaster.ammoniaStorm =>
          'Ammonia storm — toxic reducing-atmosphere weather: pollution + casualties.',
        _Disaster.cryovolcanism =>
          'Cryovolcanism — icy-moon water/ammonia eruptions: some damage, vents water.',
        _Disaster.miasma =>
          'Miasma — a sickly fog of decay rising from unburied bodies. Disease '
              'climbs and the air fouls until you clear the corpse backlog.',
        // --- Wave 2 ---
        _Disaster.lavaFlow =>
          'Lava flow — a creeping molten front burns a path of buildings to rubble.',
        _Disaster.sandworm =>
          'Sandworm — a burrowing leviathan tracks across the sands, swallowing '
              'whatever sits on its line.',
        _Disaster.grayGoo =>
          'Gray goo — self-replicating nanites consume buildings as the swarm '
              'crawls across the colony. Bulldoze a firebreak.',
        _Disaster.crawlingForest =>
          'The Crawling Forest — alien vegetation creeps over the ground, '
              'overgrowing tiles (clear them to build again).',
        _Disaster.rollingGlitch =>
          'Rolling glitch — a band of broken reality sweeps the map, briefly '
              'scrambling compute and disabling what it covers.',
        _Disaster.auroraBloom =>
          'Aurora bloom — a dazzling sky display. Harmless, and it lifts spirits.',
        _Disaster.eclipse =>
          'Eclipse — the sun is blotted out; solar power collapses until it passes.',
        _Disaster.gammaRayBurst =>
          'Gamma-ray burst — a distant cataclysm bathes the world in lethal '
              'radiation that no atmosphere can stop. Brief, brutal.',
        _Disaster.fallingStar =>
          'Falling star — a brilliant streak across the sky. Make a wish — a little '
              'cheer and inspiration (research).',
        _Disaster.skyCrack =>
          'Sky crack — reality fractures overhead. Unsettling, with the rare '
              'structural failure.',
        _Disaster.timeDilation =>
          'Time dilation — local time speeds up and slows down erratically.',
        _Disaster.sporeBloom =>
          'Spore bloom — fungal growth spreads over the ground and chokes crops.',
        _Disaster.crystalGrowth =>
          'Crystal growth — gleaming crystals overgrow tiles. They block building '
              'but can be mined for ore.',
        _Disaster.biolumTide =>
          'Bioluminescent tide — the shores glow. A beautiful, morale-boosting sight.',
        _Disaster.chemicalRain =>
          'Chemical rain — mutagenic precip: pollution and a touch of sickness.',
        _Disaster.diamondRain =>
          'Diamond rain — precious crystals fall from the deep-pressure sky. Free riches!',
        _Disaster.ironSnow =>
          'Iron snow — metallic precipitation: free ore, but it dents the roofs.',
        _Disaster.methaneDownpour =>
          'Methane downpour — hydrocarbon rain you can refine into fuel.',
        _Disaster.bloodRain =>
          'Blood rain — iron-red precip stains the colony. Ominous, mildly harmful.',
        _Disaster.blackRain =>
          'Black rain — radioactive fallout precipitation: radiation + pollution.',
        _Disaster.commsBlackout =>
          'Comms blackout — the spaceport goes dark; no new immigrants arrive.',
        _Disaster.goldRush =>
          'Gold rush — a boom! Production surges and the mood is high.',
        _Disaster.refugeeInflux =>
          'Refugee influx — a wave of arrivals swells the population fast.',
        _Disaster.festival =>
          'Festival — citizens celebrate: morale soars, though work slows.',
        _Disaster.cultUprising =>
          'Cult uprising — a fringe movement stokes rebellion and sours the mood.',
        _Disaster.aiAwakening =>
          'AI awakening — the data centres stir to life: a research windfall, and '
              'a faintly uneasy populace.',
        _Disaster.marketCrash =>
          'Market crash — funds bleed and the economy slumps.',
        _Disaster.alienBeacon =>
          'Alien beacon — a monolith hums on the surface. Studying it yields '
              'research; bulldoze it for materials.',
        _Disaster.rainingFrogs =>
          'Raining frogs — it is, inexplicably, raining frogs. Ew.',
        _Disaster.glitchInMatrix =>
          'Glitch in the Matrix — déjà-vu. The last disaster is about to happen '
              'again.',
        _Disaster.none => '',
      };

  String _disasterFix(_Disaster d) => switch (d) {
        _Disaster.tornado ||
        _Disaster.fire ||
        _Disaster.meteorShower ||
        _Disaster.nuke =>
          'Build Emergency Services to respond, Bunkers/Shelters to protect people, '
              'and keep spare ore to rebuild. Bulldoze rubble to clear flattened tiles.',
        _Disaster.miasma =>
          'Build Morgues / Crematoria (Deathcare) to clear the corpse backlog fast, '
              'plus Clinics/Hospitals for the disease it spreads.',
        _Disaster.plague =>
          'Build Clinics/Hospitals and keep Medicine stocked; Emergency Services soften it.',
        _Disaster.famine =>
          'Stockpile food ahead of time (Warehouses) and run extra Farms/Hydroponics.',
        _Disaster.solarStorm =>
          'Shelter the population; radiation decays after it passes. Keep power reserves.',
        _Disaster.dustStorm =>
          'Lean on Gas/Reactor power during the storm — solar is throttled by the dust.',
        _ => 'Ride it out — it clears on its own. Early-Warning Stations predict the next one.',
      };

  Widget _toolBar() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        color: AppTheme.panel,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _toolChip('Inspect', Icons.touch_app, _Tool.inspect, AppTheme.accent),
            const SizedBox(width: 5),
            _toolChip('Zone', Icons.grid_view, _Tool.zone, AppTheme.accent2),
            const SizedBox(width: 5),
            _toolChip('Util', Icons.bolt, _Tool.utility, AppTheme.warn),
            const SizedBox(width: 5),
            _toolChip('Road', Icons.add_road, _Tool.road, AppTheme.textDim),
            const SizedBox(width: 5),
            _toolChip('Bulldoze', Icons.delete, _Tool.bulldoze, AppTheme.danger),
            const SizedBox(width: 5),
            _toolChip('Retrofit', Icons.sync_alt, _Tool.retrofit, AppTheme.accent),
            if (_colonyNeedsSupport || _isOceanColony) ...[
              const SizedBox(width: 5),
              _toolChip(_supportLabel, Icons.grid_4x4, _Tool.support,
                  AppTheme.accent2),
            ],
            // Paint-style + auto-roads options, only for the Zone/Road tools.
            if (_toolPaintable) ...[
              const SizedBox(width: 10),
              _modeChip('Single', Icons.crop_square, _PaintMode.single),
              const SizedBox(width: 4),
              _modeChip('Paint', Icons.brush, _PaintMode.paint),
              const SizedBox(width: 4),
              _modeChip('Rect', Icons.select_all, _PaintMode.rect),
              // Auto-roads only makes sense for the Zone tool.
              if (_tool == _Tool.zone) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => setState(() => _autoRoads = !_autoRoads),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                  decoration: BoxDecoration(
                    color: _autoRoads
                        ? AppTheme.accent.withValues(alpha: 0.25)
                        : AppTheme.panelLight,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: _autoRoads ? AppTheme.accent : AppTheme.panelLight),
                  ),
                  child: Row(children: [
                    Icon(Icons.add_road,
                        size: 13,
                        color: _autoRoads ? AppTheme.accent : AppTheme.textDim),
                    const SizedBox(width: 4),
                    Text('Auto roads',
                        style: TextStyle(
                            fontSize: 12,
                            color: _autoRoads ? AppTheme.accent : AppTheme.textDim)),
                  ]),
                ),
              ),
              ],
            ],
            const SizedBox(width: 10),
            // Surface <-> underground layer toggle.
            GestureDetector(
              onTap: () => setState(() => _underground = !_underground),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: _underground
                      ? const Color(0xFF6D4C41)
                      : AppTheme.panelLight,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(children: [
                  Icon(_underground ? Icons.terrain : Icons.layers,
                      size: 13,
                      color: _underground ? AppTheme.bg : AppTheme.text),
                  const SizedBox(width: 4),
                  Text(_underground ? 'Underground' : 'Surface',
                      style: TextStyle(
                          fontSize: 12,
                          color: _underground ? AppTheme.bg : AppTheme.text)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            // Rolling-hills relief toggle (flat by default).
            GestureDetector(
              onTap: () => setState(() {
                _terrainRelief = !_terrainRelief;
                _genElevation(); // re-sculpt (or flatten) the height field
                _recompute();
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: _terrainRelief
                      ? AppTheme.accent.withValues(alpha: 0.25)
                      : AppTheme.panelLight,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: _terrainRelief
                          ? AppTheme.accent
                          : AppTheme.panelLight),
                ),
                child: Row(children: [
                  Icon(Icons.landscape,
                      size: 13,
                      color: _terrainRelief ? AppTheme.accent : AppTheme.textDim),
                  const SizedBox(width: 4),
                  Text('Relief',
                      style: TextStyle(
                          fontSize: 12,
                          color: _terrainRelief
                              ? AppTheme.accent
                              : AppTheme.textDim)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            // Replant: fill open tiles with biome flora right now (regrowth also
            // does this slowly on its own).
            GestureDetector(
              onTap: () => setState(_seedScatter),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.panelLight,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(children: [
                  Icon(Icons.forest, size: 13, color: Color(0xFF7CB342)),
                  SizedBox(width: 4),
                  Text('Plant', style: TextStyle(fontSize: 12, color: AppTheme.text)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _grid >= _maxGrid ? null : _expandLand,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: _grid >= _maxGrid
                      ? AppTheme.panelLight
                      : AppTheme.accent2.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: _grid >= _maxGrid
                          ? AppTheme.textDim
                          : AppTheme.accent2),
                ),
                child: Row(children: [
                  const Icon(Icons.open_in_full, size: 13, color: AppTheme.accent2),
                  const SizedBox(width: 4),
                  Text(_grid >= _maxGrid ? 'Max land' : 'Buy land §${_landCost.toStringAsFixed(0)}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.accent2)),
                ]),
              ),
            ),
          ]),
        ),
      );

  Widget _toolChip(String label, IconData icon, _Tool tool, Color color) {
    final sel = _tool == tool;
    return GestureDetector(
      onTap: () => setState(() => _tool = tool),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
            color: sel ? color : AppTheme.panelLight,
            borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          Icon(icon, size: 14, color: sel ? AppTheme.bg : AppTheme.text),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(fontSize: 12, color: sel ? AppTheme.bg : AppTheme.text)),
        ]),
      ),
    );
  }

  Widget _modeChip(String label, IconData icon, _PaintMode mode) {
    final sel = _paintStyle == mode;
    return GestureDetector(
      onTap: () => setState(() {
        _paintStyle = mode;
        _rectStart = null; // reset any half-started rect
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
            color: sel ? AppTheme.accent : AppTheme.panelLight,
            borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          Icon(icon, size: 13, color: sel ? AppTheme.bg : AppTheme.textDim),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 12, color: sel ? AppTheme.bg : AppTheme.textDim)),
        ]),
      ),
    );
  }

  // ---- Side pane ----

  /// The side pane, split into tabs so the player doesn't scroll forever:
  /// BUILD (planet + zones + buildings), CITY (status + economy + RCI),
  /// POLITICS (government + laws + society), STOCK (stockpile).
  /// Drag-handle above the desktop bottom drawer: drag up/down to resize it.
  /// [maxH] is the body height (caps the drawer so the render stays visible).
  Widget _drawerHandle(double maxH) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => setState(() {
          final cur = _drawerHeight ?? maxH * 0.42;
          _drawerHeight = (cur - d.delta.dy).clamp(160.0, maxH - 140);
        }),
        onDoubleTap: () => setState(() => _drawerHeight = null), // reset
        child: Container(
          height: 14,
          color: AppTheme.panel,
          alignment: Alignment.center,
          child: Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF42607A),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sidePane({bool horizontal = false}) {
    final tabBar = Container(
      color: AppTheme.panel,
      child: TabBar(
        controller: _tabs,
        isScrollable: true,
        labelColor: AppTheme.accent2,
        unselectedLabelColor: AppTheme.textDim,
        indicatorColor: AppTheme.accent2,
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        tabs: const [
          Tab(height: 36, text: 'BUILD'),
          Tab(height: 36, text: 'WORLD'),
          Tab(height: 36, text: 'CITY'),
          Tab(height: 36, text: 'POLITICS'),
          Tab(height: 36, text: 'STOCK'),
        ],
      ),
    );
    Widget body(List<Widget> kids) =>
        horizontal ? _tabStripH(kids) : _tabList(kids);
    final views = TabBarView(
      controller: _tabs,
      children: [
        body(_buildTab()),
        body(_worldTab()),
        body(_cityTab()),
        body(_politicsTab()),
        body(_stockTab()),
      ],
    );
    return ColoredBox(
      color: AppTheme.bg,
      child: Column(children: [tabBar, Expanded(child: views)]),
    );
  }

  /// Bottom-drawer tab body (desktop): the tab's widgets laid out in a row of
  /// fixed-width columns that scroll HORIZONTALLY, so a short-but-wide drawer
  /// shows a lot at once instead of one tall scroll. Each column packs a few
  /// rows; the whole strip scrolls sideways.
  Widget _tabStripH(List<Widget> children) {
    const colWidth = 300.0;
    const perCol = 6; // rows per column before wrapping to the next column
    final cols = <Widget>[];
    for (var i = 0; i < children.length; i += perCol) {
      cols.add(SizedBox(
        width: colWidth,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
              12, 12, 12, 24 + MediaQuery.viewPaddingOf(context).bottom),
          children: children.sublist(
              i, math.min(i + perCol, children.length)),
        ),
      ));
    }
    // Vertical mouse-wheel should scroll the strip HORIZONTALLY (no Shift). A
    // Listener converts wheel dy -> horizontal offset on the controller.
    return Listener(
      onPointerSignal: (sig) {
        if (sig is PointerScrollEvent && _drawerScroll.hasClients) {
          final dy = sig.scrollDelta.dy;
          if (dy != 0) {
            _drawerScroll.jumpTo((_drawerScroll.offset + dy)
                .clamp(0.0, _drawerScroll.position.maxScrollExtent));
          }
        }
      },
      child: SingleChildScrollView(
        controller: _drawerScroll,
        scrollDirection: Axis.horizontal,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cols),
      ),
    );
  }

  final ScrollController _drawerScroll = ScrollController();

  Widget _diffSlider(
          String label, double value, String hint, ValueChanged<double> onCh) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(label, style: AppTheme.body)),
            Text(
                value < 0.34 ? 'Low' : (value < 0.67 ? 'Medium' : 'High'),
                style: AppTheme.mono.copyWith(color: AppTheme.accent)),
          ]),
          SliderTheme(
            data: SliderThemeData(
                activeTrackColor: AppTheme.accent2,
                thumbColor: AppTheme.accent2,
                inactiveTrackColor: AppTheme.panelLight,
                trackHeight: 3),
            child: Slider(value: value, onChanged: onCh),
          ),
          Text(hint, style: AppTheme.dim.copyWith(fontSize: 11)),
        ]),
      );

  /// WORLD tab: time warp, host planet + biome, disasters, environment meters.
  List<Widget> _worldTab() => [
        const Text('TIME WARP', style: AppTheme.heading),
        const SizedBox(height: 6),
        Row(children: [
          Text('${_timeWarp.toStringAsFixed(0)}×',
              style: AppTheme.mono.copyWith(color: AppTheme.accent)),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                  activeTrackColor: AppTheme.accent,
                  thumbColor: AppTheme.accent,
                  inactiveTrackColor: AppTheme.panelLight,
                  trackHeight: 3),
              child: Slider(
                  value: _timeWarp,
                  min: 1,
                  max: 20,
                  onChanged: (v) => setState(() => _timeWarp = v)),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        const Text('DIFFICULTY', style: AppTheme.heading),
        const SizedBox(height: 6),
        _diffSlider('Complexity', _complexity,
            'How many systems to manage (waste, oxygen, …)',
            (v) => setState(() => _complexity = v)),
        _diffSlider('Hostility', _hostility,
            'Frequency + severity of random disasters',
            (v) => setState(() => _hostility = v)),
        _diffSlider('Forgiveness', _forgiveness,
            'How much slack before citizens die / leave',
            (v) => setState(() => _forgiveness = v)),
        _diffSlider('Bounty', _bounty,
            'Resource production rate (higher = more abundant)',
            (v) => setState(() => _bounty = v)),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _infiniteRes,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Infinite resources (debug)', style: AppTheme.body),
          subtitle: Text('Stockpiles never deplete — shows ∞, keeps live rates.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => _infiniteRes = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _infiniteDemand,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Infinite demand (debug)', style: AppTheme.body),
          subtitle: Text('RCI demand pinned to max — zones keep growing.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => _infiniteDemand = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _infiniteRobotics,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Infinite Robotics', style: AppTheme.body),
          subtitle: Text('Automated labour — buildings need no workers (full staffing).',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => _infiniteRobotics = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _ignoreUnlocks,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Ignore unlocks (debug)', style: AppTheme.body),
          subtitle: Text('Build anything regardless of the population requirement.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => _ignoreUnlocks = v),
        ),
        const SizedBox(height: 12),
        const Text('PLANET & BIOME', style: AppTheme.heading),
        const SizedBox(height: 6),
        _planetPanel(),
        const SizedBox(height: 12),
        const Text('WEATHER & DISASTERS', style: AppTheme.heading),
        const SizedBox(height: 6),
        _disasterControls(),
        const SizedBox(height: 12),
        const Text('ENVIRONMENT', style: AppTheme.heading),
        const SizedBox(height: 6),
        _pollutionRow(),
        _radiationRow(),
        if (_nuclearWinter > 0.02)
          _meterRow('Nuclear Winter',
              '${(_nuclearWinter * 100).toStringAsFixed(0)}%', _nuclearWinter,
              AppTheme.danger,
              warn: 'Sun blotted out — solar + crops failing.',
              onExplain: () => _showExplain(
                  'Nuclear Winter',
                  'Soot from a nuclear strike blots out the sun, crippling solar '
                      'power and freezing crops.',
                  'It clears over time. Build Terraforming Towers to clear it faster, '
                      'and lean on gas/nuclear power + stored food until it lifts.',
                  AppTheme.danger)),
        if (_terraform > 0.01 || _terraformers > 0)
          _meterRow('Terraforming', '${(_terraform * 100).toStringAsFixed(0)}%',
              _terraform, AppTheme.accent2),
      ];

  Widget _tabList(List<Widget> children) => ListView(
        // Bottom padding clears the real device safe-area / nav bar (not a magic
        // constant) so the last row (e.g. the connectivity panel) is never cut
        // off or hidden behind the system gesture bar.
        padding: EdgeInsets.fromLTRB(
            12, 12, 12, 64 + MediaQuery.viewPaddingOf(context).bottom),
        children: children,
      );

  List<Widget> _buildTab() {
    final q = _buildSearch.trim().toLowerCase();
    return [
      if (_blocked != null) ...[_blockedBanner(), const SizedBox(height: 10)],
      _buildSearchBox(),
      const SizedBox(height: 10),
      // Hide the zones section while searching (search targets buildings).
      if (q.isEmpty) ...[
        const Text('ZONES', style: AppTheme.heading),
        const SizedBox(height: 6),
        _zonePicker(),
        const SizedBox(height: 14),
      ],
      const Text('BUILDINGS', style: AppTheme.heading),
      const SizedBox(height: 6),
      for (final grp in kGroupLabels.keys) ..._utilGroup(grp, q),
      if (q.isNotEmpty && !kUtilCatalog.any((u) => _matchesSearch(u, q)))
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('No buildings match "$_buildSearch".',
              style: AppTheme.dim),
        ),
      const SizedBox(height: 12),
      if (q.isEmpty) _connectivityPanel(),
    ];
  }

  bool _matchesSearch(CitySpec u, String q) =>
      q.isEmpty ||
      u.label.toLowerCase().contains(q) ||
      u.type.toLowerCase().contains(q) ||
      (kGroupLabels[u.group] ?? '').toLowerCase().contains(q);

  Widget _buildSearchBox() => TextField(
        onChanged: (v) => setState(() => _buildSearch = v),
        style: AppTheme.body,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search buildings…',
          hintStyle: AppTheme.dim,
          prefixIcon: const Icon(Icons.search, size: 18, color: AppTheme.textDim),
          suffixIcon: _buildSearch.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: () => setState(() => _buildSearch = ''),
                ),
          filled: true,
          fillColor: AppTheme.bg,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF223247)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF223247)),
          ),
        ),
      );

  List<Widget> _cityTab() => [
        const Text('COLONY STATUS', style: AppTheme.heading),
        const SizedBox(height: 8),
        _statRow('Population', '${_population.round()}'),
        _statRow('Housing', '$_housing'),
        _statRow('Jobs', '$_jobs'),
        _statRow('Homeless', '$_homeless'),
        ..._mortalityStats(), // corpses + deaths = vital stats, not politics
        if (_grown.isNotEmpty) _utilisationRow(),
        _powerRow(),
        _computeRow(),
        _happinessRow(),
        if (_congestion > 0.02)
          _meterRow('Traffic congestion',
              '${(_congestion * 100).toStringAsFixed(0)}%', _congestion,
              _congestion > 0.6
                  ? AppTheme.danger
                  : (_congestion > 0.35 ? AppTheme.warn : AppTheme.accent2),
              warn: _congestion > 0.5
                  ? 'Gridlock — workers stuck commuting, staffing down ${((1 - (1 - _congestion * 0.4)) * 100).toStringAsFixed(0)}%.'
                  : null,
              onExplain: () => _showExplain(
                  'Traffic Congestion',
                  'Every connected building routes its workers to the hub along '
                      'the road network. The busiest tiles (the arteries near the '
                      'hub) carry the most trips. Heavy congestion means workers '
                      'spend longer travelling, so fewer effective worker-hours '
                      'reach the jobs — up to a 40% staffing penalty at full '
                      'gridlock.',
                  'Add more roads so traffic spreads over parallel routes instead '
                      'of funnelling through one street. Build transit stops to '
                      'take trips off the roads. Keep workplaces near housing.',
                  AppTheme.warn)),
        if (_wasteBacklog > 0.02)
          _meterRow('Waste backlog', '${(_wasteBacklog * 100).toStringAsFixed(0)}%',
              _wasteBacklog,
              _wasteBacklog > 0.5 ? AppTheme.danger : AppTheme.warn,
              warn: _wasteBacklog > 0.4
                  ? 'Garbage + sewage piling up — pollution + disease.'
                  : null,
              onExplain: () => _showExplain(
                  'Waste Backlog',
                  'Your population generates garbage + sewage every tick. When it '
                      'piles up faster than you process it, it pollutes the air and '
                      'spreads disease, dragging happiness.',
                  'Build Landfills (cheap), Recycling Centers (recover ore/steel), '
                      'and Sewage Treatment plants (recover water). Tap the Garbage / '
                      'Sewage chips for the exact balance.',
                  AppTheme.warn)),
        _pollutionRow(),
        _radiationRow(),
        const SizedBox(height: 12),
        const Text('ECONOMY', style: AppTheme.heading),
        const SizedBox(height: 6),
        _economyPicker(),
        const SizedBox(height: 6),
        _taxControl(),
        _statRow('Funds', '§${_funds.toStringAsFixed(0)}'),
        _statRow('Research', '${_research.toStringAsFixed(0)} pts'),
        const SizedBox(height: 12),
        const Text('RCI DEMAND', style: AppTheme.heading),
        const SizedBox(height: 6),
        _rciBar('Residential', _resTarget, const Color(0xFF7FE0A0)),
        _rciBar('Commercial', _comTarget, const Color(0xFF4FC3F7)),
        _rciBar('Industrial', _indTarget, const Color(0xFFE3A857)),
      ];

  List<Widget> _politicsTab() => [
        const Text('GOVERNMENT', style: AppTheme.heading),
        const SizedBox(height: 6),
        _govtPicker(),
        const SizedBox(height: 8),
        ..._lawRows(),
        const SizedBox(height: 12),
        const Text('SOCIETY', style: AppTheme.heading),
        const SizedBox(height: 6),
        if (_revoltMsg != null) _revoltBanner(),
        _socialBar('Crime', _crime, AppTheme.danger),
        _socialBar('Corruption', _corruption, const Color(0xFFB388FF)),
        _socialBar('Inequality', _inequality, const Color(0xFFE3A857)),
        _socialBar('Rebellion', _rebellion, AppTheme.danger),
        _socialBar('Disease', _disease, const Color(0xFF9CCC65)),
      ];

  /// Corpses + death-rate readout — a CITY metric (vital stats), not politics.
  List<Widget> _mortalityStats() => [
        if (_corpses > 0.5)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Icon(Icons.dangerous,
                  size: 14,
                  color: _corpses > _population * 0.05
                      ? AppTheme.danger
                      : AppTheme.warn),
              const SizedBox(width: 6),
              const Expanded(
                  child: Text('Corpses (unprocessed)', style: AppTheme.body)),
              Text(_corpses.toStringAsFixed(0),
                  style: AppTheme.mono.copyWith(
                      color: _corpses > _population * 0.05
                          ? AppTheme.danger
                          : AppTheme.warn)),
            ]),
          ),
        if (_deathRate > 0.01)
          _statRow('Deaths', '${_deathRate.toStringAsFixed(2)}/s'),
        if (_corpses > _population * 0.03 && _population > 10)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                'Corpse backlog spreading disease — build morgues / crematoria.',
                style: AppTheme.dim.copyWith(color: AppTheme.danger)),
          ),
      ];

  List<Widget> _stockTab() => [
        const Text('STOCKPILE', style: AppTheme.heading),
        const SizedBox(height: 2),
        Text('Rate is throttled output; (…) = full potential if fully staffed/'
            'powered.', style: AppTheme.dim),
        const SizedBox(height: 8),
        ..._stockRows(),
      ];

  String _biomeName(Biome b) => cityBiomeName(b);

  /// Short buff/debuff summary for the selected biome.
  String _biomeSummary() {
    final fx = _biomeFx;
    final bits = <String>[];
    void m(String label, double v) {
      if ((v - 1.0).abs() > 0.05) {
        bits.add('${v > 1 ? "+" : ""}${((v - 1) * 100).toStringAsFixed(0)}% $label');
      }
    }
    m('food', fx.food);
    m('water', fx.water);
    m('ore', fx.ore);
    m('solar', fx.solar);
    if (fx.happy.abs() > 0.005) {
      bits.add('${fx.happy > 0 ? "+" : ""}${(fx.happy * 100).toStringAsFixed(0)}% happy');
    }
    if (fx.scrub > 0.5) bits.add('cleans air');
    if (fx.scrub < -0.5) bits.add('dirties air');
    return bits.isEmpty ? 'Neutral terrain.' : bits.join(' · ');
  }

  void _triggerDisaster(_Disaster d) => setState(() {
        _disaster = d;
        _disasterTime = d.duration;
      });

  // ---- Building context menus ----

  /// A bottom-sheet action menu shared by the lander + functional buildings.
  void _contextMenu(String title, IconData icon, Color accent,
      List<Widget> actions) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.panel,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Icon(icon, color: accent),
              const SizedBox(width: 10),
              Text(title, style: AppTheme.heading.copyWith(color: accent)),
            ]),
            const SizedBox(height: 12),
            ...actions,
          ]),
        ),
      ),
    );
  }

  Widget _ctxAction(IconData icon, String label, String sub, Color color,
      VoidCallback onTap) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(label, style: AppTheme.body.copyWith(color: color)),
      subtitle: Text(sub, style: AppTheme.dim),
      onTap: () {
        Navigator.of(context).pop();
        onTap();
      },
    );
  }

  /// Context menu for the landing site (the hub). Plant a flag, or launch the
  /// lander back to orbit if it still has fuel.
  void _showLanderMenu() {
    final hasFuel = _stockOf(Commodity.fuel) >= 10;
    _contextMenu('Landing Site', Icons.rocket_launch, AppTheme.accent2, [
      _ctxAction(
          _flagPlanted ? Icons.flag : Icons.outlined_flag,
          _flagPlanted ? 'Flag planted' : 'Plant flag',
          _flagPlanted ? 'Your colours fly over the colony.' : 'Claim this world.',
          _flagPlanted ? AppTheme.textDim : AppTheme.accent2,
          () => setState(() => _flagPlanted = true)),
      _ctxAction(
          Icons.flight_takeoff,
          hasFuel ? 'Launch lander' : 'Launch (no fuel)',
          hasFuel
              ? 'Burn 10 fuel and ascend back to orbit.'
              : 'Need ≥10 fuel in the stockpile to launch.',
          hasFuel ? AppTheme.warn : AppTheme.textDim,
          hasFuel ? _launchLander : () {}),
    ]);
  }

  void _launchLander() {
    setState(() => _stock[Commodity.fuel] = _stockOf(Commodity.fuel) - 10);
    // Launch the lander into the real 3D sim from this colony's surface.
    _fly3DAscent();
  }

  /// Relief mission cooldown in seconds (between requests).
  static const double _reliefCooldownMax = 180.0;
  // Landing timeline: a craft descends over the first 12%, DWELLS on the pad for
  // 30 s (the middle ~76%), then ascends over the last 12%. Total ~38 s.
  static const double _craftDwellSec = 30.0;
  static const double _craftTotalSec = _craftDwellSec / 0.76;

  /// Footprint pad tiles of a spaceport (one craft per tile).
  Iterable<int> _padTilesOf(int anchor) =>
      _cellsOf(anchor); // every covered cell is a pad

  /// A free pad tile of [anchor] (not occupied by a craft), or null if full.
  int? _freePad(int anchor) {
    final taken = {
      for (final c in _craft)
        if (c.anchor == anchor) c.padTile
    };
    for (final t in _padTilesOf(anchor)) {
      if (!taken.contains(t)) return t;
    }
    return null;
  }

  /// "Request assistance": dispatch a relief craft to [anchor] (a spaceport). It
  /// flies in, lands on a free pad, dwells 30 s and drops a care package of
  /// resources + settlers, then leaves — the anti-soft-lock lifeline.
  void _requestRelief(int anchor) {
    if (_reliefCooldown > 0) return;
    final pad = _freePad(anchor);
    if (pad == null) return; // all pads busy
    setState(() {
      _craft.add(_LandedCraft(anchor: anchor, padTile: pad, isRelief: true));
      _reliefCooldown = _reliefCooldownMax;
    });
  }

  /// Drop the relief care package: top up life support, add funds + settlers that
  /// stick (raising the population floor so a cut-off colony gets unstuck).
  void _grantReliefPayload() {
    final s = (_grid * _grid) / 400.0; // 1.0 at a 20×20 map
    void give(String c, double amt) =>
        _stock[c] = (_stockOf(c) + amt).clamp(0.0, _stockCap);
    give(Commodity.food, 400 * s);
    give(Commodity.water, 400 * s);
    give(Commodity.oxygen, 300 * s);
    give(Commodity.ore, 300 * s);
    give(Commodity.fuel, 80 * s);
    _funds += 2000 * s;
    _housing += 8;
    _reliefCrew += 8;
    _population += 8;
    _blocked = 'Relief delivered: supplies + 8 settlers.';
  }

  /// Rough propellant (in delivery-units) a craft needs to climb back to orbit
  /// from THIS world, given the [cargo] it lifted. Heavier worlds (higher surface
  /// gravity vs Earth) cost more; lighter ones (moons) much less. A floor keeps
  /// even a tiny delivery needing a little fuel.
  double _returnFuelFor(double cargo) {
    final g = _body.mu / (_body.radius * _body.radius); // surface gravity
    const earthG = 9.80665;
    final gRatio = (g / earthG).clamp(0.1, 3.0);
    return (10 + cargo * 0.25) * gRatio;
  }

  /// Advance all visiting craft + run the recurring delivery schedules.
  void _reliefTick(double dt) {
    if (_reliefCooldown > 0) _reliefCooldown -= dt;

    // Dispatch scheduled deliveries that are due, IN LIST ORDER (priority).
    final spent = <int, List<_DeliverySchedule>>{}; // one-time runs to drop
    _deliveries.forEach((anchor, list) {
      if (_utils[anchor]?.type != 'spaceport' || !_isConnected(anchor)) return;
      for (final sched in list) {
        sched.timer -= dt;
        if (sched.timer > 0) continue;
        // Claim its assigned pad (or any free one). If busy, hold the timer at 0
        // so it dispatches the moment a pad opens (no missed cycle).
        final pad = _padForSchedule(anchor, sched.padIndex);
        if (pad == null) {
          sched.timer = 0;
          continue;
        }
        _dispatchDelivery(anchor, pad, sched);
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
      final list = _deliveries[anchor];
      if (list == null) return;
      list.removeWhere(runs.contains);
      if (list.isEmpty) _deliveries.remove(anchor);
    });

    // Advance each craft; drop its payload once, at the start of the dwell.
    final done = <_LandedCraft>[];
    for (final c in _craft) {
      // Host spaceport gone -> the craft leaves immediately.
      if (_utils[c.anchor]?.type != 'spaceport') {
        done.add(c);
        continue;
      }
      // All visiting craft (relief + deliveries) use the simple pad animation:
      // descend -> dwell (drop payload) -> lift off.
      c.phase += dt / _craftTotalSec;
      if (!c.granted && c.phase >= 0.12) {
        c.granted = true;
        if (c.isRelief) {
          _grantReliefPayload();
        } else if (c.resource == kDeliveryPeople) {
          // Settlers stick: raise housing + the population floor (like relief).
          final n = c.payload.round();
          _housing += n;
          _reliefCrew += n;
          _population += n;
          _blocked = 'Settler transport arrived: +$n colonists.';
        } else if (c.resource != null) {
          _stock[c.resource!] =
              (_stockOf(c.resource!) + c.payload).clamp(0.0, _stockCap);
        }
      }
      if (c.phase >= 1.0) done.add(c);
    }
    _craft.removeWhere(done.contains);
  }

  /// The pad tile a schedule should use: its PINNED pad (footprint index) if set
  /// and currently free, else any free pad. Null if none available.
  int? _padForSchedule(int anchor, int? padIndex) {
    final taken = {
      for (final c in _craft)
        if (c.anchor == anchor) c.padTile
    };
    if (padIndex != null) {
      final tiles = _padTilesOf(anchor).toList();
      if (padIndex < 0 || padIndex >= tiles.length) return _freePad(anchor);
      final tile = tiles[padIndex];
      return taken.contains(tile) ? null : tile;
    }
    return _freePad(anchor);
  }

  /// Send one delivery craft to [pad], applying the schedule's fuel rule.
  void _dispatchDelivery(int anchor, int pad, _DeliverySchedule sched) {
    // People are passengers, not cargo: their count isn't cut by return fuel.
    // Commodities are: self-fuelling shaves the return propellant off the load.
    final isPeople = sched.resource == kDeliveryPeople;
    final returnFuel = _returnFuelFor(sched.amount);
    double delivered;
    if (sched.spareFuel) {
      delivered =
          isPeople ? sched.amount : (sched.amount - returnFuel).clamp(0.0, sched.amount);
    } else {
      final half = returnFuel / 2;
      if (_stockOf(Commodity.fuel) < half ||
          _stockOf(Commodity.oxidizer) < half) {
        _blocked =
            'A ${sched.resource} delivery is grounded: not enough fuel/oxidizer to refuel it.';
        sched.timer = 0; // retry next frame
        return;
      }
      _stock[Commodity.fuel] = _stockOf(Commodity.fuel) - half;
      _stock[Commodity.oxidizer] = _stockOf(Commodity.oxidizer) - half;
      delivered = sched.amount;
    }
    // A delivery uses the SIMPLE pad animation (like Request Assistance): the
    // craft descends onto its pad, dwells while it unloads, then lifts off — no
    // free-flight autopilot (which missed the pad + looked erratic).
    _craft.add(_LandedCraft(
        anchor: anchor,
        padTile: pad,
        isRelief: false,
        resource: sched.resource,
        payload: delivered));
  }

  /// Resources that can be flown in on a scheduled delivery. 'people' is a
  /// special run that brings settlers instead of a commodity.
  static const List<String> _deliverable = [
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

  /// Delivery MANAGER for [anchor]: list every scheduled delivery, reorder
  /// (priority), assign each to a pad, add new ones, remove. Lets a starport run
  /// several deliveries in parallel across its pads.
  void _showDeliveryConfig(int anchor) {
    final padCount = _specAt(anchor)?.cellCount ?? 1;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.panel,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final list = _deliveries[anchor] ?? const <_DeliverySchedule>[];
          String padLabel(int? p) => p == null ? 'any pad' : 'pad ${p + 1}';
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Expanded(
                        child: Text('DELIVERY SCHEDULE', style: AppTheme.heading)),
                    Text('$padCount pad${padCount == 1 ? "" : "s"}',
                        style: AppTheme.dim),
                  ]),
                  const SizedBox(height: 6),
                  if (list.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No deliveries booked.', style: AppTheme.dim),
                    ),
                  // Reorderable list = dispatch priority.
                  if (list.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ReorderableListView(
                        shrinkWrap: true,
                        buildDefaultDragHandles: true,
                        onReorder: (a, b) => setSheet(() => setState(() {
                              if (b > a) b -= 1;
                              final s = list.removeAt(a);
                              list.insert(b, s);
                            })),
                        children: [
                          for (var i = 0; i < list.length; i++)
                            ListTile(
                              key: ValueKey(list[i]),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Text('${i + 1}',
                                  style: AppTheme.mono
                                      .copyWith(color: AppTheme.warn)),
                              title: Text(
                                  '${list[i].resource} · ${list[i].amount.toStringAsFixed(0)}${list[i].resource == kDeliveryPeople ? " pax" : "u"}',
                                  style: AppTheme.body),
                              subtitle: Text(
                                  '${list[i].recurring ? "every ${list[i].intervalSec.toStringAsFixed(0)}s" : "one-time"} · ${padLabel(list[i].padIndex)}'
                                  '${list[i].spareFuel ? " · self-fuel" : " · colony-fuel"}',
                                  style: AppTheme.dim),
                              trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit,
                                          size: 18, color: AppTheme.accent2),
                                      onPressed: () => _editDelivery(
                                          anchor, padCount, list[i],
                                          onDone: () => setSheet(() {})),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete,
                                          size: 18, color: AppTheme.danger),
                                      onPressed: () => setSheet(() => setState(() {
                                            list.removeAt(i);
                                            if (list.isEmpty) {
                                              _deliveries.remove(anchor);
                                            }
                                          })),
                                    ),
                                  ]),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add delivery'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accent2,
                        foregroundColor: AppTheme.bg),
                    onPressed: () {
                      final sched = _DeliverySchedule(
                        resource: Commodity.food,
                        intervalSec: 30,
                        amount: 200,
                        spareFuel: true,
                        padIndex: null,
                        timer: 30,
                      );
                      _editDelivery(anchor, padCount, sched, isNew: true,
                          onDone: () => setSheet(() {}));
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Editor for ONE delivery [sched] (resource / interval / amount-implied /
  /// spare-fuel / pad). [isNew] appends it to [anchor]'s list on save.
  void _editDelivery(int anchor, int padCount, _DeliverySchedule sched,
      {bool isNew = false, required VoidCallback onDone}) {
    var resource = sched.resource;
    var interval = sched.intervalSec;
    var spareFuel = sched.spareFuel;
    var recurring = sched.recurring;
    var padIndex = sched.padIndex;
    final amount = sched.amount;
    final returnFuel = _returnFuelFor(amount);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.panel,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isNew ? 'NEW DELIVERY' : 'EDIT DELIVERY',
                    style: AppTheme.heading),
                const SizedBox(height: 8),
                const Text('Resource', style: AppTheme.dim),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final r in _deliverable)
                    ChoiceChip(
                      label: Text(r, style: const TextStyle(fontSize: 11)),
                      selected: resource == r,
                      selectedColor: AppTheme.accent2,
                      backgroundColor: AppTheme.panelLight,
                      onSelected: (_) => setSheet(() => resource = r),
                    ),
                ]),
                const SizedBox(height: 10),
                // Recurring toggle: off (default) = a single one-time run; on =
                // repeats on the interval below.
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: AppTheme.accent2,
                  value: recurring,
                  onChanged: (v) => setSheet(() => recurring = v ?? false),
                  title: const Text('Recurring', style: AppTheme.body),
                  subtitle: Text(
                      recurring
                          ? 'Repeats automatically on the interval below.'
                          : 'One-time delivery — flies once, then clears.',
                      style: AppTheme.dim),
                ),
                if (recurring) ...[
                  Text('Every ${interval.toStringAsFixed(0)} s',
                      style: AppTheme.dim),
                  Slider(
                    value: interval,
                    min: 15,
                    max: 120,
                    divisions: 7,
                    onChanged: (v) => setSheet(() => interval = v),
                  ),
                ],
                const Text('Pad', style: AppTheme.dim),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  ChoiceChip(
                    label: const Text('Any', style: TextStyle(fontSize: 11)),
                    selected: padIndex == null,
                    selectedColor: AppTheme.accent2,
                    backgroundColor: AppTheme.panelLight,
                    onSelected: (_) => setSheet(() => padIndex = null),
                  ),
                  for (var p = 0; p < padCount; p++)
                    ChoiceChip(
                      label: Text('Pad ${p + 1}',
                          style: const TextStyle(fontSize: 11)),
                      selected: padIndex == p,
                      selectedColor: AppTheme.accent2,
                      backgroundColor: AppTheme.panelLight,
                      onSelected: (_) => setSheet(() => padIndex = p),
                    ),
                ]),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: AppTheme.accent2,
                  value: spareFuel,
                  onChanged: (v) => setSheet(() => spareFuel = v ?? true),
                  title: const Text('Craft carries spare fuel',
                      style: AppTheme.body),
                  subtitle: Text(
                      resource == kDeliveryPeople
                          ? (spareFuel
                              ? 'Brings ${amount.toStringAsFixed(0)} settlers; carries its own return fuel.'
                              : 'Brings ${amount.toStringAsFixed(0)} settlers; colony burns ${returnFuel.toStringAsFixed(0)} fuel+oxidizer for the return.')
                          : (spareFuel
                              ? 'Delivers ${(amount - returnFuel).clamp(0, amount).toStringAsFixed(0)}u (return fuel cut from cargo).'
                              : 'Delivers ${amount.toStringAsFixed(0)}u; colony burns ${returnFuel.toStringAsFixed(0)} fuel+oxidizer.'),
                      style: AppTheme.dim),
                ),
                const SizedBox(height: 6),
                ElevatedButton.icon(
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(isNew ? 'Add' : 'Save'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accent2,
                      foregroundColor: AppTheme.bg),
                  onPressed: () {
                    setState(() {
                      sched
                        ..resource = resource
                        ..intervalSec = interval
                        ..spareFuel = spareFuel
                        ..recurring = recurring
                        ..padIndex = padIndex;
                      if (isNew) {
                        // One-time runs dispatch promptly (short delay so the
                        // craft animation reads); recurring waits a full cycle.
                        sched.timer = recurring ? interval : 2.0;
                        (_deliveries[anchor] ??= []).add(sched);
                      }
                    });
                    Navigator.of(ctx).pop();
                    onDone();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Context menu for a functional building. Generic actions (bulldoze) plus a
  /// few type-specific ones (the reactor's "disable safety" easter egg).
  void _showBuildingMenu(int anchor, CitySpec spec) {
    final status = _buildingStatus(anchor, spec);
    final actions = <Widget>[
      _ctxAction(Icons.info_outline, 'Details',
          '${status.label} · ${_isConnected(anchor) ? "connected" : "cut off"}',
          status.color, () => _showResourceDetailForBuilding(anchor, spec)),
    ];
    // Reactor easter egg: SCRAM the safeties for a meltdown.
    if (spec.type == 'reactor' || spec.type == 'fusion') {
      actions.add(_ctxAction(
          Icons.warning_amber,
          'Disable safety systems',
          'Override the SCRAM interlocks. What could go wrong?',
          AppTheme.danger,
          () => _meltdown(anchor)));
    }
    // Spaceports + airfields are launch sites: enter the VAB to design a craft
    // and launch it (rockets from spaceports, spaceplanes from airfields).
    if (spec.type == 'spaceport' || spec.type == 'airfield') {
      final connected = _isConnected(anchor);
      final plane = spec.type == 'airfield';
      actions.add(_ctxAction(
          Icons.precision_manufacturing,
          'Design & launch craft',
          connected
              ? 'Open the VAB; launch a ${plane ? "spaceplane" : "rocket"} from here.'
              : 'Connect this ${spec.label} to the road network first.',
          connected ? AppTheme.accent2 : AppTheme.textDim,
          connected ? _openVab : () {}));
    }
    // Spaceports double as landing pads: park the lander here (occupied state).
    if (spec.type == 'spaceport') {
      final parked = _landerPad == anchor;
      actions.add(_ctxAction(
          parked ? Icons.flight_takeoff : Icons.flight_land,
          parked ? 'Lander is parked here' : 'Land lander on this pad',
          parked
              ? 'Clear the pad for incoming shuttles.'
              : 'Move the landing site onto this spaceport (marks it occupied).',
          AppTheme.accent2,
          () => setState(() => _landerPad = parked ? null : anchor)));
      // Anti-soft-lock lifeline: call in a relief mission that lands on a free
      // pad, dwells 30 s + drops supplies + settlers, then leaves. Cooldown +
      // needs a free pad (a spaceport has one pad per footprint tile).
      final cd = _reliefCooldown.ceil();
      final hasPad = _freePad(anchor) != null;
      final canRelief = _reliefCooldown <= 0 && hasPad;
      actions.add(_ctxAction(
          Icons.volunteer_activism,
          canRelief
              ? 'Request assistance'
              : (!hasPad ? 'All pads busy' : 'Assistance on cooldown'),
          canRelief
              ? 'A relief craft lands here with food, water, ore, fuel, funds + 8 settlers.'
              : (!hasPad
                  ? 'Every pad on this spaceport is occupied — wait for one to clear.'
                  : 'Recovering — available again in ${cd}s.'),
          canRelief ? AppTheme.accent2 : AppTheme.textDim,
          canRelief ? () => _requestRelief(anchor) : () {}));
      // Recurring resource deliveries (a list — a starport runs several).
      final list = _deliveries[anchor];
      final n = list?.length ?? 0;
      actions.add(_ctxAction(
          Icons.local_shipping,
          n == 0 ? 'Schedule deliveries' : 'Deliveries ($n booked)',
          n == 0
              ? 'Book recurring resource deliveries to this spaceport.'
              : 'Manage, reorder + assign deliveries to pads.',
          AppTheme.accent2,
          () => _showDeliveryConfig(anchor)));
      // Fly a manual descent over the colony onto this spaceport's pads.
      actions.add(_ctxAction(
          Icons.flight_land,
          'Pilot a landing',
          'Fly an in-atmo descent over the colony — touch down on a pad, or smash '
              'into the city.',
          AppTheme.warn,
          () => _pilotLanding(anchor)));
      // Launch into the real 3D solar-system sim (spherical planet + camera +
      // staging) from this world's surface.
      actions.add(_ctxAction(
          Icons.rocket_launch,
          'Launch in 3D sim',
          'Fly a staged ascent in the full 3D sim — real planet sphere, orbit '
              'camera, and STAGE/decouple.',
          AppTheme.accent2,
          _fly3DAscent));
    }
    actions.add(_ctxAction(Icons.delete, 'Demolish',
        'Tear it down (partial ore refund).', AppTheme.danger,
        () => setState(() {
              _clearCell(anchor);
              _recompute();
            })));
    _contextMenu(spec.label, spec.icon, spec.color, actions);
  }

  /// Diagnose this building's worst current problem so the Details readout +
  /// modal explain WHY it's flagged (matches the on-map status icons) instead
  /// of always claiming "Operating". Checked worst-first; the first hit wins.
  ({String label, String why, String fix, Color color}) _buildingStatus(
      int anchor, CitySpec spec) {
    final powerRatio =
        _powerDraw <= 0 ? 1.0 : (_powerOut / _powerDraw).clamp(0.0, 1.0);
    final needsPower = spec.powerDraw > 0;
    final needsStaff = spec.jobs > 0;

    if (_abandoned.contains(anchor)) {
      return (
        label: 'Abandoned',
        why: 'Its people walked out after this building lost road or power for '
            'too long. An abandoned building produces nothing and decays into '
            'rubble if the failure isn\'t fixed.',
        fix: 'Reconnect it to the road network and restore power. Once '
            'infrastructure is back it can be reoccupied.',
        color: AppTheme.danger,
      );
    }
    if (!_isConnected(anchor)) {
      return (
        label: 'Cut off',
        why: 'This building has no road path back to the colony hub, so no '
            'workers, goods, or services reach it. It produces nothing while '
            'disconnected.',
        fix: 'Lay a road connecting it to the hub network. Watch for gaps, '
            'water, or demolished tiles breaking the path.',
        color: AppTheme.danger,
      );
    }
    if (needsPower && powerRatio < 0.95) {
      return (
        label: 'Unpowered',
        why: 'The grid is supplying only ${(powerRatio * 100).toStringAsFixed(0)}% '
            'of demand (${_powerOut.toStringAsFixed(0)}/${_powerDraw.toStringAsFixed(0)} '
            'power). Under-powered buildings run throttled and risk abandonment.',
        fix: 'Build more generators (solar / reactor / fusion) or demolish '
            'non-essential draws until supply exceeds demand.',
        color: AppTheme.warn,
      );
    }
    if (needsStaff && _staffing < 0.95) {
      return (
        label: 'Understaffed',
        why: 'The city can only fill ${(_staffing * 100).toStringAsFixed(0)}% of '
            'its jobs, so this building runs short-handed and below full output. '
            'Too few workers, or congestion stretching their commute.',
        fix: 'Grow population (housing + a connected spaceport for immigrants), '
            'or cut road congestion + excess jobs so workers go round.',
        color: AppTheme.warn,
      );
    }
    if (_corpses > 1) {
      return (
        label: 'Bodies unprocessed',
        why: 'There are ${_corpses.toStringAsFixed(0)} unprocessed corpses in '
            'the colony. The backlog breeds disease and litters the streets, '
            'dragging happiness across every building.',
        fix: 'Build / connect deathcare (cemetery, crematorium) and keep it '
            'powered + staffed so bodies are processed faster than they pile up.',
        color: AppTheme.warn,
      );
    }
    if (_happiness < 0.5) {
      return (
        label: 'Unhappy',
        why: 'Colony happiness is ${(_happiness * 100).toStringAsFixed(0)}%. '
            'Low happiness slows growth and, if it keeps falling, risks unrest '
            'and citizens fleeing.',
        fix: 'Balance R/C/I demand, fund services (health, parks, transit), and '
            'cut crime, pollution, and inequality. Some laws lift happiness.',
        color: AppTheme.warn,
      );
    }
    return (
      label: 'Operating',
      why: 'Connected, powered, and staffed — running at full output.',
      fix: 'Keep it road-connected, powered, and the city well-staffed.',
      color: AppTheme.accent2,
    );
  }

  void _showResourceDetailForBuilding(int anchor, CitySpec spec) {
    final status = _buildingStatus(anchor, spec);
    final io = <String>[];
    spec.inputs.forEach((k, v) => io.add('−${v.toStringAsFixed(1)} ${Commodity.name(k)}/s'));
    spec.outputs.forEach((k, v) => io.add('+${v.toStringAsFixed(1)} ${Commodity.name(k)}/s'));
    if (spec.powerOutput > 0) io.add('+${spec.powerOutput.toStringAsFixed(0)} power');
    if (spec.powerDraw > 0) io.add('−${spec.powerDraw.toStringAsFixed(0)} power');
    if (spec.jobs > 0) io.add('${spec.jobs} jobs');
    if (spec.housing > 0) io.add('${spec.housing} housing');
    // Lead the WHY with the status diagnosis, then the IO stats so the modal
    // explains the flagged problem instead of just listing throughput.
    final stats = io.isEmpty ? 'A passive structure.' : io.join('\n');
    _showExplain(
        '${spec.label} — ${status.label}',
        '${status.why}\n\n$stats',
        status.fix,
        status.color);
  }

  /// Reactor meltdown easter egg: SCRAM the safeties and watch it go up — fires
  /// the nuke disaster (radiation + nuclear winter), centred on the city.
  void _meltdown(int anchor) {
    _triggerDisaster(_Disaster.nuke);
    setState(() {
      _radiation = (_radiation + 0.3).clamp(0.0, 1.0);
      _clearCell(anchor); // the reactor is gone
      _recompute();
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('☢ MELTDOWN — safety interlocks disabled. Oops.'),
        backgroundColor: Color(0xFF6B1414),
        duration: Duration(seconds: 4)));
  }

  Widget _disasterControls() {
    // Only offer disasters that make physical sense on this planet + biome
    // (airless worlds get no wind/rain; deserts don't snow; oceans don't burn).
    final all =
        _Disaster.values.where((d) => d != _Disaster.none && _disasterPossible(d));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(_hasWarning ? Icons.sensors : Icons.sensors_off,
            size: 14,
            color: _hasWarning ? AppTheme.accent2 : AppTheme.textDim),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _hasWarning
                ? 'Early-warning online — disasters are forecast, prep your bunkers.'
                : 'No early-warning station — build one to forecast disasters.'
                    ' Bunkers + Emergency Services reduce harm.',
            style: AppTheme.dim.copyWith(
                color: _hasWarning ? AppTheme.accent2 : AppTheme.textDim),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      if (_disaster != _Disaster.none)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Icon(_disaster.icon, size: 16, color: AppTheme.warn),
            const SizedBox(width: 6),
            Text('${_disaster.label} active (${_disasterTime.toStringAsFixed(0)}s)',
                style: AppTheme.dim.copyWith(color: AppTheme.warn)),
          ]),
        ),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final d in all)
          GestureDetector(
            onTap: () => _triggerDisaster(d),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: _disaster == d
                    ? AppTheme.warn
                    : (d == _Disaster.nuke
                        ? AppTheme.danger.withValues(alpha: 0.2)
                        : AppTheme.panelLight),
                borderRadius: BorderRadius.circular(6),
                border: d == _Disaster.nuke
                    ? Border.all(color: AppTheme.danger)
                    : null,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(d.icon,
                    size: 13,
                    color: d == _Disaster.nuke
                        ? AppTheme.danger
                        : (_disaster == d ? AppTheme.bg : AppTheme.text)),
                const SizedBox(width: 4),
                Text(d.label,
                    style: TextStyle(
                        fontSize: 11,
                        color: d == _Disaster.nuke
                            ? AppTheme.danger
                            : (_disaster == d ? AppTheme.bg : AppTheme.text))),
              ]),
            ),
          ),
      ]),
    ]);
  }

  Widget _planetPanel() => Container(
        padding: const EdgeInsets.all(10),
        decoration: AppTheme.panelBox(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.public, size: 16, color: AppTheme.accent),
            const SizedBox(width: 6),
            const Text('Planet', style: AppTheme.body),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButton<CelestialBody>(
                value: _body,
                isExpanded: true,
                dropdownColor: AppTheme.panelLight,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: [
                  for (final b in _bodies)
                    DropdownMenuItem(
                        value: b, child: Text(b.name, style: AppTheme.body)),
                ],
                onChanged: (b) => setState(() => _body = b!),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.terrain, size: 16, color: AppTheme.accent2),
            const SizedBox(width: 6),
            const Text('Biome', style: AppTheme.body),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButton<Biome>(
                value: _biome,
                isExpanded: true,
                dropdownColor: AppTheme.panelLight,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: [
                  for (final b in Biome.values)
                    DropdownMenuItem(
                        value: b, child: Text(_biomeName(b), style: AppTheme.body)),
                ],
                onChanged: (b) => setState(() => _biome = b!),
              ),
            ),
          ]),
          Text(_biomeSummary(), style: AppTheme.dim.copyWith(fontSize: 11)),
          const SizedBox(height: 4),
          Wrap(spacing: 14, runSpacing: 4, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.solar_power, size: 14, color: Color(0xFFFFD23F)),
              const SizedBox(width: 4),
              Text('Solar ×${_solarFactor.toStringAsFixed(2)}',
                  style: AppTheme.mono.copyWith(
                      color: _solarFactor >= 1 ? AppTheme.accent2 : AppTheme.warn,
                      fontSize: 12)),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.wind_power, size: 14, color: Color(0xFFB2DFDB)),
              const SizedBox(width: 4),
              Text('Wind ×${_windFactor.toStringAsFixed(2)}',
                  style: AppTheme.mono.copyWith(
                      color:
                          _windFactor >= 0.5 ? AppTheme.accent2 : AppTheme.warn,
                      fontSize: 12)),
            ]),
          ]),
          if (_windFactor < 0.05)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('Airless world — wind turbines are useless here.',
                  style: AppTheme.dim.copyWith(color: AppTheme.warn)),
            ),
          const SizedBox(height: 2),
          Row(children: [
            Icon(_breathable ? Icons.air : Icons.masks,
                size: 14,
                color: _breathable ? AppTheme.accent2 : AppTheme.warn),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                _breathable
                    ? 'Breathable air (O₂ ${(_o2Fraction * 100).toStringAsFixed(0)}%) — oxygen free.'
                    : _o2Harvestable
                        ? 'Thin O₂ (${(_o2Fraction * 100).toStringAsFixed(0)}%) — harvest or split water.'
                        : 'No breathable O₂ — split water (electrolysis) or shuttle in.',
                style: AppTheme.dim.copyWith(
                    color: _breathable ? AppTheme.accent2 : AppTheme.warn,
                    fontSize: 11),
              ),
            ),
          ]),
          const Divider(height: 14, color: Color(0xFF223247)),
          _surfaceReadout(),
        ]),
      );

  /// Live physical surface-conditions readout (temp / pressure / water /
  /// habitability) — the scalars that drive flora + colony style.
  Widget _surfaceReadout() {
    final s = _surface;
    final hab = s.habitability;
    final habCol = hab > 0.6
        ? AppTheme.accent2
        : (hab > 0.3 ? AppTheme.warn : AppTheme.danger);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.thermostat, size: 14, color: AppTheme.textDim),
        const SizedBox(width: 4),
        Text('SURFACE — ${s.summary}',
            style: AppTheme.dim.copyWith(
                color: habCol, fontWeight: FontWeight.bold, fontSize: 11)),
      ]),
      const SizedBox(height: 4),
      Wrap(spacing: 12, runSpacing: 2, children: [
        _condChip('Temp', '${s.temperatureC.toStringAsFixed(0)}°C'),
        _condChip('Press', '${(s.pressureAtm).toStringAsFixed(2)} atm'),
        _condChip('Water', '${(s.waterActivity * 100).toStringAsFixed(0)}%'),
        _condChip('Aquifer', '${(_waterTable * 100).toStringAsFixed(0)}%'),
        _condChip('Grav', '${s.gravityG.toStringAsFixed(2)}g'),
      ]),
      if (_waterTable < 0.4)
        Text('Water table low — pumping is drying the surface; plants dying back.',
            style: AppTheme.dim.copyWith(
                color: _waterTable < 0.2 ? AppTheme.danger : AppTheme.warn,
                fontSize: 11)),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
            value: hab,
            minHeight: 6,
            backgroundColor: AppTheme.panelLight,
            color: habCol),
      ),
      const SizedBox(height: 2),
      Text('Habitability ${(hab * 100).toStringAsFixed(0)}% — '
          '${hab > 0.5 ? "plants thrive" : hab > 0.15 ? "sparse life" : "barren; terraform to grow life"}',
          style: AppTheme.dim.copyWith(fontSize: 11, color: habCol)),
      const SizedBox(height: 4),
      Builder(builder: (_) {
        final l = _liquid;
        return Row(children: [
          Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                  color: Color(l.colorArgb),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: const Color(0x33FFFFFF)))),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                'Surface liquid: ${l.label}'
                '${l.isMolten ? " (molten — lethal)" : l.combustible ? " (fuel)" : l.potable ? " (drinkable)" : ""}'
                '${_oceanPollution > 0.05 ? " · polluted" : ""}',
                style: AppTheme.dim.copyWith(fontSize: 11)),
          ),
        ]);
      }),
    ]);
  }

  Widget _condChip(String label, String value) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label ', style: AppTheme.dim.copyWith(fontSize: 11)),
          Text(value,
              style: AppTheme.mono.copyWith(fontSize: 11, color: AppTheme.text)),
        ],
      );

  Widget _blockedBanner() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
            color: AppTheme.danger.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          const Icon(Icons.block, color: AppTheme.danger, size: 16),
          const SizedBox(width: 8),
          Expanded(
              child: Text(_blocked!,
                  style: AppTheme.dim.copyWith(color: AppTheme.danger))),
        ]),
      );

  Widget _zonePicker() {
    Widget kindChip(String kind, String label, Color color) {
      final sel = _tool == _Tool.zone && _zoneKind == kind;
      return GestureDetector(
        onTap: () => setState(() {
          _tool = _Tool.zone;
          _zoneKind = kind;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: sel ? color : AppTheme.panelLight,
              borderRadius: BorderRadius.circular(6)),
          child: Text(label,
              style: TextStyle(fontSize: 12, color: sel ? AppTheme.bg : AppTheme.text)),
        ),
      );
    }

    Widget densityChip(Density d, String label) {
      final sel = _density == d;
      return GestureDetector(
        onTap: () => setState(() {
          _tool = _Tool.zone;
          _density = d;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
              color: sel ? AppTheme.accent : AppTheme.panelLight,
              borderRadius: BorderRadius.circular(6)),
          child: Text(label,
              style: TextStyle(fontSize: 11, color: sel ? AppTheme.bg : AppTheme.text)),
        ),
      );
    }

    final spec = kZoneSpecs[_zoneKind]![_density]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          kindChip('residential', 'Residential', const Color(0xFF7FE0A0)),
          kindChip('commercial', 'Commercial', const Color(0xFF4FC3F7)),
          kindChip('industrial', 'Industrial', const Color(0xFFE3A857)),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          densityChip(Density.low, 'Low'),
          densityChip(Density.medium, 'Medium'),
          densityChip(Density.high, 'High'),
        ]),
        const SizedBox(height: 4),
        Text(
            'Grows: ${spec.label} — ${spec.housing > 0 ? "+${spec.housing} housing" : "${spec.jobs} jobs"} · ${_zoneBuildCost.toStringAsFixed(0)} ore each',
            style: AppTheme.dim),
      ],
    );
  }

  List<Widget> _utilGroup(String grp, [String q = '']) {
    final group = kUtilCatalog
        .where((u) => u.group == grp && _matchesSearch(u, q))
        .toList();
    if (group.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2, left: 2),
        child: Text(kGroupLabels[grp] ?? grp,
            style: AppTheme.dim.copyWith(
                color: AppTheme.accent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.6)),
      ),
      for (final u in group) _utilRow(u),
    ];
  }

  Widget _utilRow(CitySpec u) {
    final sel = _tool == _Tool.utility && _selectedUtil.type == u.type;
    final locked = !_unlocked(u);
    return Card(
      color: sel ? u.color.withValues(alpha: 0.18) : AppTheme.panel,
      margin: const EdgeInsets.symmetric(vertical: 3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: sel ? u.color : const Color(0xFF223247)),
      ),
      child: ExpansionTile(
        dense: true,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(u.icon, color: locked ? AppTheme.textDim : u.color),
        title: Row(children: [
          Expanded(
              child: Text(u.label,
                  style: AppTheme.body.copyWith(
                      color: locked ? AppTheme.textDim : AppTheme.text))),
          if (locked)
            Text('pop ${u.unlockPop}', style: AppTheme.dim)
          else
            _costChip(u.buildCost),
        ]),
        subtitle: Text(_specSummary(u), style: AppTheme.dim),
        onExpansionChanged: (_) => setState(() {
          _tool = _Tool.utility;
          _selectedUtil = u;
        }),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        children: [_effectDetail(u)],
      ),
    );
  }

  String _specSummary(CitySpec s) {
    final bits = <String>[];
    if (s.jobs > 0) bits.add('${s.jobs} jobs');
    if (s.powerOutput > 0) bits.add('+${s.powerOutput.toStringAsFixed(0)} pwr');
    if (s.computeOutput > 0) bits.add('+${s.computeOutput.toStringAsFixed(0)} compute');
    for (final e in s.outputs.entries) {
      bits.add('→${Commodity.name(e.key)}');
    }
    if (s.services.isNotEmpty) bits.add(s.services.keys.first);
    if (s.storageBonus > 0) bits.add('+${s.storageBonus.toStringAsFixed(0)} storage');
    return bits.take(3).join(' · ');
  }

  Widget _effectDetail(CitySpec s) {
    Widget line(String l, String v, [Color? c]) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            Expanded(child: Text(l, style: AppTheme.dim)),
            Text(v, style: AppTheme.mono.copyWith(color: c ?? AppTheme.text)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (s.jobs > 0) line('Jobs', '${s.jobs}'),
      if (s.powerOutput > 0)
        line(
            'Power',
            _powerFactor(s.type) == 1.0
                ? '+${s.powerOutput.toStringAsFixed(0)}'
                : '+${(s.powerOutput * _powerFactor(s.type)).toStringAsFixed(0)} (×${_powerFactor(s.type).toStringAsFixed(2)} here)',
            AppTheme.accent2),
      if (s.powerDraw > 0)
        line('Power draw', '-${s.powerDraw.toStringAsFixed(0)}', AppTheme.warn),
      if (s.computeOutput > 0)
        line('Compute', '+${s.computeOutput.toStringAsFixed(0)}', AppTheme.accent2),
      if (s.computeDraw > 0)
        line('Compute use', '-${s.computeDraw.toStringAsFixed(0)}', AppTheme.warn),
      for (final e in s.inputs.entries)
        line('Needs ${Commodity.name(e.key)}', '-${e.value.toStringAsFixed(1)}/s',
            AppTheme.warn),
      for (final e in s.outputs.entries)
        line('Makes ${Commodity.name(e.key)}', '+${e.value.toStringAsFixed(1)}/s',
            AppTheme.accent2),
      for (final e in s.services.entries)
        line('${_cap(e.key)} service', '${e.value.toStringAsFixed(0)} pop',
            AppTheme.accent),
      if (s.pollution > 0)
        line('Pollution', '+${s.pollution.toStringAsFixed(1)}/s', AppTheme.warn),
      if (s.storageBonus > 0)
        line('Storage', '+${s.storageBonus.toStringAsFixed(0)}', AppTheme.accent2),
      const SizedBox(height: 4),
      Text('Build: ${s.buildCost.toStringAsFixed(0)} ore', style: AppTheme.dim),
    ]);
  }

  Widget _costChip(double cost) {
    final afford = _stockOf(Commodity.ore) >= cost;
    final c = afford ? AppTheme.accent2 : AppTheme.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
          color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
      child: Text('${cost.toStringAsFixed(0)} ore',
          style: AppTheme.mono.copyWith(color: c, fontSize: 11)),
    );
  }

  // ---- Status widgets ----

  /// Compact stockpile summary — one chip per resource in a Wrap, shown above
  /// the render. Each chip: name, amount, and the net /s (throttled), with the
  /// unthrottled potential in parentheses when staffing/power/compute is cutting
  /// production.
  Widget _stockChips() {
    final cap = _stockCap;
    final rate = _netRates();
    final raw = _netRates(throttled: false);
    final shown = Commodity.ordered.where((c) =>
        _stockOf(c) > 0.05 ||
        (rate[c]?.abs() ?? 0) > 0.05 ||
        c == Commodity.ore ||
        c == Commodity.food ||
        c == Commodity.water);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: AppTheme.panel,
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final c in shown)
          GestureDetector(
            onTap: () => _showResourceDetail(c),
            child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.bg,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                  color: _stockOf(c) >= cap - 0.5
                      ? AppTheme.warn
                      : const Color(0xFF223247)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${Commodity.name(c)} ',
                  style: AppTheme.dim.copyWith(fontSize: 11)),
              _infiniteRes && c != Commodity.garbage && c != Commodity.sewage
                  ? const Icon(Icons.all_inclusive,
                      size: 12, color: AppTheme.accent2)
                  : Text(_stockOf(c).toStringAsFixed(0),
                      style: AppTheme.mono.copyWith(fontSize: 11)),
              const SizedBox(width: 4),
              Text(_fmtRate(rate[c] ?? 0),
                  style: AppTheme.mono.copyWith(
                      fontSize: 11,
                      color: (rate[c] ?? 0) >= 0
                          ? AppTheme.accent2
                          : AppTheme.warn)),
              // Show the unthrottled potential when it differs (production cut).
              if (((raw[c] ?? 0) - (rate[c] ?? 0)).abs() > 0.05)
                Text(' (${_fmtRate(raw[c] ?? 0)})',
                    style: AppTheme.mono.copyWith(
                        fontSize: 10, color: AppTheme.textDim)),
            ]),
          ),
          ),
      ]),
    );
  }

  List<Widget> _stockRows() {
    final cap = _stockCap;
    final rates = _netRates();
    final raw = _netRates(throttled: false);
    bool show(String c) =>
        _stockOf(c) > 0.05 ||
        (rates[c]?.abs() ?? 0) > 0.05 ||
        c == Commodity.ore ||
        c == Commodity.food ||
        c == Commodity.water;
    final out = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          const Expanded(child: Text('Capacity / resource', style: AppTheme.dim)),
          Text(cap.toStringAsFixed(0),
              style: AppTheme.mono.copyWith(color: AppTheme.accent)),
        ]),
      ),
    ];
    // Group by section: Raw Resources / Components / Finished Goods.
    for (final section in Commodity.sections) {
      final inSection = Commodity.ordered
          .where((c) => Commodity.section(c) == section && show(c))
          .toList();
      if (inSection.isEmpty) continue;
      out.add(Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text(section,
            style: AppTheme.dim.copyWith(
                color: AppTheme.accent,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.6)),
      ));
      for (final c in inSection) {
        out.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(Commodity.name(c), style: AppTheme.body)),
            Text('${_stockOf(c).toStringAsFixed(0)}/${cap.toStringAsFixed(0)}',
                style: AppTheme.mono.copyWith(
                    color: _stockOf(c) >= cap - 0.5
                        ? AppTheme.warn
                        : _stockOf(c) > 0
                            ? AppTheme.text
                            : AppTheme.textDim)),
            SizedBox(
              width: 96,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: _fmtRate(rates[c] ?? 0),
                      style: AppTheme.mono.copyWith(
                          fontSize: 11,
                          color: (rates[c] ?? 0) >= 0
                              ? AppTheme.accent2
                              : AppTheme.warn)),
                  if (((raw[c] ?? 0) - (rates[c] ?? 0)).abs() > 0.05)
                    TextSpan(
                        text: ' (${_fmtRate(raw[c] ?? 0)})',
                        style: AppTheme.mono.copyWith(
                            fontSize: 10, color: AppTheme.textDim)),
                ]),
                textAlign: TextAlign.right,
              ),
            ),
          ]),
        ));
      }
    }
    return out;
  }

  /// Net rates. [throttled] true applies the live production throttle (power /
  /// compute / staffing); false gives the full nameplate potential. Life-support
  /// consumption is the same in both.
  Map<String, double> _netRates({bool throttled = true}) {
    final t = throttled ? _throttle : 1.0;
    final r = <String, double>{};
    for (final e in _activeSpecs) {
      e.value.outputs.forEach((k, v) => r[k] = (r[k] ?? 0) + v * t);
      e.value.inputs.forEach((k, v) => r[k] = (r[k] ?? 0) - v * t);
    }
    r[Commodity.food] = (r[Commodity.food] ?? 0) - _population * _foodPerPersonPerSec;
    r[Commodity.water] = (r[Commodity.water] ?? 0) - _population * _waterPerPersonPerSec;
    if (!_breathable) {
      r[Commodity.oxygen] =
          (r[Commodity.oxygen] ?? 0) - _population * _waterPerPersonPerSec;
    }
    // Population GENERATES waste (positive net = it's piling up).
    r[Commodity.garbage] =
        (r[Commodity.garbage] ?? 0) + _population * _garbagePerPersonPerSec;
    r[Commodity.sewage] =
        (r[Commodity.sewage] ?? 0) + _population * _sewagePerPersonPerSec;
    return r;
  }

  String _fmtRate(double r) =>
      r.abs() < 0.05 ? '±0/s' : '${r >= 0 ? "+" : ""}${r.toStringAsFixed(1)}/s';

  /// Per-building producer/consumer breakdown for a commodity (counts + total
  /// throttled rate per building type).
  ({List<({String label, double rate, int count})> producers,
    List<({String label, double rate, int count})> consumers,
    double lifeSupport}) _commodityBreakdown(String c) {
    final prod = <String, ({double rate, int count})>{};
    final cons = <String, ({double rate, int count})>{};
    for (final e in _activeSpecs) {
      final s = e.value;
      final out = (s.outputs[c] ?? 0) * _biomeMult(c) * _throttle;
      final inp = (s.inputs[c] ?? 0) * _throttle;
      if (out > 0) {
        final cur = prod[s.label];
        prod[s.label] =
            (rate: (cur?.rate ?? 0) + out, count: (cur?.count ?? 0) + 1);
      }
      if (inp > 0) {
        final cur = cons[s.label];
        cons[s.label] =
            (rate: (cur?.rate ?? 0) + inp, count: (cur?.count ?? 0) + 1);
      }
    }
    var life = 0.0;
    if (c == Commodity.food) life = _population * _foodPerPersonPerSec;
    if (c == Commodity.water) life = _population * _waterPerPersonPerSec;
    if (c == Commodity.oxygen && !_breathable) {
      life = _population * _waterPerPersonPerSec;
    }
    List<({String label, double rate, int count})> rows(
            Map<String, ({double rate, int count})> m) =>
        [for (final e in m.entries) (label: e.key, rate: e.value.rate, count: e.value.count)]
          ..sort((a, b) => b.rate.compareTo(a.rate));
    return (producers: rows(prod), consumers: rows(cons), lifeSupport: life);
  }

  /// A "why did this happen / how to fix" modal for a warning or status.
  void _showExplain(String title, String why, String fix, Color color) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: AppTheme.panel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: AppTheme.title.copyWith(color: color, fontSize: 18)),
                const SizedBox(height: 14),
                Text('WHY',
                    style: AppTheme.dim.copyWith(
                        color: AppTheme.warn,
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(why, style: AppTheme.body),
                const SizedBox(height: 14),
                Text('HOW TO FIX',
                    style: AppTheme.dim.copyWith(
                        color: AppTheme.accent2,
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(fix, style: AppTheme.body),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('GOT IT'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Tap handler for a status alert chip — explains that specific situation.
  void _explainAlert(String key) {
    switch (key) {
      case 'starving':
        _showExplain(
            'Starving',
            'Your food or water (or oxygen, off-world) ran out — the stockpile has '
                'less than a few seconds of runway, so citizens are leaving and dying.',
            'Build more Farms (food) and Water Plants. On non-breathable worlds add '
                'Electrolysis or an O₂ Harvester. Tap the Food/Water/Oxygen chip to see '
                'the exact production vs. consumption.',
            AppTheme.danger);
      case 'spaceport':
        final (title, body, fix) = switch (_noSpaceportReason) {
          1 => (
              'Spaceport Cut Off',
              'You have a spaceport, but it lost its road link to the hub (a road '
                  'was bulldozed or never reached it), so no immigrants can arrive '
                  'and population growth has stopped.',
              'Re-lay a road connecting the spaceport back to the hub network.'
            ),
          2 => (
              'Spaceport Demolished',
              'Your spaceport was demolished (or destroyed by a disaster). A colony '
                  'only grows while a working, connected spaceport lets immigrants '
                  'arrive — without one, population stalls and drifts down.',
              'Rebuild a Spaceport (TRANSPORT group) next to a road that links back '
                  'to the hub.'
            ),
          _ => (
              'No Spaceport',
              'A colony only grows when immigrants can arrive — that needs a working '
                  'spaceport connected to the road network. Without one, population stays 0.',
              'Place a Spaceport (TRANSPORT group) on a tile next to a road that links '
                  'back to the hub.'
            ),
        };
        _showExplain(title, body, fix, AppTheme.warn);
      case 'fire':
        _showExplain(
            'Buildings on Fire',
            'A fire is burning through the colony. It spreads to adjacent buildings '
                '— roads and empty ground act as firebreaks that stop it.',
            'Build Emergency Services / Police near at-risk districts (they put fires '
                'out within range), and bulldoze a gap to break the spread.',
            AppTheme.danger);
      case 'pollution':
        _showExplain(
            'Air Pollution',
            'Industry, power plants and dense zones emit pollution. High pollution '
                'drags happiness and breeds disease.',
            'Add Parks + Forest biome (scrub the air), pass the Emissions Cap, build '
                'Terraforming Towers, or switch dirty power to solar/wind/fusion.',
            AppTheme.warn);
      case 'disease':
        _showExplain(
            'Disease Outbreak',
            'Sickness is spreading — driven by poor healthcare coverage, pollution, '
                'a corpse backlog, or filth in the streets. It kills people.',
            'Build Clinics/Hospitals (health coverage), clear waste + corpses, and '
                'cut pollution.',
            AppTheme.danger);
      case 'power':
        _showExplain(
            'Power Shortage',
            'Demand outstrips generation, so buildings throttle down (and eventually '
                'go dark / abandon).',
            'Build more power (solar/wind/reactor/fusion) or reduce draw.',
            AppTheme.warn);
      default:
        _showExplain(
            'City Healthy',
            'You have a connected spaceport and life support is stocked, so the '
                'population is immigrating toward your housing capacity.',
            'Keep housing, services, food/water/oxygen and power ahead of demand to '
                'keep growing.',
            AppTheme.accent2);
    }
  }

  void _showResourceDetail(String c) {
    final bd = _commodityBreakdown(c);
    final net = _netRates()[c] ?? 0;
    final raw = _netRates(throttled: false)[c] ?? 0;
    final cap = _stockCap;
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: AppTheme.panel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Commodity.name(c),
                    style: AppTheme.title.copyWith(
                        color: AppTheme.accent, fontSize: 18)),
                const SizedBox(height: 2),
                Text('Section: ${Commodity.section(c)}', style: AppTheme.dim),
                const SizedBox(height: 12),
                _kvLine('In stock', '${_stockOf(c).toStringAsFixed(0)} / ${cap.toStringAsFixed(0)}'),
                _kvLine('Net rate',
                    _fmtRate(net) + (((raw - net).abs() > 0.05) ? '  (potential ${_fmtRate(raw)})' : ''),
                    net >= 0 ? AppTheme.accent2 : AppTheme.warn),
                if (raw - net > 0.05)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        'Production throttled to ${(_throttle * 100).toStringAsFixed(0)}% — '
                        '${_bottleneckName()} is the limiter.',
                        style: AppTheme.dim.copyWith(color: AppTheme.warn)),
                  ),
                const SizedBox(height: 14),
                _detailSection('PRODUCED BY', bd.producers, AppTheme.accent2),
                _detailSection('CONSUMED BY', bd.consumers, AppTheme.warn),
                if (bd.lifeSupport > 0.001)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      const Expanded(
                          child: Text('Population life support', style: AppTheme.body)),
                      Text('-${bd.lifeSupport.toStringAsFixed(1)}/s',
                          style: AppTheme.mono.copyWith(color: AppTheme.warn)),
                    ]),
                  ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: AppTheme.bg,
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(_howToGrow(c), style: AppTheme.dim),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('CLOSE'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailSection(
      String title, List<({String label, double rate, int count})> rows,
      Color color) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: AppTheme.dim.copyWith(
              color: color, fontSize: 10, fontWeight: FontWeight.bold)),
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text('${r.label} ×${r.count}', style: AppTheme.body)),
            Text('${r.rate >= 0 ? "+" : ""}${r.rate.toStringAsFixed(1)}/s',
                style: AppTheme.mono.copyWith(color: color)),
          ]),
        ),
      const SizedBox(height: 8),
    ]);
  }

  Widget _kvLine(String k, String v, [Color? c]) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(k, style: AppTheme.body)),
          Text(v, style: AppTheme.mono.copyWith(color: c ?? AppTheme.text)),
        ]),
      );

  String _bottleneckName() {
    final power = _powerDraw <= 0 ? 1.0 : (_powerOut / _powerDraw).clamp(0.0, 1.0);
    final compute = _computeDemand <= 0 ? 1.0 : (_computeSupply / _computeDemand).clamp(0.0, 1.0);
    if (_staffing <= power && _staffing <= compute) return 'staffing (not enough workers)';
    if (power <= compute) return 'power (brownout)';
    return 'compute (data shortfall)';
  }

  String _howToGrow(String c) => switch (c) {
        Commodity.ore => 'Build more Mines. Heavy Industry zones also refine ore→steel.',
        Commodity.steel => 'Build Steel Mills (need ore) or zone Industrial.',
        Commodity.water => 'Build Water Plants; biome + rain boost it.',
        Commodity.food => 'Build Farms (need water). Avoid nuclear winter.',
        Commodity.oxygen => _breathable
            ? 'Breathable world — oxygen is free here.'
            : 'Build Electrolysis Plants (split water) or an O₂ Harvester.',
        Commodity.electronics => 'Build Electronics Plants (need steel + compute).',
        Commodity.compute => 'Build Data Centers (need electronics + lots of power).',
        Commodity.tubes => 'Steel Mills produce tubes as a byproduct.',
        Commodity.rocketParts => 'Build a Rocket Parts Factory (tubes + electronics).',
        Commodity.fuel || Commodity.oxidizer => 'Build Refineries (need ore).',
        Commodity.guns || Commodity.ammo => 'Build an Arms Factory (steel + electronics).',
        Commodity.missiles => 'Build a Missile Plant (tubes + rocket parts).',
        Commodity.rations => 'Build a Rations Plant (need food).',
        Commodity.medicine =>
          'Build Chemists (small) or a Pharma Plant (big). Hospitals + Clinics '
              'consume it; without medicine their health coverage drops.',
        Commodity.garbage =>
          'This is WASTE — keep it near zero. Build Landfills (cheap) or Recycling '
              'Centers (recover ore + steel) to consume it faster than the population '
              'produces it.',
        Commodity.sewage =>
          'This is WASTE — build Sewage Treatment plants to process it (they also '
              'recover clean water). A backlog pollutes + spreads disease.',
        _ => 'Build the matching factory; ensure power, compute + staffing are met.',
      };

  Widget _powerRow() {
    final ratio = _powerDraw <= 0 ? 1.0 : (_powerOut / _powerDraw).clamp(0.0, 1.0);
    final ok = ratio >= 1.0;
    return _meterRow('Power', '${_powerOut.toStringAsFixed(0)} / ${_powerDraw.toStringAsFixed(0)}',
        ratio, ok ? AppTheme.accent2 : AppTheme.danger,
        warn: ok ? null : 'Brownout — production throttled.',
        onExplain: () => _showExplain(
            'Power Grid',
            ok
                ? 'Generation (${_powerOut.toStringAsFixed(0)}) meets demand '
                    '(${_powerDraw.toStringAsFixed(0)}).'
                : 'Demand (${_powerDraw.toStringAsFixed(0)}) exceeds generation '
                    '(${_powerOut.toStringAsFixed(0)}). Every building throttles to the '
                    'grid ratio, cutting all production.',
            'Build more power: Solar (sun-dependent), Wind (air-dependent), Gas '
                '(burns fuel), Reactor or Fusion (unlock with population). On dark/'
                'airless worlds favour gas + nuclear.',
            ok ? AppTheme.accent2 : AppTheme.danger));
  }

  /// Average grown-zone utilisation + a count of buildings still under
  /// construction. Tappable for a breakdown of the small/med/large/max stages.
  Widget _utilisationRow() {
    var sum = 0.0, building = 0;
    final stages = <String, int>{};
    for (final k in _grown) {
      if (_zones[k] == null) continue;
      sum += _utilFactor(k);
      if (_underConstruction(k)) building++;
      stages.update(_utilStage(k), (v) => v + 1, ifAbsent: () => 1);
    }
    final avg = _grown.isEmpty ? 0.0 : sum / _grown.length;
    final label = building > 0 ? '$building building' : '${(avg * 100).round()}% avg';
    return _meterRow('Utilisation', label, avg, AppTheme.accent2,
        onExplain: () => _showExplain(
            'Building Utilisation',
            'Zoned buildings rise through a construction phase, then fill up in '
                'stages — Small → Medium → Large → Max — as demand sustains them, '
                'and shrink back when demand fades. A building only contributes '
                'its housing / jobs / services in proportion to how occupied it '
                'is.\n\nCurrent mix: '
                '${stages.entries.map((e) => '${e.value} ${e.key}').join(', ')}.',
            'Keep demand high (balance R/C/I), power on, and roads connected so '
                'buildings finish construction and climb to Max occupancy.',
            AppTheme.accent2));
  }

  Widget _computeRow() {
    if (_computeDemand <= 0 && _computeSupply <= 0) return const SizedBox.shrink();
    final ratio = _computeDemand <= 0 ? 1.0 : (_computeSupply / _computeDemand).clamp(0.0, 1.0);
    final ok = ratio >= 1.0;
    return _meterRow('Compute', '${_computeSupply.toStringAsFixed(0)} / ${_computeDemand.toStringAsFixed(0)}',
        ratio, ok ? AppTheme.accent : AppTheme.danger,
        warn: ok ? null : 'Compute shortfall — advanced buildings throttled.');
  }

  Widget _pollutionRow() {
    final level = (_pollution / 200).clamp(0.0, 1.0);
    final c = level > 0.6 ? AppTheme.danger : (level > 0.3 ? AppTheme.warn : AppTheme.accent2);
    return _meterRow('Pollution', _pollution.toStringAsFixed(0), level, c,
        warn: level > 0.5 ? 'Atmosphere degrading — happiness + health hit.' : null,
        onExplain: () => _showExplain(
            'Pollution',
            'Industry, power plants and dense zones emit pollution into the '
                'atmosphere. High pollution drags happiness and breeds disease.',
            'Add Parks and Forest biome (scrub the air), pass the Emissions Cap '
                'ordinance, build Terraforming Towers (negative pollution), or replace '
                'dirty industry/gas with clean power (solar/wind/fusion).',
            c));
  }

  Widget _radiationRow() {
    if (_radiation <= 0.02) return const SizedBox.shrink();
    return _meterRow('Radiation', '${(_radiation * 100).toStringAsFixed(0)}%',
        _radiation, _radiation > 0.4 ? AppTheme.danger : AppTheme.warn,
        warn: _radiation > 0.4 ? 'Radiation sickness killing citizens.' : null,
        onExplain: () => _showExplain(
            'Radiation',
            'Comes from thin-atmosphere worlds (less air = more space '
                'radiation), solar storms, and nuclear fallout. It causes '
                'radiation sickness (disease + deaths).',
            'It decays on its own. Thicken the atmosphere (terraforming) for '
                'less background radiation, and shelter the population in '
                'Bunkers / Fallout Shelters during events.',
            AppTheme.danger));
  }

  Widget _meterRow(String label, String value, double ratio, Color color,
          {String? warn, VoidCallback? onExplain}) =>
      GestureDetector(
        onTap: onExplain,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(label, style: AppTheme.body)),
              if (onExplain != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(Icons.info_outline,
                      size: 13, color: color.withValues(alpha: 0.7)),
                ),
              Text(value, style: AppTheme.mono.copyWith(color: color)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                  value: ratio.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: AppTheme.panelLight,
                  color: color),
            ),
            if (warn != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(warn, style: AppTheme.dim.copyWith(color: color)),
              ),
          ]),
        ),
      );

  Widget _happinessRow() {
    final h = _happiness;
    final col = h >= 0.66 ? AppTheme.accent2 : (h >= 0.33 ? AppTheme.warn : AppTheme.danger);
    final face = h >= 0.66
        ? Icons.sentiment_very_satisfied
        : (h >= 0.33 ? Icons.sentiment_neutral : Icons.sentiment_very_dissatisfied);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(face, size: 16, color: col),
          const SizedBox(width: 6),
          const Expanded(child: Text('Happiness', style: AppTheme.body)),
          Text('${(h * 100).toStringAsFixed(0)}%',
              style: AppTheme.mono.copyWith(color: col)),
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
              value: h, minHeight: 6,
              backgroundColor: AppTheme.panelLight, color: col),
        ),
      ]),
    );
  }

  Widget _connectivityPanel() {
    final built = _grown.length + _utils.length;
    final abandoned = _abandoned.length;
    final disconnected = [
      ..._grown.where((k) => !_isConnected(k)),
      ..._utils.keys.where((k) => !_isConnected(k)),
    ].length;
    final issue = abandoned > 0 || disconnected > 0;
    final msg = built == 0
        ? 'Lay roads from the hub, paint zones + place buildings beside them.'
        : abandoned > 0
            ? '$abandoned building(s) abandoned (grey) — restore road/power.'
            : disconnected > 0
                ? '$disconnected building(s) cut off from the road network.'
                : 'All $built buildings connected + occupied.';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.panelBox(border: issue ? AppTheme.warn : const Color(0xFF223247)),
      child: Row(children: [
        Icon(issue ? Icons.warning_amber : Icons.hub,
            color: issue ? AppTheme.warn : AppTheme.accent, size: 18),
        const SizedBox(width: 8),
        Expanded(
            child: Text(msg,
                style: AppTheme.dim.copyWith(color: issue ? AppTheme.warn : AppTheme.textDim))),
      ]),
    );
  }

  Widget _economyPicker() => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final e in _Economy.values)
            _pill(e.label, _economy == e, AppTheme.accent,
                () => setState(() => _economy = e)),
        ],
      );

  Widget _govtPicker() => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final g in _Govt.values)
            _pill(g.label, _govt == g, AppTheme.accent2, () => setState(() {
                  _govt = g;
                  if (g.lawsAutoVoted) _autoVote();
                })),
        ],
      );

  Widget _pill(String label, bool sel, Color color, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: sel ? color : AppTheme.panelLight,
              borderRadius: BorderRadius.circular(6)),
          child: Text(label,
              style: TextStyle(fontSize: 12, color: sel ? AppTheme.bg : AppTheme.text)),
        ),
      );

  Widget _taxControl() {
    final controllable = _economy.taxControllable;
    final tax = _effectiveTax();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(controllable ? 'Tax rate' : 'State levy (fixed)',
                  style: AppTheme.body)),
          Text('${(tax * 100).toStringAsFixed(0)}%',
              style: AppTheme.mono.copyWith(color: AppTheme.accent)),
        ]),
        SliderTheme(
          data: SliderThemeData(
              activeTrackColor: controllable ? AppTheme.accent : AppTheme.textDim,
              thumbColor: controllable ? AppTheme.accent : AppTheme.textDim,
              inactiveTrackColor: AppTheme.panelLight,
              trackHeight: 3),
          child: Slider(
              value: tax.clamp(0.0, 0.4),
              max: 0.4,
              onChanged: controllable ? (v) => setState(() => _taxRate = v) : null),
        ),
      ]),
    );
  }

  List<Widget> _lawRows() {
    final auto = _govt.lawsAutoVoted;
    return [
      Text(
          auto
              ? '${_govt.label}: laws are auto-voted to address the worst problems.'
              : 'Enact ordinances directly:',
          style: AppTheme.dim),
      const SizedBox(height: 4),
      for (final l in _Law.values)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            Icon(_laws.contains(l) ? Icons.check_box : Icons.check_box_outline_blank,
                size: 17,
                color: _laws.contains(l) ? AppTheme.accent2 : AppTheme.textDim),
            const SizedBox(width: 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.label, style: AppTheme.body),
                Text(l.effect, style: AppTheme.dim),
              ]),
            ),
            if (!auto)
              Switch(
                  value: _laws.contains(l),
                  activeThumbColor: AppTheme.accent2,
                  onChanged: (v) =>
                      setState(() => v ? _laws.add(l) : _laws.remove(l))),
          ]),
        ),
    ];
  }

  Widget _revoltBanner() => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: AppTheme.danger.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.danger)),
        child: Row(children: [
          const Icon(Icons.local_fire_department, color: AppTheme.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(_revoltMsg!,
                  style: AppTheme.dim.copyWith(color: AppTheme.danger))),
          GestureDetector(
            onTap: () => setState(() => _revoltMsg = null),
            child: const Icon(Icons.close, color: AppTheme.danger, size: 16),
          ),
        ]),
      );

  Widget _socialBar(String label, double value, Color color) {
    final alarm = value > 0.5;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 84, child: Text(label, style: AppTheme.body)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
                value: value, minHeight: 8,
                backgroundColor: AppTheme.panelLight,
                color: alarm ? AppTheme.danger : color),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 34,
          child: Text('${(value * 100).toStringAsFixed(0)}%',
              textAlign: TextAlign.right,
              style: AppTheme.mono.copyWith(
                  fontSize: 11, color: alarm ? AppTheme.danger : color)),
        ),
      ]),
    );
  }

  Widget _rciBar(String label, double value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(width: 84, child: Text(label, style: AppTheme.body)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                  value: value, minHeight: 9,
                  backgroundColor: AppTheme.panelLight, color: color),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 36,
            child: Text('${(value * 100).toStringAsFixed(0)}%',
                textAlign: TextAlign.right,
                style: AppTheme.mono.copyWith(color: color)),
          ),
        ]),
      );

  Widget _statRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, style: AppTheme.body)),
          Text(v, style: AppTheme.mono),
        ]),
      );

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// Display name for a biome (shared by the builder + the new-city setup screen).
String cityBiomeName(Biome b) => switch (b) {
      Biome.ocean => 'Ocean',
      Biome.iceCap => 'Ice Cap',
      Biome.tundra => 'Tundra',
      Biome.desert => 'Desert',
      Biome.grassland => 'Grassland',
      Biome.forest => 'Forest',
      Biome.mountains => 'Mountains',
      Biome.volcanic => 'Volcanic',
      Biome.barren => 'Barren',
      Biome.wetland => 'Wetland',
      Biome.coastal => 'Coastal',
      Biome.volcano => 'Volcano (lava)',
    };

/// New-colony setup screen: pick the world, terrain, politics, economy, map size
/// and difficulty before founding a city. "Found Colony" launches the builder
/// with the chosen [CityConfig].
class NewCityScreen extends StatefulWidget {
  const NewCityScreen({super.key});

  @override
  State<NewCityScreen> createState() => _NewCityScreenState();
}

class _NewCityScreenState extends State<NewCityScreen> {
  late final List<CelestialBody> _bodies;
  late CelestialBody _body;
  Biome _biome = Biome.grassland;
  _Govt _govt = _Govt.democracy;
  _Economy _economy = _Economy.capitalism;
  double _grid = 20;
  double _complexity = 0.6, _hostility = 0.4, _forgiveness = 1.0, _bounty = 1.0;
  _ColonyStyle _mode = _ColonyStyle.open;
  double _altitude = 50; // km, floating cloud-deck altitude (flavor)

  @override
  void initState() {
    super.initState();
    _bodies = RealSolarSystem.build().all.where((b) => !b.isStar).toList()
      ..sort((a, b) => a.solarFlux.compareTo(b.solarFlux));
    _body = _bodies.firstWhere((b) => b.id.value == 'earth',
        orElse: () => _bodies.first);
  }

  /// Allowed colony modes for the chosen body: gas giants have no surface, so
  /// only floating (cloud city) + orbital are offered there.
  List<_ColonyStyle> get _allowedModes => _body.isGasGiant
      ? [_ColonyStyle.domed, _ColonyStyle.orbital]
      : _ColonyStyle.values;

  String _modeLabel(_ColonyStyle m) => switch (m) {
        _ColonyStyle.open => 'Surface',
        _ColonyStyle.domed => 'Floating (cloud city)',
        _ColonyStyle.orbital => 'Orbital station',
      };

  void _found() {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => CityBuilderScreen(
        config: CityConfig(
          gridSize: _grid.round(),
          bodyId: _body.id.value,
          biome: _biome,
          govtIndex: _govt.index,
          economyIndex: _economy.index,
          colonyModeIndex: _mode.index,
          complexity: _complexity,
          hostility: _hostility,
          forgiveness: _forgiveness,
          bounty: _bounty,
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: 'NEW COLONY',
      accentColor: AppTheme.accent2,
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 24 + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          const Text('WORLD', style: AppTheme.heading),
          const SizedBox(height: 8),
          _dropdownRow<CelestialBody>(
              Icons.public, 'Planet', _body, _bodies, (b) => b.name, (b) {
            setState(() {
              _body = b;
              // Gas giants have no surface — clamp to a valid mode.
              if (!_allowedModes.contains(_mode)) _mode = _allowedModes.first;
            });
          }),
          const SizedBox(height: 6),
          _dropdownRow<Biome>(Icons.terrain, 'Biome', _biome, Biome.values,
              cityBiomeName, (b) => setState(() => _biome = b)),
          const SizedBox(height: 6),
          _dropdownRow<_ColonyStyle>(Icons.apartment, 'Colony', _mode,
              _allowedModes, _modeLabel, (m) => setState(() => _mode = m)),
          if (_body.isGasGiant)
            Text('Gas giant — no solid surface; floating or orbital only.',
                style: AppTheme.dim.copyWith(color: AppTheme.warn, fontSize: 11)),
          if (_mode == _ColonyStyle.domed) ...[
            Row(children: [
              const SizedBox(width: 96, child: Text('Altitude', style: AppTheme.body)),
              Expanded(
                child: Slider(
                  value: _altitude,
                  min: 0,
                  max: 100,
                  onChanged: (v) => setState(() => _altitude = v),
                ),
              ),
              Text('${_altitude.toStringAsFixed(0)} km',
                  style: AppTheme.mono.copyWith(color: AppTheme.accent2)),
            ]),
            Text('Higher = thinner, colder air but less crushing pressure. Pick '
                'the habitable cloud deck (Venus ~50 km ≈ 1 atm, ~25 °C).',
                style: AppTheme.dim.copyWith(fontSize: 11)),
          ],
          const SizedBox(height: 6),
          Wrap(spacing: 14, children: [
            Text('Solar ×${(_body.solarFlux / 1361).clamp(0.05, 4.0).toStringAsFixed(2)}',
                style: AppTheme.mono.copyWith(color: AppTheme.warn)),
            Text('Gravity ${(_body.mu / (_body.radius * _body.radius)).toStringAsFixed(1)} m/s²',
                style: AppTheme.mono.copyWith(color: AppTheme.textDim)),
          ]),
          const SizedBox(height: 16),
          const Text('POLITICS & ECONOMY', style: AppTheme.heading),
          const SizedBox(height: 8),
          _dropdownRow<_Govt>(Icons.account_balance, 'Government', _govt,
              _Govt.values, (g) => g.label, (g) => setState(() => _govt = g)),
          const SizedBox(height: 6),
          _dropdownRow<_Economy>(Icons.payments, 'Economy', _economy,
              _Economy.values, (e) => e.label, (e) => setState(() => _economy = e)),
          const SizedBox(height: 16),
          const Text('MAP SIZE', style: AppTheme.heading),
          const SizedBox(height: 8),
          Row(children: [
            const Expanded(child: Text('Grid', style: AppTheme.body)),
            Text('${_grid.round()} × ${_grid.round()}  (${_grid.round() * _grid.round()} tiles)',
                style: AppTheme.mono.copyWith(color: AppTheme.accent2)),
          ]),
          Slider(
              value: _grid,
              min: 12,
              max: 48,
              divisions: 18,
              onChanged: (v) => setState(() => _grid = v)),
          const SizedBox(height: 8),
          const Text('DIFFICULTY', style: AppTheme.heading),
          const SizedBox(height: 8),
          _slider('Complexity', _complexity, 'How many systems to manage',
              (v) => setState(() => _complexity = v)),
          _slider('Hostility', _hostility, 'Disaster frequency + severity',
              (v) => setState(() => _hostility = v)),
          _slider('Forgiveness', _forgiveness, 'Slack before citizens die / leave',
              (v) => setState(() => _forgiveness = v)),
          _slider('Bounty', _bounty, 'Resource abundance (production rate)',
              (v) => setState(() => _bounty = v)),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accent2,
                foregroundColor: AppTheme.bg,
                padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: _found,
            icon: const Icon(Icons.rocket_launch),
            label: const Text('FOUND COLONY'),
          ),
        ],
      ),
    );
  }

  Widget _dropdownRow<T>(IconData icon, String label, T value, List<T> options,
      String Function(T) name, ValueChanged<T> onChanged) {
    return Row(children: [
      Icon(icon, size: 16, color: AppTheme.accent),
      const SizedBox(width: 8),
      SizedBox(width: 96, child: Text(label, style: AppTheme.body)),
      Expanded(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: AppTheme.panelLight,
          underline: const SizedBox.shrink(),
          isDense: true,
          items: [
            for (final o in options)
              DropdownMenuItem(value: o, child: Text(name(o), style: AppTheme.body)),
          ],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      ),
    ]);
  }

  Widget _slider(String label, double value, String hint, ValueChanged<double> onCh) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(label, style: AppTheme.body)),
            Text(value < 0.34 ? 'Low' : (value < 0.67 ? 'Medium' : 'High'),
                style: AppTheme.mono.copyWith(color: AppTheme.accent)),
          ]),
          Slider(value: value, onChanged: onCh),
          Text(hint, style: AppTheme.dim.copyWith(fontSize: 11)),
        ]),
      );
}

