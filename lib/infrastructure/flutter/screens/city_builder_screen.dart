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
import 'city_panels.dart';
import 'city_site_actions.dart';

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
typedef _Economy = Economy;
typedef _ColonyStyle = ColonyStyle;
typedef _LandedCraft = LandedCraft;

class _CityBuilderScreenState extends State<CityBuilderScreen>
    with TickerProviderStateMixin, CityPanels {
  @override
  CitySim get sim => _sim;

  @override
  void panelChanged() => setState(() {});

  /// The flat builder is where a colony is DESIGNED — including, in the
  /// stand-alone sandbox, which world it stands on. Driving a live colony
  /// (`driveLocally: false`) means the world already owns it, so re-siting is
  /// off there too.
  @override
  bool get panelCanResite => widget.driveLocally;

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
  List<LaunchSite> get _launchSites => cityLaunchSites(_sim);

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
            final site = CitySim.siteIdOfCell(anchor);
            final pad = _sim.freePad(site);
            if (pad != null) {
              _sim.craft.add(_LandedCraft(
                  site: site,
                  padIndex: pad,
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
      final spec = anchor == null ? null : _sim.utils[anchor];
      if (anchor != null && spec != null) {
        showCitySiteMenu(
          context: context,
          sim: _sim,
          site: CitySim.siteIdOfCell(anchor),
          spec: spec,
          onChanged: () => setState(() {}),
          hooks: _siteHooks(anchor),
        );
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
                landerPad: CitySim.cellOfSiteId(_sim.landerPad),
                landedCraft: [
                  for (final c in _sim.craft)
                    // All craft use the simple pad animation now (no free flight),
                    // so they report no altitude/downrange — always on their pad.
                    // A craft visiting a LOT-placed port has no cell to stand
                    // on, so the flat map simply does not draw it.
                    if (_sim.padCellOf(c.site, c.padIndex) case final tile?)
                      (
                        tile: tile,
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
        body(cityWorldPanel()),
        body(cityStatusPanel()),
        body(cityPoliticsPanel()),
        body(cityStockPanel()),
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

  /// Host actions the flat map contributes to the shared site sheet.
  ///
  /// "Pilot a landing" and "Launch in 3D sim" are BRIDGES: they exist to carry
  /// you from the map out into the world. The in-world editor deliberately
  /// omits them — from the cockpit you are already flying, so it offers pad
  /// targeting in their place.
  CitySiteHooks _siteHooks(int anchor) => CitySiteHooks(
        onOpenVab: _openVab,
        extra: (site, spec) => [
          if (spec.type == 'spaceport') ...[
            citySiteAction(
                context,
                Icons.flight_land,
                'Pilot a landing',
                'Fly an in-atmo descent over the colony — touch down on a pad, '
                    'or smash into the city.',
                AppTheme.warn,
                () => _pilotLanding(anchor)),
            citySiteAction(
                context,
                Icons.rocket_launch,
                'Launch in 3D sim',
                'Fly a staged ascent in the full 3D sim — real planet sphere, '
                    'orbit camera, and STAGE/decouple.',
                AppTheme.accent2,
                _fly3DAscent),
          ],
        ],
      );

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
    final rate = netRates();
    final raw = netRates(throttled: false);
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
            onTap: () => showResourceDetail(c),
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
              Text(fmtRate(rate[c] ?? 0),
                  style: AppTheme.mono.copyWith(
                      fontSize: 11,
                      color: (rate[c] ?? 0) >= 0
                          ? AppTheme.accent2
                          : AppTheme.warn)),
              // Show the unthrottled potential when it differs (production cut).
              if (((raw[c] ?? 0) - (rate[c] ?? 0)).abs() > 0.05)
                Text(' (${fmtRate(raw[c] ?? 0)})',
                    style: AppTheme.mono.copyWith(
                        fontSize: 10, color: AppTheme.textDim)),
            ]),
          ),
          ),
      ]),
    );
  }





  /// A "why did this happen / how to fix" modal for a warning or status.
  ///
  /// A thin wrapper on the shared modal: seventeen call sites read better
  /// against a method than against a free function taking `context`.
  void _showExplain(String title, String why, String fix, Color color) =>
      showExplain(context, title, why, fix, color);

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










  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// Display name for a biome (shared by the builder + the new-city setup screen).

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

