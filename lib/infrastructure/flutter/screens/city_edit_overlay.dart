// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The city editor, as an overlay on the 3D flight view.
///
/// The same tools as the 2D builder — zone, road, utility, bulldoze, retrofit,
/// support — but applied to the ground you are actually looking at, from the
/// cockpit, without leaving the world. The colony being edited is the one the
/// simulation owns, so a building placed here is standing there the next frame.
library;

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/parcel.dart';
import 'app_theme.dart';
import 'city_model.dart';

/// What the editor does with a tap on the ground.
enum CityEditTool {
  inspect,
  zone,
  road,
  utility,
  bulldoze,
  retrofit,
  support,

  /// Drag out a road SPLINE. Releasing subdivides the blocks either side into
  /// parcels, which is what the grid road tool cannot do — a tile has no
  /// frontage, so nothing can be cut from it.
  roadSpline,
}

/// Editor state, held by the flight view so it survives a rebuild and can be
/// read by the picker without rebuilding the toolbar.
class CityEditController extends ChangeNotifier {
  CityEditTool tool = CityEditTool.inspect;
  String zoneKind = 'residential';
  Density density = Density.low;
  CityBuildingSpec selectedUtil = kUtilCatalog.first;

  /// The cell the cursor is over, for the 3D highlight.
  int? hoverCell;

  /// Last thing the editor refused to do, shown in the toolbar.
  String? blocked;

  /// Control points of the spline currently being drawn, in colony-local
  /// metres. Empty when not drawing.
  final List<Vec2> pending = [];

  /// Road class the spline tool lays.
  RoadClass roadClass = RoadClass.street;

  /// Frontage/depth the blocks are cut at. These are the "user settings" the
  /// parcels are drawn from — change them and the same street re-subdivides.
  double frontageM = 24;
  double lotDepthM = 32;

  int _roadSeq = 0;

  /// Add a control point to the road being drawn.
  void addSplinePoint(Vec2 p) {
    // Skip points a hand-drag dumps almost on top of each other: they make the
    // curve cusp and buy nothing.
    if (pending.isNotEmpty && pending.last.distanceTo(p) < 8) return;
    pending.add(p);
    notifyListeners();
  }

  /// Commit the drawn road and re-cut the parcels around it.
  void commitSpline(CitySim city) {
    if (pending.length < 2) {
      pending.clear();
      notifyListeners();
      return;
    }
    city.layout.settings = city.layout.settings.copyWith(
      frontageM: frontageM,
      depthM: lotDepthM,
    );
    city.layout.addRoad(RoadSpline(
      id: 'road-${_roadSeq++}',
      roadClass: roadClass,
      controls: List.of(pending),
    ));
    pending.clear();
    notifyListeners();
  }

  bool get active => tool != CityEditTool.inspect;

  /// Public rebuild signal. `notifyListeners` is protected, so the toolbar's
  /// own controls — which mutate settings directly — go through this rather
  /// than reaching into the base class.
  void changed() => notifyListeners();

  void set(CityEditTool t) {
    tool = t;
    blocked = null;
    notifyListeners();
  }

  void pickUtil(CityBuildingSpec s) {
    selectedUtil = s;
    tool = CityEditTool.utility;
    notifyListeners();
  }

  void pickZone(String kind, Density d) {
    zoneKind = kind;
    density = d;
    tool = CityEditTool.zone;
    notifyListeners();
  }

  void setHover(int? cell) {
    if (cell == hoverCell) return;
    hoverCell = cell;
    notifyListeners();
  }

  /// Place the held building on the parcel [parcelId].
  ///
  /// The parcel path bypasses the cell rules entirely: a lot already knows its
  /// own size and frontage, so there is no footprint-fit question to ask.
  void applyToParcel(CitySim city, String parcelId) {
    blocked = null;
    final spec = selectedUtil;
    if (tool != CityEditTool.utility) return;
    if (!city.unlocked(spec)) {
      blocked = '\${spec.label} needs \${spec.unlockPop} population.';
      return;
    }
    if (city.stockOf('ore') < spec.buildCost) {
      blocked = 'Needs \${spec.buildCost.toStringAsFixed(0)} ore.';
      return;
    }
    if (!city.placeOnParcel(parcelId, spec)) {
      blocked = 'That lot is taken.';
      return;
    }
    city.stock['ore'] = city.stockOf('ore') - spec.buildCost;
    notifyListeners();
  }

