// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../domain/colony/city/city_config.dart';
import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/planetary/planet_surface.dart';
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
///
/// The simulation itself is NOT here — it lives in [CitySim] under the domain,
/// so a colony keeps running while you are flying somewhere else. This screen
/// owns only what a view owns: the held tool, the paint mode, the camera, the
/// panels, and the icon/colour tables.
class CityBuilderScreen extends StatefulWidget {
  /// Founding parameters, used only when [sim] is null.
  final CityConfig? config;

  /// An EXISTING colony to view. Pass this when the world already owns the
  /// colony (it is registered with the authoritative sim) so opening the
  /// builder shows the live city rather than founding a second one.
  final CitySim? sim;

  /// Whether this screen advances the colony itself. True stand-alone; false
  /// when the authoritative tick is already driving it, so it is not stepped
  /// twice per frame.
  final bool driveLocally;

  const CityBuilderScreen({
    super.key,
    this.config,
    this.sim,
    this.driveLocally = true,
  });

  @override
  State<CityBuilderScreen> createState() => _CityBuilderScreenState();
}

enum _Tool { inspect, zone, road, utility, bulldoze, retrofit, support }

/// How the zone/road tools apply: one tile per tap, continuous drag-paint, or
/// drag a rectangle and fill it on release.
enum _PaintMode { single, paint, rect }

// The sim's vocabulary, re-exported under the names the view has always used.
// These are type aliases onto the domain types, so `_Disaster.tornado` and
// `_LandedCraft(...)` keep working unchanged against the moved definitions.
typedef _Disaster = Disaster;
typedef _Govt = Govt;
typedef _Law = Law;
typedef _Economy = Economy;
typedef _ColonyStyle = ColonyStyle;
typedef _LandedCraft = LandedCraft;
typedef _DeliverySchedule = DeliverySchedule;

/// Icon per disaster. Lives here, not on the enum, because the enum is domain
/// data now and [IconData] is a widget type.
const Map<Disaster, IconData> kDisasterIcons = {
  Disaster.none: Icons.wb_sunny,
  Disaster.rain: Icons.water_drop,
  Disaster.thunderstorm: Icons.thunderstorm,
  Disaster.snow: Icons.ac_unit,
  Disaster.dustStorm: Icons.air,
  Disaster.tornado: Icons.cyclone,
  Disaster.fire: Icons.local_fire_department,
  Disaster.meteorShower: Icons.stream,
  Disaster.plague: Icons.coronavirus,
  Disaster.famine: Icons.no_meals,
  Disaster.solarStorm: Icons.flare,
  Disaster.nuke: Icons.dangerous,
  Disaster.hurricane: Icons.cyclone,
  Disaster.blizzard: Icons.severe_cold,
  Disaster.fog: Icons.foggy,
  Disaster.acidRain: Icons.invert_colors,
  Disaster.earthquake: Icons.vibration,
  Disaster.radiationStorm: Icons.bubble_chart,
  Disaster.glassRain: Icons.grain,
  Disaster.ammoniaStorm: Icons.ac_unit,
  Disaster.cryovolcanism: Icons.ac_unit,
  Disaster.miasma: Icons.cloud,
  Disaster.lavaFlow: Icons.local_fire_department,
  Disaster.sandworm: Icons.waves,
  Disaster.grayGoo: Icons.blur_on,
  Disaster.crawlingForest: Icons.forest,
  Disaster.rollingGlitch: Icons.broken_image,
  Disaster.auroraBloom: Icons.auto_awesome,
  Disaster.eclipse: Icons.dark_mode,
  Disaster.gammaRayBurst: Icons.flare,
  Disaster.fallingStar: Icons.star,
  Disaster.skyCrack: Icons.bolt,
  Disaster.timeDilation: Icons.hourglass_bottom,
  Disaster.sporeBloom: Icons.grass,
  Disaster.crystalGrowth: Icons.diamond,
  Disaster.biolumTide: Icons.water,
  Disaster.chemicalRain: Icons.science,
  Disaster.diamondRain: Icons.diamond,
  Disaster.ironSnow: Icons.ac_unit,
  Disaster.methaneDownpour: Icons.local_gas_station,
  Disaster.bloodRain: Icons.water_drop,
  Disaster.blackRain: Icons.grain,
  Disaster.commsBlackout: Icons.signal_cellular_off,
  Disaster.goldRush: Icons.paid,
  Disaster.refugeeInflux: Icons.groups,
  Disaster.festival: Icons.celebration,
  Disaster.cultUprising: Icons.report,
  Disaster.aiAwakening: Icons.smart_toy,
  Disaster.marketCrash: Icons.trending_down,
  Disaster.alienBeacon: Icons.cell_tower,
  Disaster.rainingFrogs: Icons.pets,
  Disaster.glitchInMatrix: Icons.replay,
};

extension _DisasterIcon on Disaster {
  IconData get icon => kDisasterIcons[this] ?? Icons.warning_amber;
}