  /// Apply the held tool to [cell] of [city].
  ///
  /// Every branch goes through the colony's own mutators rather than touching
  /// its maps directly — those methods carry the placement rules (footprint
  /// fit, support, cost, connectivity refresh) that a raw map write would skip.
  void applyTo(CitySim city, int cell) {
    blocked = null;
    switch (tool) {
      case CityEditTool.inspect:
      // The spline tool works in continuous metres, not cells — it is driven
      // by addSplinePoint/commitSpline, never by a cell tap.
      case CityEditTool.roadSpline:
        return;
      case CityEditTool.zone:
        if (city.roads.contains(cell)) {
          blocked = 'That is a road.';
          return;
        }
        city.zones[cell] = CityZoneType(zoneKind, density);
        city.recompute();
      case CityEditTool.road:
        city.addRoad(cell);
      case CityEditTool.utility:
        final spec = selectedUtil;
        if (!city.unlocked(spec)) {
          blocked = '${spec.label} needs ${spec.unlockPop} population.';
          return;
        }
        if (city.stockOf('ore') < spec.buildCost) {
          blocked = 'Needs ${spec.buildCost.toStringAsFixed(0)} ore.';
          return;
        }
        if (!city.footprintFree(cell % city.grid, cell ~/ city.grid, spec)) {
          blocked = 'No room for ${spec.label} here.';
          return;
        }
        city.stock['ore'] = city.stockOf('ore') - spec.buildCost;
        city.placeUtil(cell, spec);
        city.recompute();
      case CityEditTool.bulldoze:
        city.clearCell(cell);
        city.recompute();
      case CityEditTool.retrofit:
        city.retrofitCell(cell);
      case CityEditTool.support:
        city.support.add(cell);
        city.recompute();
    }
    notifyListeners();
  }
}

/// The toolbar strip. Sits over the 3D view; deliberately narrow so it does
/// not eat the window the player is flying through.
class CityEditOverlay extends StatelessWidget {
  const CityEditOverlay({
    super.key,
    required this.controller,
    required this.city,
    required this.onClose,
    this.onOpenPanels,
  });

  final CityEditController controller;
  final CitySim city;
  final VoidCallback onClose;

  /// Opens the full 2D builder. The in-world editor covers PLACEMENT; the
  /// panels it has no 3D equivalent for — politics, budgets, stockpiles,
  /// delivery schedules — still live there.
  final VoidCallback? onOpenPanels;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xEE0B1017),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF24313F)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (controller.blocked != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    controller.blocked!,
                    style: const TextStyle(
                        color: Color(0xFFFFB74D), fontSize: 11),
                  ),
                ),
              Row(mainAxisSize: MainAxisSize.min, children: [
                _tool(CityEditTool.inspect, Icons.search, 'Look'),
                _tool(CityEditTool.zone, Icons.grid_view, 'Zone'),
                _tool(CityEditTool.road, Icons.add_road, 'Road'),
                _tool(CityEditTool.roadSpline, Icons.timeline, 'Draw Road'),
                _tool(CityEditTool.utility, Icons.factory, 'Build'),
                _tool(CityEditTool.bulldoze, Icons.clear, 'Clear'),
                _tool(CityEditTool.retrofit, Icons.sync, 'Retrofit'),
                _tool(CityEditTool.support, Icons.foundation, 'Support'),
                const SizedBox(width: 8),
                _stat('§', city.funds),
                _stat('Ore', city.stockOf('ore')),
                _stat('Pop', city.population),
                const SizedBox(width: 8),
                if (onOpenPanels != null)
                  IconButton(
                    onPressed: onOpenPanels,
                    icon: const Icon(Icons.dashboard, size: 16),
                    color: const Color(0xFF9FB4CC),
                    tooltip: 'City panels',
                  ),
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 16),
                  color: const Color(0xFF9FB4CC),
                  tooltip: 'Close editor',
                ),
              ]),
              if (controller.tool == CityEditTool.zone) _zoneRow(),
              if (controller.tool == CityEditTool.roadSpline) _splineRow(),
              if (controller.tool == CityEditTool.utility) _buildRow(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tool(CityEditTool t, IconData icon, String label) {
    final on = controller.tool == t;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: () => controller.set(t),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: on ? AppTheme.accent2.withValues(alpha: 0.22) : null,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
                color: on ? AppTheme.accent2 : const Color(0xFF2A3948)),
          ),
          child: Row(children: [
            Icon(icon,
                size: 14,
                color: on ? AppTheme.accent2 : const Color(0xFF9FB4CC)),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    color: on ? AppTheme.accent2 : const Color(0xFF9FB4CC))),
          ]),
        ),
      ),
    );
  }

  Widget _stat(String label, double value) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: Text('$label ${value.round()}',
            style: const TextStyle(color: Color(0xFF7FE0A0), fontSize: 11)),
      );

  /// Road class and the frontage/depth the blocks get cut at.
  Widget _splineRow() => Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final c in RoadClass.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                onTap: () {
                  controller.roadClass = c;
                  controller.changed();
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                        color: controller.roadClass == c
                            ? Colors.white
                            : const Color(0xFF2A3948)),
                  ),
                  child: Text(c.label,
                      style: const TextStyle(
                          fontSize: 10, color: Color(0xFFD6E2EE))),
                ),
              ),
            ),
          const SizedBox(width: 10),
          _slider('Frontage', controller.frontageM, 8, 80,
              (v) => controller.frontageM = v),
          _slider('Depth', controller.lotDepthM, 12, 120,
              (v) => controller.lotDepthM = v),
          if (controller.pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('${controller.pending.length} pts',
                  style: const TextStyle(
                      fontSize: 10, color: Color(0xFF7FE0A0))),
            ),
        ]),
      );

  Widget _slider(
      String label, double value, double lo, double hi, void Function(double) set) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label ${value.round()}m',
          style: const TextStyle(fontSize: 10, color: Color(0xFF9FB4CC))),
      SizedBox(
        width: 90,
        child: Slider(
          value: value.clamp(lo, hi),
          min: lo,
          max: hi,
          onChanged: (v) {
            set(v);
            controller.changed();
          },
        ),
      ),
    ]);
  }

  Widget _zoneRow() => Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final kind in const ['residential', 'commercial', 'industrial'])
            for (final d in Density.values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: InkWell(
                  onTap: () => controller.pickZone(kind, d),
                  child: Container(
                    width: 26,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Color(kZoneSpecs[kind]![d]!.colorArgb)
                          .withValues(alpha: 0.35 + d.index * 0.2),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(
                        color: controller.zoneKind == kind &&
                                controller.density == d
                            ? Colors.white
                            : Colors.transparent,
                      ),
                    ),
                  ),
                ),
              ),
        ]),
      );

  /// The build palette, filtered to what this colony can actually put up —
  /// showing locked entries here would be a list of things that do nothing.
  Widget _buildRow() {
    final available =
        kUtilCatalog.where((s) => city.unlocked(s)).toList();
    return SizedBox(
      height: 30,
      width: 520,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: available.length,
        itemBuilder: (context, i) {
          final s = available[i];
          final on = identical(controller.selectedUtil, s);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
            child: InkWell(
              onTap: () => controller.pickUtil(s),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: on ? Colors.white : const Color(0xFF2A3948)),
                  color: Color(s.colorArgb).withValues(alpha: 0.18),
                ),
                child: Row(children: [
                  Icon(s.icon, size: 13, color: Color(s.colorArgb)),
                  const SizedBox(width: 4),
                  Text(s.label,
                      style: const TextStyle(
                          fontSize: 10, color: Color(0xFFD6E2EE))),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}