class _CityBuilderScreenState extends State<CityBuilderScreen>
    with TickerProviderStateMixin {
  /// The colony being viewed. All simulation state lives here.
  late final CitySim _sim;

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


  // Sim.
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  bool _underground = false; // view/build the subsurface layer
  String _buildSearch = ''; // BUILD-tab palette filter (lowercased)
  // Map camera lives here (not in CityMapView) so orbit/zoom/pan survive the
  // drawer toggle rebuilding the map widget.
  final CityCamController _mapCam = CityCamController();
  bool _paneOpen = true; // side panel open (false = full-screen render)


  /// Ground tint for the host planet's surface, tinted by the chosen biome.
  Color get _groundTint {
    final base = _bodyGroundTint;
    final biomeCol = switch (_sim.biome) {
      Biome.ocean => Color(_sim.liquid.colorArgb), // tint by what the sea IS made of
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
      Biome.volcano => Color(_sim.liquid.colorArgb), // lava-lake colour
    };
    // Blend the planet's base tone with the biome colour.
    return Color.lerp(base, biomeCol, 0.6) ?? base;
  }

  Color get _bodyGroundTint => switch (_sim.body.id.value) {
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


  @override
  void initState() {
    super.initState();
    // Found (or adopt) the colony. The screen no longer seeds any of it — that
    // is world state, so CitySim owns the whole founding sequence.
    _sim = widget.sim ??
        CitySim.found(
          widget.config,
          bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList()
            ..sort((a, b) => a.solarFlux.compareTo(b.solarFlux)),
        );
    _tabs = TabController(length: 5, vsync: this);
    _ticker = createTicker(_onFrame)..start();
  }

  /// Drive the colony from the screen's own ticker.
  ///
  /// This is the LOCAL driver, used when the city builder is opened stand-alone.
  /// When a colony is registered with the authoritative simulation, that tick
  /// advances it instead and this screen only repaints — see [CityBuilderScreen.driveLocally].
  void _onFrame(Duration elapsed) {
    final wallDt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (_driveLocally) _sim.advance(wallDt * _sim.timeWarp);
    setState(() {});
  }

  bool get _driveLocally => widget.driveLocally;

  /// Tools that support the single / paint / rect placement styles (Utility is
  /// tap-only since it costs ore + is single-placement).
  bool get _toolPaintable =>
      _tool == _Tool.zone ||
      _tool == _Tool.road ||
      _tool == _Tool.bulldoze ||
      _tool == _Tool.retrofit ||
      _tool == _Tool.support;

  late final TabController _tabs;

  @override
  void dispose() {
    _ticker.dispose();
    _tabs.dispose();
    _drawerScroll.dispose();
    super.dispose();
  }

  /// Connected launch sites for the VAB: spaceports (rockets) + airfields
  /// (spaceplanes). Only road-connected ones can dispatch a launch.
  List<LaunchSite> get _launchSites => [
        for (final e in _sim.utils.entries)
          if (_sim.isConnected(e.key) &&
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
        bodyId: _sim.body.id.value,
        launchSites: _launchSites,
        latitude: _sim.cityLat,
        longitude: _sim.cityLon,
      ),
    ));
  }

  /// Pilot a manual descent over the colony onto [anchor]'s pads. A clean pad
  /// landing parks a delivery craft there; coming down on the city flattens a
  /// random building (the craft is lost too).
  void _pilotLanding(int anchor) {
    final pads = (_sim.specAt(anchor)?.cellCount ?? 1);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AscentScreen(
        bodyId: _sim.body.id.value,
        descent: true,
        pads: pads,
        onLand: (padIndex) {
          // Touched down on a pad -> drop a small supply payload there.
          if (padIndex == null) return;
          setState(() {
            final pad = _sim.freePad(anchor);
            if (pad != null) {
              _sim.craft.add(_LandedCraft(
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
          setState(_sim.flattenOne);
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
      _sim.body,
      latDeg: _sim.cityLat,
      lonDeg: _sim.cityLon,
      name: '${_sim.body.name} Ascent',
    );
    // Bridge the colony's live cargo traffic into the sim as named craft on
    // their own orbits, so they appear with real trajectories — one shuttle per
    // active scheduled delivery, plus a couple of other-player shuttles.
    final traffic = <Vessel>[];
    var i = 0;
    for (final c in _sim.craft.where((c) => !c.isRelief && c.resource != null)) {
      traffic.add(SampleWorld.buildTrafficVessel(
        _sim.body,
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
      _sim.body,
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

  // ---- Simulation tick ----


  void _onTapCell(int x, int y) {
    final k = _sim.key(x, y);
    // The hub IS the lander/landing site — tapping it always opens its menu,
    // whatever tool is held (it can't be zoned/bulldozed away).
    if (k == _sim.hubKey) {
      _showLanderMenu();
      return;
    }
    // Inspect tool: tap a building (or any covered tile) for its context menu.
    if (_tool == _Tool.inspect) {
      final anchor = _sim.anchorOf(k);
      if (anchor != null && _sim.utils.containsKey(anchor)) {
        _showBuildingMenu(anchor, _sim.utils[anchor]!);
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
      _sim.blocked = null;
      switch (_tool) {
        case _Tool.inspect:
          break; // handled above
        case _Tool.retrofit:
          _sim.retrofitCell(k);
        case _Tool.support:
          if (_sim.support.contains(k)) {
            _sim.support.remove(k);
          } else {
            _sim.clearCell(k);
            _sim.support.add(k);
          }
        case _Tool.bulldoze:
          _sim.clearCell(k);
        case _Tool.road:
          if (_sim.roads.contains(k)) {
            _sim.removeRoad(k);
          } else {
            _sim.clearCell(k, keepSupport: true); // road runs ON the platform
            _sim.addRoad(k);
          }
        case _Tool.utility:
          final anchor = _sim.anchorOf(k);
          if (anchor != null && _sim.utils[anchor]?.type == _selectedUtil.type) {
            // Tapping any tile of an existing same-type building removes it.
            _sim.clearCell(anchor);
          } else if (_selectedUtil.type == 'o2harvester' && !_sim.o2Harvestable) {
            _sim.blocked =
                '${_sim.body.name} has no harvestable oxygen — use Electrolysis instead.';
          } else if (_selectedUtil.type == 'mine' &&
              _sim.colonyMode != _ColonyStyle.open) {
            // No ground to dig on a cloud city / orbital station.
            _sim.blocked = _sim.colonyMode == _ColonyStyle.orbital
                ? 'No surface to mine in orbit.'
                : 'No ground to mine on a cloud city.';
          } else if (!_sim.unlocked(_selectedUtil)) {
            _sim.blocked =
                '${_selectedUtil.label} unlocks at population ${_selectedUtil.unlockPop}.';
          } else if (!_sim.footprintFree(x, y, _selectedUtil)) {
            _sim.blocked = _selectedUtil.cellCount > 1
                ? 'No room — ${_selectedUtil.label} needs a clear ${_selectedUtil.footW}×${_selectedUtil.footH} area here.'
                : 'Cell occupied.';
          } else if (!_sim.footprintSupported(
              x, y, _selectedUtil.footW, _selectedUtil.footH)) {
            _sim.blocked = 'Needs ${_sim.supportLabel} support here — build the structure first.';
          } else if (_sim.stockOf(Commodity.ore) < _selectedUtil.buildCost) {
            _sim.blocked =
                'Need ${_selectedUtil.buildCost.toStringAsFixed(0)} ore for ${_selectedUtil.label}.';
          } else {
            _sim.stock[Commodity.ore] =
                _sim.stockOf(Commodity.ore) - _selectedUtil.buildCost;
            _sim.placeUtil(k, _selectedUtil);
          }
        case _Tool.zone:
          final z = ZoneType(_zoneKind, _density);
          final cur = _sim.zones[k];
          if (cur != null && cur.kind == z.kind && cur.density == z.density) {
            _sim.clearCell(k);
          } else if (!_sim.footprintSupported(x, y, 1, 1)) {
            _sim.blocked = 'Needs ${_sim.supportLabel} support here — build the structure first.';
          } else {
            _sim.clearCell(k, keepSupport: true); // build ON the platform, keep it
            _sim.zones[k] = z;
            if (_autoRoads) _sim.autoRoadAround(k);
          }
      }
      _sim.recompute();
    });
  }

  /// Cells to highlight under the cursor for the active placement tool. Empty
  /// for inspect/no-hover. For the Utility tool it's the selected building's
  /// footprint anchored at the hover cell; for zone/road/support/bulldoze it's
  /// the single hovered cell.
  Set<int> _hoverHighlight() {
    final h = _hoverCell;
    if (h == null) return const {};
    final hx = h % _sim.grid, hy = h ~/ _sim.grid;
    if (_tool == _Tool.utility) {
      final spec = _selectedUtil;
      final out = <int>{};
      for (var dy = 0; dy < spec.footH; dy++) {
        for (var dx = 0; dx < spec.footW; dx++) {
          final x = hx + dx, y = hy + dy;
          if (x < _sim.grid && y < _sim.grid) out.add(_sim.key(x, y));
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
    final k = _sim.key(x, y);
    if (k == _sim.hubKey) return;
    setState(() {
      _sim.blocked = null;
      switch (_tool) {
        case _Tool.bulldoze:
          _sim.clearCell(k);
        case _Tool.road:
          if (!_sim.roads.contains(k)) {
            _sim.clearCell(k, keepSupport: true); // road runs ON the platform
            _sim.addRoad(k);
          }
        case _Tool.zone:
          final z = ZoneType(_zoneKind, _density);
          final cur = _sim.zones[k];
          if (cur == null || cur.kind != z.kind || cur.density != z.density) {
            _sim.clearCell(k, keepSupport: true); // build ON the platform, keep it
            _sim.zones[k] = z;
            if (_autoRoads) _sim.autoRoadAround(k);
          }
        case _Tool.retrofit:
          _sim.retrofitCell(k);
        case _Tool.support:
          if (!_sim.support.contains(k)) {
            _sim.clearCell(k);
            _sim.support.add(k);
          }
        case _Tool.utility:
        case _Tool.inspect:
          break; // tap-only
      }
      _sim.recompute();
    });
  }


  /// Fill the rectangle spanning two corner cells with the active Zone or Road
  /// tool (used by the Rect paint style). Bounded to keep the loop cheap.
  void _fillRect(int a, int b) {
    final ax = a % _sim.grid, ay = a ~/ _sim.grid;
    final bx = b % _sim.grid, by = b ~/ _sim.grid;
    final x0 = math.min(ax, bx), x1 = math.max(ax, bx);
    final y0 = math.min(ay, by), y1 = math.max(ay, by);
    _sim.blocked = null;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final k = _sim.key(x, y);
        if (k == _sim.hubKey) continue;
        if (_tool == _Tool.retrofit) {
          _sim.retrofitCell(k);
        } else if (_tool == _Tool.support) {
          if (!_sim.support.contains(k)) {
            _sim.clearCell(k);
            _sim.support.add(k);
          }
        } else if (_tool == _Tool.bulldoze) {
          _sim.clearCell(k);
        } else if (_tool == _Tool.road) {
          if (!_sim.roads.contains(k)) {
            _sim.clearCell(k, keepSupport: true); // road runs ON the platform
            _sim.addRoad(k);
          }
        } else {
          final z = ZoneType(_zoneKind, _density);
          _sim.clearCell(k, keepSupport: true); // build ON the platform, keep it
          _sim.zones[k] = z;
          if (_autoRoads) _sim.autoRoadAround(k);
        }
      }
    }
    _sim.recompute();
  }


  Color _cellColor(int key) {
    final z = _sim.zones[key];
    if (z != null) return _sim.grownSpec(z).color;
    final u = _sim.utils[key];
    if (u != null) return u.color;
    return const Color(0xFF6FB4FF);
  }


  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: 'CITY BUILDER',
      accentColor: AppTheme.accent2,
      actions: [
        if (_sim.zones.isNotEmpty || _sim.utils.isNotEmpty || _sim.roads.length > 1)
          IconButton(
            icon: const Icon(Icons.delete_sweep, color: AppTheme.danger),
            tooltip: 'Clear',
            onPressed: () => setState(() {
              _sim.zones.clear();
              _sim.utils.clear();
              _sim.footprint.clear();
              _sim.rubble.clear();
              _sim.crystal.clear();
              _sim.scatter.clear();
              _sim.buildStyle.clear();
              _sim.support.clear();
              _sim.landerPad = null;
              _sim.grown.clear();
              _sim.growProgress.clear();
              _sim.abandoned.clear();
              _sim.roads
                ..clear()
                ..add(_sim.hubKey);
              _sim.recompute();
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
                grid: _sim.grid,
                cell: CitySim.cellM,
                cells: _sim.mapCells,
                groundTint: _underground
                    ? Color.lerp(_groundTint, const Color(0xFF120E0A), 0.7)!
                    : _groundTint,
                zoneTint: {for (final e in _sim.zones.entries) e.key: _sim.grownSpec(e.value).color},
                roads: _sim.roads,
                rubble: _sim.rubble,
                fires: _sim.fires,
                scatter: _sim.scatter,
                support: _sim.support,
                colonyMode: _sim.colonyMode.index,
                liquidColor: _sim.liquid.colorArgb,
                liquidMolten: _sim.liquid.isMolten,
                elevation: _sim.elevation,
                liquidTiles: {
                  for (var k = 0; k < _sim.grid * _sim.grid; k++)
                    if (_sim.isLiquidTile(k)) k
                },
                roadSealed: _sim.roadSealed,
                hubs: {_sim.hubKey},
                connected: _sim.isConnected,
                occupied: (k) => !_sim.abandoned.contains(k),
                colorOf: (b) {
                  final key = int.tryParse(b.id) ?? -1;
                  if (_sim.abandoned.contains(key)) return const Color(0xFF555B63);
                  return _cellColor(key);
                },
                heightOf: (b) {
                  final key = int.tryParse(b.id) ?? -1;
                  return _sim.specAt(key)?.height() ?? 10;
                },
                kindOf: (b) {
                  final key = int.tryParse(b.id) ?? -1;
                  return _sim.specAt(key)?.type ?? '';
                },
                footOf: (key) {
                  final s = _sim.specAt(key);
                  return (s?.footW ?? 1, s?.footH ?? 1);
                },
                styleOf: _sim.styleOf,
                growthOf: (key) =>
                    _sim.grown.contains(key) ? (_sim.growProgress[key] ?? 1.0) : 1.0,
                // Traffic intensity = how much of the population is employed +
                // active; transit stops light up the network.
                commuters: _sim.population > 0
                    ? (math.min(_sim.population.floor(), _sim.jobs) / _sim.population)
                        .clamp(0.0, 1.0)
                    : 0.0,
                trafficAt: _sim.trafficAt,
                transitStops: {
                  for (final e in _sim.utils.entries)
                    if (e.value.type == 'transit' && _sim.isConnected(e.key)) e.key
                },
                corpseDensity: _sim.population > 0
                    ? (_sim.corpses / _sim.population).clamp(0.0, 1.0)
                    : (_sim.corpses > 1 ? 0.5 : 0.0),
                // Garbage/sewage litter density from each backlog (relative to a
                // tolerable level scaled by population).
                garbageDensity: _sim.population > 0
                    ? (_sim.stockOf(Commodity.garbage) / (_sim.population * 1.5))
                        .clamp(0.0, 1.0)
                    : 0.0,
                sewageDensity: _sim.population > 0
                    ? (_sim.stockOf(Commodity.sewage) / (_sim.population * 1.5))
                        .clamp(0.0, 1.0)
                    : 0.0,
                wasteTiles: _sim.wasteSites.toSet(),
                // A building flags understaffed when the city can't fill jobs
                // (global staffing < 95%) and this building actually needs them.
                understaffed: (k) =>
                    _sim.staffing < 0.95 && (_sim.specAt(k)?.jobs ?? 0) > 0,
                disaster: _sim.disaster.index,
                weatherFade: _sim.weatherFade,
                nuclearWinter: _sim.nuclearWinter,
                radiation: _sim.radiation,
                daylight: _sim.daylight,
                flag: _sim.flagPlanted,
                stormX: _sim.isMovingFront ? _sim.stormX : -1,
                stormY: _sim.isMovingFront ? _sim.stormY : -1,
                landerPad: _sim.landerPad,
                landedCraft: [
                  for (final c in _sim.craft)
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
                beaconCell: _sim.beaconCell,
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
                    if (_sim.disaster != _Disaster.none) ...[
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
    if (_sim.starved) {
      out.add((
        icon: Icons.no_food,
        msg: 'STARVING — pop leaving',
        color: AppTheme.danger,
        tap: () => _explainAlert('starving'),
      ));
    }
    if (!_sim.hasSpaceport) {
      out.add((
        icon: Icons.block,
        msg: switch (_sim.noSpaceportReason) {
          1 => 'Spaceport cut off — reconnect it',
          2 => 'Spaceport demolished — rebuild',
          _ => 'No spaceport — build one',
        },
        color: AppTheme.warn,
        tap: () => _explainAlert('spaceport'),
      ));
    }
    if (_sim.fires.isNotEmpty) {
      out.add((
        icon: Icons.local_fire_department,
        msg: '${_sim.fires.length} building${_sim.fires.length == 1 ? "" : "s"} on fire',
        color: AppTheme.danger,
        tap: () => _explainAlert('fire'),
      ));
    }
    if (_sim.pollution > 120) {
      out.add((
        icon: Icons.cloud,
        msg: 'Air pollution critical',
        color: AppTheme.danger,
        tap: () => _explainAlert('pollution'),
      ));
    } else if (_sim.pollution > 70) {
      out.add((
        icon: Icons.cloud,
        msg: 'Air pollution rising',
        color: AppTheme.warn,
        tap: () => _explainAlert('pollution'),
      ));
    }
    if (_sim.disease > 0.4) {
      out.add((
        icon: Icons.coronavirus,
        msg: 'Disease outbreak',
        color: AppTheme.danger,
        tap: () => _explainAlert('disease'),
      ));
    }
    if (_sim.powerDraw > 0 && _sim.powerOut < _sim.powerDraw * 0.9) {
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
          'Pop ${_sim.population.round()} · ${_sim.popTrend}',
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
    final d = _sim.disaster;
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
    final secs = _sim.disasterTime.ceil();
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
            if (_sim.colonyNeedsSupport || _sim.isOceanColony) ...[
              const SizedBox(width: 5),
              _toolChip(_sim.supportLabel, Icons.grid_4x4, _Tool.support,
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
                _sim.terrainRelief = !_sim.terrainRelief;
                _sim.genElevation(); // re-sculpt (or flatten) the height field
                _sim.recompute();
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: _sim.terrainRelief
                      ? AppTheme.accent.withValues(alpha: 0.25)
                      : AppTheme.panelLight,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: _sim.terrainRelief
                          ? AppTheme.accent
                          : AppTheme.panelLight),
                ),
                child: Row(children: [
                  Icon(Icons.landscape,
                      size: 13,
                      color: _sim.terrainRelief ? AppTheme.accent : AppTheme.textDim),
                  const SizedBox(width: 4),
                  Text('Relief',
                      style: TextStyle(
                          fontSize: 12,
                          color: _sim.terrainRelief
                              ? AppTheme.accent
                              : AppTheme.textDim)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            // Replant: fill open tiles with biome flora right now (regrowth also
            // does this slowly on its own).
            GestureDetector(
              onTap: () => setState(_sim.seedScatter),
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
              onTap: _sim.grid >= CitySim.maxGrid ? null : _sim.expandLand,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: _sim.grid >= CitySim.maxGrid
                      ? AppTheme.panelLight
                      : AppTheme.accent2.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: _sim.grid >= CitySim.maxGrid
                          ? AppTheme.textDim
                          : AppTheme.accent2),
                ),
                child: Row(children: [
                  const Icon(Icons.open_in_full, size: 13, color: AppTheme.accent2),
                  const SizedBox(width: 4),
                  Text(_sim.grid >= CitySim.maxGrid ? 'Max land' : 'Buy land §${CitySim.landCost.toStringAsFixed(0)}',
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
          Text('${_sim.timeWarp.toStringAsFixed(0)}×',
              style: AppTheme.mono.copyWith(color: AppTheme.accent)),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                  activeTrackColor: AppTheme.accent,
                  thumbColor: AppTheme.accent,
                  inactiveTrackColor: AppTheme.panelLight,
                  trackHeight: 3),
              child: Slider(
                  value: _sim.timeWarp,
                  min: 1,
                  max: 20,
                  onChanged: (v) => setState(() => _sim.timeWarp = v)),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        const Text('DIFFICULTY', style: AppTheme.heading),
        const SizedBox(height: 6),
        _diffSlider('Complexity', _sim.complexity,
            'How many systems to manage (waste, oxygen, …)',
            (v) => setState(() => _sim.complexity = v)),
        _diffSlider('Hostility', _sim.hostility,
            'Frequency + severity of random disasters',
            (v) => setState(() => _sim.hostility = v)),
        _diffSlider('Forgiveness', _sim.forgiveness,
            'How much slack before citizens die / leave',
            (v) => setState(() => _sim.forgiveness = v)),
        _diffSlider('Bounty', _sim.bounty,
            'Resource production rate (higher = more abundant)',
            (v) => setState(() => _sim.bounty = v)),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _sim.infiniteRes,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Infinite resources (debug)', style: AppTheme.body),
          subtitle: Text('Stockpiles never deplete — shows ∞, keeps live rates.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => _sim.infiniteRes = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _sim.infiniteDemand,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Infinite demand (debug)', style: AppTheme.body),
          subtitle: Text('RCI demand pinned to max — zones keep growing.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => _sim.infiniteDemand = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _sim.infiniteRobotics,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Infinite Robotics', style: AppTheme.body),
          subtitle: Text('Automated labour — buildings need no workers (full staffing).',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => _sim.infiniteRobotics = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _sim.ignoreUnlocks,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Ignore unlocks (debug)', style: AppTheme.body),
          subtitle: Text('Build anything regardless of the population requirement.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => _sim.ignoreUnlocks = v),
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
        if (_sim.nuclearWinter > 0.02)
          _meterRow('Nuclear Winter',
              '${(_sim.nuclearWinter * 100).toStringAsFixed(0)}%', _sim.nuclearWinter,
              AppTheme.danger,
              warn: 'Sun blotted out — solar + crops failing.',
              onExplain: () => _showExplain(
                  'Nuclear Winter',
                  'Soot from a nuclear strike blots out the sun, crippling solar '
                      'power and freezing crops.',
                  'It clears over time. Build Terraforming Towers to clear it faster, '
                      'and lean on gas/nuclear power + stored food until it lifts.',
                  AppTheme.danger)),
        if (_sim.terraform > 0.01 || _sim.terraformers > 0)
          _meterRow('Terraforming', '${(_sim.terraform * 100).toStringAsFixed(0)}%',
              _sim.terraform, AppTheme.accent2),
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
      if (_sim.blocked != null) ...[_blockedBanner(), const SizedBox(height: 10)],
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
        _statRow('Population', '${_sim.population.round()}'),
        _statRow('Housing', '${_sim.housing}'),
        _statRow('Jobs', '${_sim.jobs}'),
        _statRow('Homeless', '${_sim.homeless}'),
        ..._mortalityStats(), // corpses + deaths = vital stats, not politics
        if (_sim.grown.isNotEmpty) _utilisationRow(),
        _powerRow(),
        _computeRow(),
        _happinessRow(),
        if (_sim.congestion > 0.02)
          _meterRow('Traffic congestion',
              '${(_sim.congestion * 100).toStringAsFixed(0)}%', _sim.congestion,
              _sim.congestion > 0.6
                  ? AppTheme.danger
                  : (_sim.congestion > 0.35 ? AppTheme.warn : AppTheme.accent2),
              warn: _sim.congestion > 0.5
                  ? 'Gridlock — workers stuck commuting, staffing down ${((1 - (1 - _sim.congestion * 0.4)) * 100).toStringAsFixed(0)}%.'
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
        if (_sim.wasteBacklog > 0.02)
          _meterRow('Waste backlog', '${(_sim.wasteBacklog * 100).toStringAsFixed(0)}%',
              _sim.wasteBacklog,
              _sim.wasteBacklog > 0.5 ? AppTheme.danger : AppTheme.warn,
              warn: _sim.wasteBacklog > 0.4
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
        _statRow('Funds', '§${_sim.funds.toStringAsFixed(0)}'),
        _statRow('Research', '${_sim.research.toStringAsFixed(0)} pts'),
        const SizedBox(height: 12),
        const Text('RCI DEMAND', style: AppTheme.heading),
        const SizedBox(height: 6),
        _rciBar('Residential', _sim.resTarget, const Color(0xFF7FE0A0)),
        _rciBar('Commercial', _sim.comTarget, const Color(0xFF4FC3F7)),
        _rciBar('Industrial', _sim.indTarget, const Color(0xFFE3A857)),
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
        if (_sim.revoltMsg != null) _revoltBanner(),
        _socialBar('Crime', _sim.crime, AppTheme.danger),
        _socialBar('Corruption', _sim.corruption, const Color(0xFFB388FF)),
        _socialBar('Inequality', _sim.inequality, const Color(0xFFE3A857)),
        _socialBar('Rebellion', _sim.rebellion, AppTheme.danger),
        _socialBar('Disease', _sim.disease, const Color(0xFF9CCC65)),
      ];

  /// Corpses + death-rate readout — a CITY metric (vital stats), not politics.
  ///
  /// Rows render whenever the colony is populated (not gated on the live value)
  /// so the panel doesn't THRASH as the death rate / corpse count crosses a
  /// threshold frame-to-frame — at zero they just sit dimmed.
  List<Widget> _mortalityStats() {
    if (_sim.population < 1) return const [];
    final corpseAlarm = _sim.corpses > _sim.population * 0.05;
    final corpseColor =
        _sim.corpses < 0.5 ? AppTheme.textDim : (corpseAlarm ? AppTheme.danger : AppTheme.warn);
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(Icons.dangerous, size: 14, color: corpseColor),
          const SizedBox(width: 6),
          const Expanded(
              child: Text('Corpses (unprocessed)', style: AppTheme.body)),
          Text(_sim.corpses.toStringAsFixed(0),
              style: AppTheme.mono.copyWith(color: corpseColor)),
        ]),
      ),
      _statRow('Deaths', '${_sim.deathRate.toStringAsFixed(2)}/s'),
      // Disease warning still appears only when the backlog is dangerous, but
      // it's the last line so toggling it can't shove the rows above it.
      if (_sim.corpses > _sim.population * 0.03 && _sim.population > 10)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
              'Corpse backlog spreading disease — build morgues / crematoria.',
              style: AppTheme.dim.copyWith(color: AppTheme.danger)),
        ),
    ];
  }

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
    final fx = _sim.biomeFx;
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
        _sim.disaster = d;
        _sim.disasterTime = d.duration;
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
    final hasFuel = _sim.stockOf(Commodity.fuel) >= 10;
    _contextMenu('Landing Site', Icons.rocket_launch, AppTheme.accent2, [
      _ctxAction(
          _sim.flagPlanted ? Icons.flag : Icons.outlined_flag,
          _sim.flagPlanted ? 'Flag planted' : 'Plant flag',
          _sim.flagPlanted ? 'Your colours fly over the colony.' : 'Claim this world.',
          _sim.flagPlanted ? AppTheme.textDim : AppTheme.accent2,
          () => setState(() => _sim.flagPlanted = true)),
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
    setState(() => _sim.stock[Commodity.fuel] = _sim.stockOf(Commodity.fuel) - 10);
    // Launch the lander into the real 3D sim from this colony's surface.
    _fly3DAscent();
  }


  /// Delivery MANAGER for [anchor]: list every scheduled delivery, reorder
  /// (priority), assign each to a pad, add new ones, remove. Lets a starport run
  /// several deliveries in parallel across its pads.
  void _showDeliveryConfig(int anchor) {
    final padCount = _sim.specAt(anchor)?.cellCount ?? 1;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.panel,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final list = _sim.deliveries[anchor] ?? const <_DeliverySchedule>[];
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
                                              _sim.deliveries.remove(anchor);
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
    final returnFuel = _sim.returnFuelFor(amount);
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
                  for (final r in CitySim.deliverable)
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
                        (_sim.deliveries[anchor] ??= []).add(sched);
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
          '${status.label} · ${_sim.isConnected(anchor) ? "connected" : "cut off"}',
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
      final connected = _sim.isConnected(anchor);
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
      final parked = _sim.landerPad == anchor;
      actions.add(_ctxAction(
          parked ? Icons.flight_takeoff : Icons.flight_land,
          parked ? 'Lander is parked here' : 'Land lander on this pad',
          parked
              ? 'Clear the pad for incoming shuttles.'
              : 'Move the landing site onto this spaceport (marks it occupied).',
          AppTheme.accent2,
          () => setState(() => _sim.landerPad = parked ? null : anchor)));
      // Anti-soft-lock lifeline: call in a relief mission that lands on a free
      // pad, dwells 30 s + drops supplies + settlers, then leaves. Cooldown +
      // needs a free pad (a spaceport has one pad per footprint tile).
      final cd = _sim.reliefCooldown.ceil();
      final hasPad = _sim.freePad(anchor) != null;
      final canRelief = _sim.reliefCooldown <= 0 && hasPad;
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
          canRelief ? () => _sim.requestRelief(anchor) : () {}));
      // Recurring resource deliveries (a list — a starport runs several).
      final list = _sim.deliveries[anchor];
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
              _sim.clearCell(anchor);
              _sim.recompute();
            })));
    _contextMenu(spec.label, spec.icon, spec.color, actions);
  }

  /// Diagnose this building's worst current problem so the Details readout +
  /// modal explain WHY it's flagged (matches the on-map status icons) instead
  /// of always claiming "Operating". Checked worst-first; the first hit wins.
  ({String label, String why, String fix, Color color}) _buildingStatus(
      int anchor, CitySpec spec) {
    final powerRatio =
        _sim.powerDraw <= 0 ? 1.0 : (_sim.powerOut / _sim.powerDraw).clamp(0.0, 1.0);
    final needsPower = spec.powerDraw > 0;
    final needsStaff = spec.jobs > 0;

    if (_sim.abandoned.contains(anchor)) {
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
    if (!_sim.isConnected(anchor)) {
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
            'of demand (${_sim.powerOut.toStringAsFixed(0)}/${_sim.powerDraw.toStringAsFixed(0)} '
            'power). Under-powered buildings run throttled and risk abandonment.',
        fix: 'Build more generators (solar / reactor / fusion) or demolish '
            'non-essential draws until supply exceeds demand.',
        color: AppTheme.warn,
      );
    }
    if (needsStaff && _sim.staffing < 0.95) {
      return (
        label: 'Understaffed',
        why: 'The city can only fill ${(_sim.staffing * 100).toStringAsFixed(0)}% of '
            'its jobs, so this building runs short-handed and below full output. '
            'Too few workers, or congestion stretching their commute.',
        fix: 'Grow population (housing + a connected spaceport for immigrants), '
            'or cut road congestion + excess jobs so workers go round.',
        color: AppTheme.warn,
      );
    }
    if (_sim.corpses > 1) {
      return (
        label: 'Bodies unprocessed',
        why: 'There are ${_sim.corpses.toStringAsFixed(0)} unprocessed corpses in '
            'the colony. The backlog breeds disease and litters the streets, '
            'dragging happiness across every building.',
        fix: 'Build / connect deathcare (cemetery, crematorium) and keep it '
            'powered + staffed so bodies are processed faster than they pile up.',
        color: AppTheme.warn,
      );
    }
    if (_sim.happiness < 0.5) {
      return (
        label: 'Unhappy',
        why: 'Colony happiness is ${(_sim.happiness * 100).toStringAsFixed(0)}%. '
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
      _sim.radiation = (_sim.radiation + 0.3).clamp(0.0, 1.0);
      _sim.clearCell(anchor); // the reactor is gone
      _sim.recompute();
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
        _Disaster.values.where((d) => d != _Disaster.none && _sim.disasterPossible(d));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(_sim.hasWarning ? Icons.sensors : Icons.sensors_off,
            size: 14,
            color: _sim.hasWarning ? AppTheme.accent2 : AppTheme.textDim),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _sim.hasWarning
                ? 'Early-warning online — disasters are forecast, prep your bunkers.'
                : 'No early-warning station — build one to forecast disasters.'
                    ' Bunkers + Emergency Services reduce harm.',
            style: AppTheme.dim.copyWith(
                color: _sim.hasWarning ? AppTheme.accent2 : AppTheme.textDim),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      if (_sim.disaster != _Disaster.none)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Icon(_sim.disaster.icon, size: 16, color: AppTheme.warn),
            const SizedBox(width: 6),
            Text('${_sim.disaster.label} active (${_sim.disasterTime.toStringAsFixed(0)}s)',
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
                color: _sim.disaster == d
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
                        : (_sim.disaster == d ? AppTheme.bg : AppTheme.text)),
                const SizedBox(width: 4),
                Text(d.label,
                    style: TextStyle(
                        fontSize: 11,
                        color: d == _Disaster.nuke
                            ? AppTheme.danger
                            : (_sim.disaster == d ? AppTheme.bg : AppTheme.text))),
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
                value: _sim.body,
                isExpanded: true,
                dropdownColor: AppTheme.panelLight,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: [
                  for (final b in _sim.bodies)
                    DropdownMenuItem(
                        value: b, child: Text(b.name, style: AppTheme.body)),
                ],
                onChanged: (b) => setState(() => _sim.body = b!),
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
                value: _sim.biome,
                isExpanded: true,
                dropdownColor: AppTheme.panelLight,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: [
                  for (final b in Biome.values)
                    DropdownMenuItem(
                        value: b, child: Text(_biomeName(b), style: AppTheme.body)),
                ],
                onChanged: (b) => setState(() => _sim.biome = b!),
              ),
            ),
          ]),
          Text(_biomeSummary(), style: AppTheme.dim.copyWith(fontSize: 11)),
          const SizedBox(height: 4),
          Wrap(spacing: 14, runSpacing: 4, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.solar_power, size: 14, color: Color(0xFFFFD23F)),
              const SizedBox(width: 4),
              Text('Solar ×${_sim.solarFactor.toStringAsFixed(2)}',
                  style: AppTheme.mono.copyWith(
                      color: _sim.solarFactor >= 1 ? AppTheme.accent2 : AppTheme.warn,
                      fontSize: 12)),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.wind_power, size: 14, color: Color(0xFFB2DFDB)),
              const SizedBox(width: 4),
              Text('Wind ×${_sim.windFactor.toStringAsFixed(2)}',
                  style: AppTheme.mono.copyWith(
                      color:
                          _sim.windFactor >= 0.5 ? AppTheme.accent2 : AppTheme.warn,
                      fontSize: 12)),
            ]),
          ]),
          if (_sim.windFactor < 0.05)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('Airless world — wind turbines are useless here.',
                  style: AppTheme.dim.copyWith(color: AppTheme.warn)),
            ),
          const SizedBox(height: 2),
          Row(children: [
            Icon(_sim.breathable ? Icons.air : Icons.masks,
                size: 14,
                color: _sim.breathable ? AppTheme.accent2 : AppTheme.warn),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                _sim.breathable
                    ? 'Breathable air (O₂ ${(_sim.o2Fraction * 100).toStringAsFixed(0)}%) — oxygen free.'
                    : _sim.o2Harvestable
                        ? 'Thin O₂ (${(_sim.o2Fraction * 100).toStringAsFixed(0)}%) — harvest or split water.'
                        : 'No breathable O₂ — split water (electrolysis) or shuttle in.',
                style: AppTheme.dim.copyWith(
                    color: _sim.breathable ? AppTheme.accent2 : AppTheme.warn,
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
    final s = _sim.surface;
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
        _condChip('Aquifer', '${(_sim.waterTable * 100).toStringAsFixed(0)}%'),
        _condChip('Grav', '${s.gravityG.toStringAsFixed(2)}g'),
      ]),
      if (_sim.waterTable < 0.4)
        Text('Water table low — pumping is drying the surface; plants dying back.',
            style: AppTheme.dim.copyWith(
                color: _sim.waterTable < 0.2 ? AppTheme.danger : AppTheme.warn,
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
        final l = _sim.liquid;
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
                '${_sim.oceanPollution > 0.05 ? " · polluted" : ""}',
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
              child: Text(_sim.blocked!,
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
            'Grows: ${spec.label} — ${spec.housing > 0 ? "+${spec.housing} housing" : "${spec.jobs} jobs"} · ${CitySim.zoneBuildCost.toStringAsFixed(0)} ore each',
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
    final locked = !_sim.unlocked(u);
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
            _sim.powerFactor(s.type) == 1.0
                ? '+${s.powerOutput.toStringAsFixed(0)}'
                : '+${(s.powerOutput * _sim.powerFactor(s.type)).toStringAsFixed(0)} (×${_sim.powerFactor(s.type).toStringAsFixed(2)} here)',
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
    final afford = _sim.stockOf(Commodity.ore) >= cost;
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
    final cap = _sim.stockCap;
    final rate = _netRates();
    final raw = _netRates(throttled: false);
    final shown = Commodity.ordered.where((c) =>
        _sim.stockOf(c) > 0.05 ||
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
                  color: _sim.stockOf(c) >= cap - 0.5
                      ? AppTheme.warn
                      : const Color(0xFF223247)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${Commodity.name(c)} ',
                  style: AppTheme.dim.copyWith(fontSize: 11)),
              _sim.infiniteRes && c != Commodity.garbage && c != Commodity.sewage
                  ? const Icon(Icons.all_inclusive,
                      size: 12, color: AppTheme.accent2)
                  : Text(_sim.stockOf(c).toStringAsFixed(0),
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
    final cap = _sim.stockCap;
    final rates = _netRates();
    final raw = _netRates(throttled: false);
    bool show(String c) =>
        _sim.stockOf(c) > 0.05 ||
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
            Text('${_sim.stockOf(c).toStringAsFixed(0)}/${cap.toStringAsFixed(0)}',
                style: AppTheme.mono.copyWith(
                    color: _sim.stockOf(c) >= cap - 0.5
                        ? AppTheme.warn
                        : _sim.stockOf(c) > 0
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
    final t = throttled ? _sim.throttle : 1.0;
    final r = <String, double>{};
    for (final e in _sim.activeSpecs) {
      e.value.outputs.forEach((k, v) => r[k] = (r[k] ?? 0) + v * t);
      e.value.inputs.forEach((k, v) => r[k] = (r[k] ?? 0) - v * t);
    }
    r[Commodity.food] = (r[Commodity.food] ?? 0) - _sim.population * CitySim.foodPerPersonPerSec;
    r[Commodity.water] = (r[Commodity.water] ?? 0) - _sim.population * CitySim.waterPerPersonPerSec;
    if (!_sim.breathable) {
      r[Commodity.oxygen] =
          (r[Commodity.oxygen] ?? 0) - _sim.population * CitySim.waterPerPersonPerSec;
    }
    // Population GENERATES waste (positive net = it's piling up).
    r[Commodity.garbage] =
        (r[Commodity.garbage] ?? 0) + _sim.population * CitySim.garbagePerPersonPerSec;
    r[Commodity.sewage] =
        (r[Commodity.sewage] ?? 0) + _sim.population * CitySim.sewagePerPersonPerSec;
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
    for (final e in _sim.activeSpecs) {
      final s = e.value;
      final out = (s.outputs[c] ?? 0) * _sim.biomeMult(c) * _sim.throttle;
      final inp = (s.inputs[c] ?? 0) * _sim.throttle;
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
    if (c == Commodity.food) life = _sim.population * CitySim.foodPerPersonPerSec;
    if (c == Commodity.water) life = _sim.population * CitySim.waterPerPersonPerSec;
    if (c == Commodity.oxygen && !_sim.breathable) {
      life = _sim.population * CitySim.waterPerPersonPerSec;
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
        final (title, body, fix) = switch (_sim.noSpaceportReason) {
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
    final cap = _sim.stockCap;
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
                _kvLine('In stock', '${_sim.stockOf(c).toStringAsFixed(0)} / ${cap.toStringAsFixed(0)}'),
                _kvLine('Net rate',
                    _fmtRate(net) + (((raw - net).abs() > 0.05) ? '  (potential ${_fmtRate(raw)})' : ''),
                    net >= 0 ? AppTheme.accent2 : AppTheme.warn),
                if (raw - net > 0.05)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        'Production throttled to ${(_sim.throttle * 100).toStringAsFixed(0)}% — '
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
    final power = _sim.powerDraw <= 0 ? 1.0 : (_sim.powerOut / _sim.powerDraw).clamp(0.0, 1.0);
    final compute = _sim.computeDemand <= 0 ? 1.0 : (_sim.computeSupply / _sim.computeDemand).clamp(0.0, 1.0);
    if (_sim.staffing <= power && _sim.staffing <= compute) return 'staffing (not enough workers)';
    if (power <= compute) return 'power (brownout)';
    return 'compute (data shortfall)';
  }

  String _howToGrow(String c) => switch (c) {
        Commodity.ore => 'Build more Mines. Heavy Industry zones also refine ore→steel.',
        Commodity.steel => 'Build Steel Mills (need ore) or zone Industrial.',
        Commodity.water => 'Build Water Plants; biome + rain boost it.',
        Commodity.food => 'Build Farms (need water). Avoid nuclear winter.',
        Commodity.oxygen => _sim.breathable
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
    final ratio = _sim.powerDraw <= 0 ? 1.0 : (_sim.powerOut / _sim.powerDraw).clamp(0.0, 1.0);
    final ok = ratio >= 1.0;
    return _meterRow('Power', '${_sim.powerOut.toStringAsFixed(0)} / ${_sim.powerDraw.toStringAsFixed(0)}',
        ratio, ok ? AppTheme.accent2 : AppTheme.danger,
        warn: ok ? null : 'Brownout — production throttled.',
        onExplain: () => _showExplain(
            'Power Grid',
            ok
                ? 'Generation (${_sim.powerOut.toStringAsFixed(0)}) meets demand '
                    '(${_sim.powerDraw.toStringAsFixed(0)}).'
                : 'Demand (${_sim.powerDraw.toStringAsFixed(0)}) exceeds generation '
                    '(${_sim.powerOut.toStringAsFixed(0)}). Every building throttles to the '
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
    for (final k in _sim.grown) {
      if (_sim.zones[k] == null) continue;
      sum += _sim.utilFactor(k);
      if (_sim.underConstruction(k)) building++;
      stages.update(_sim.utilStage(k), (v) => v + 1, ifAbsent: () => 1);
    }
    final avg = _sim.grown.isEmpty ? 0.0 : sum / _sim.grown.length;
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
    if (_sim.computeDemand <= 0 && _sim.computeSupply <= 0) return const SizedBox.shrink();
    final ratio = _sim.computeDemand <= 0 ? 1.0 : (_sim.computeSupply / _sim.computeDemand).clamp(0.0, 1.0);
    final ok = ratio >= 1.0;
    return _meterRow('Compute', '${_sim.computeSupply.toStringAsFixed(0)} / ${_sim.computeDemand.toStringAsFixed(0)}',
        ratio, ok ? AppTheme.accent : AppTheme.danger,
        warn: ok ? null : 'Compute shortfall — advanced buildings throttled.');
  }

  Widget _pollutionRow() {
    final level = (_sim.pollution / 200).clamp(0.0, 1.0);
    final c = level > 0.6 ? AppTheme.danger : (level > 0.3 ? AppTheme.warn : AppTheme.accent2);
    return _meterRow('Pollution', _sim.pollution.toStringAsFixed(0), level, c,
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
    if (_sim.radiation <= 0.02) return const SizedBox.shrink();
    return _meterRow('Radiation', '${(_sim.radiation * 100).toStringAsFixed(0)}%',
        _sim.radiation, _sim.radiation > 0.4 ? AppTheme.danger : AppTheme.warn,
        warn: _sim.radiation > 0.4 ? 'Radiation sickness killing citizens.' : null,
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
    final h = _sim.happiness;
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
    final built = _sim.grown.length + _sim.utils.length;
    final abandoned = _sim.abandoned.length;
    final disconnected = [
      ..._sim.grown.where((k) => !_sim.isConnected(k)),
      ..._sim.utils.keys.where((k) => !_sim.isConnected(k)),
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
            _pill(e.label, _sim.economy == e, AppTheme.accent,
                () => setState(() => _sim.economy = e)),
        ],
      );

  Widget _govtPicker() => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final g in _Govt.values)
            _pill(g.label, _sim.govt == g, AppTheme.accent2, () => setState(() {
                  _sim.govt = g;
                  if (g.lawsAutoVoted) _sim.autoVote();
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
    final controllable = _sim.economy.taxControllable;
    final tax = _sim.effectiveTax();
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
              onChanged: controllable ? (v) => setState(() => _sim.taxRate = v) : null),
        ),
      ]),
    );
  }

  List<Widget> _lawRows() {
    final auto = _sim.govt.lawsAutoVoted;
    return [
      Text(
          auto
              ? '${_sim.govt.label}: laws are auto-voted to address the worst problems.'
              : 'Enact ordinances directly:',
          style: AppTheme.dim),
      const SizedBox(height: 4),
      for (final l in _Law.values)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            Icon(_sim.laws.contains(l) ? Icons.check_box : Icons.check_box_outline_blank,
                size: 17,
                color: _sim.laws.contains(l) ? AppTheme.accent2 : AppTheme.textDim),
            const SizedBox(width: 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.label, style: AppTheme.body),
                Text(l.effect, style: AppTheme.dim),
              ]),
            ),
            if (!auto)
              Switch(
                  value: _sim.laws.contains(l),
                  activeThumbColor: AppTheme.accent2,
                  onChanged: (v) =>
                      setState(() => v ? _sim.laws.add(l) : _sim.laws.remove(l))),
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
              child: Text(_sim.revoltMsg!,
                  style: AppTheme.dim.copyWith(color: AppTheme.danger))),
          GestureDetector(
            onTap: () => setState(() => _sim.revoltMsg = null),
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

