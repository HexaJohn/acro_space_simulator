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

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/commodity.dart';
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

  /// The palette row currently expanded for detail, by label. One at a
  /// time: the panel is short, and two open rows push the rest off it.
  String? expandedLabel;

  /// Build-palette filter, lowercased on read. Same search the 2D builder has.
  String buildSearch = '';

  /// Add a control point to the road being drawn.
  void addSplinePoint(Vec2 p) {
    // Skip points a hand-drag dumps almost on top of each other: they make the
    // curve cusp and buy nothing.
    if (pending.isNotEmpty && pending.last.distanceTo(p) < 8) return;
    pending.add(p);
    notifyListeners();
  }

  /// Commit the drawn road: junctions split, lots re-cut, buildings carried
  /// across any lot renames.
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
    city.commitRoad(List.of(pending), roadClass);
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

  /// Apply the held tool to a PARCEL.
  ///
  /// The parcel path is the one the in-flight editor uses for everything now.
  /// A lot knows its own size, frontage and orientation, so none of the cell
  /// path's questions — does the footprint fit, is it road-adjacent, which way
  /// does it face — have to be asked.
  void applyToLot(CitySim city, String parcelId) {
    blocked = null;
    switch (tool) {
      case CityEditTool.utility:
        applyToParcel(city, parcelId);
      case CityEditTool.zone:
        city.layout.setUse(parcelId, _useForKind());
        notifyListeners();
      case CityEditTool.bulldoze:
        city.parcelBuildings.remove(parcelId);
        city.grownParcels.remove(parcelId);
        city.lotFires.remove(parcelId);
        city.layout.setUse(parcelId, ParcelUse.unzoned);
        notifyListeners();
      case CityEditTool.inspect:
      case CityEditTool.roadSpline:
      case CityEditTool.road:
      case CityEditTool.retrofit:
      case CityEditTool.support:
        return;
    }
  }

  ParcelUse _useForKind() => switch (zoneKind) {
        'commercial' => ParcelUse.commercial,
        'industrial' => ParcelUse.industrial,
        _ => ParcelUse.residential,
      };

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

  /// Window width, captured on build so the panel widgets can bound
  /// themselves without each plumbing a LayoutBuilder.
  static double _maxWidth = 560;

  @override
  Widget build(BuildContext context) {
    _maxWidth = math.max(240.0, MediaQuery.sizeOf(context).width - 24);
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
              // Horizontally scrollable: the tool strip plus the readouts is
              // wider than a narrow window, and a toolbar that overflows is a
              // toolbar with unreachable tools on it.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                _tool(CityEditTool.inspect, Icons.search, 'Look'),
                _tool(CityEditTool.zone, Icons.grid_view, 'Zone'),
                _tool(CityEditTool.roadSpline, Icons.timeline, 'Road'),
                _tool(CityEditTool.utility, Icons.factory, 'Build'),
                _tool(CityEditTool.bulldoze, Icons.clear, 'Clear'),
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
              ),
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
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
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
        ),
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

  /// Zone kind and density: the 2D builder's picker, brought across. Named
  /// chips rather than anonymous colour swatches, because "Residential /
  /// Medium" is what the player is choosing, not a shade of green.
  Widget _zoneRow() {
    Widget kindChip(String kind, String label, int argb) {
      final sel = controller.zoneKind == kind;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: GestureDetector(
          onTap: () => controller.pickZone(kind, controller.density),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: sel ? Color(argb) : const Color(0xFF16202B),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 11,
                    color: sel
                        ? const Color(0xFF0B1017)
                        : const Color(0xFFD6E2EE))),
          ),
        ),
      );
    }

    Widget densityChip(Density d, String label) {
      final sel = controller.density == d;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: GestureDetector(
          onTap: () => controller.pickZone(controller.zoneKind, d),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: sel ? AppTheme.accent : const Color(0xFF16202B),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 10,
                    color: sel
                        ? const Color(0xFF0B1017)
                        : const Color(0xFFD6E2EE))),
          ),
        ),
      );
    }

    final spec = kZoneSpecs[controller.zoneKind]![controller.density]!;
    final what = spec.housing > 0 ? '+${spec.housing} hab' : '${spec.jobs} jobs';
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          kindChip('residential', 'Residential', 0xFF7FE0A0),
          kindChip('commercial', 'Commercial', 0xFF4FC3F7),
          kindChip('industrial', 'Industrial', 0xFFE3A857),
          const SizedBox(width: 10),
          densityChip(Density.low, 'Low'),
          densityChip(Density.medium, 'Medium'),
          densityChip(Density.high, 'High'),
          const SizedBox(width: 10),
          // What this combination actually grows, so the choice is not blind.
          Text('${spec.label} - $what',
              style: const TextStyle(fontSize: 10, color: Color(0xFF9FB4CC))),
        ]),
      ),
    );
  }

  /// The FULL building palette, exactly as the 2D builder presents it:
  /// grouped, searchable, and showing locked entries rather than hiding them.
  ///
  /// Hiding what you cannot build yet was the wrong call — a palette that
  /// silently omits half the catalogue reads as a shorter game, and the
  /// population gate is the thing that tells you what to grow toward.
  Widget _buildRow() {
    final q = controller.buildSearch.trim().toLowerCase();
    final groups = <String, List<CityBuildingSpec>>{};
    for (final u in kUtilCatalog) {
      if (!_matches(u, q)) continue;
      groups.putIfAbsent(u.group, () => []).add(u);
    }

    return SizedBox(
      // Bounded by the window: the palette is a panel, not a reason for the
      // whole toolbar to overflow off-screen.
      width: math.min(560.0, _maxWidth),
      height: 240,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              height: 28,
              child: TextField(
                style: const TextStyle(fontSize: 11, color: Color(0xFFD6E2EE)),
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 14),
                  prefixIconConstraints:
                      BoxConstraints(minWidth: 26, minHeight: 26),
                  hintText: 'Search buildings',
                  hintStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 6),
                ),
                onChanged: (v) {
                  controller.buildSearch = v;
                  controller.changed();
                },
              ),
            ),
          ),
          Expanded(
            child: groups.isEmpty
                ? Center(
                    child: Text('No buildings match "$q".',
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF6D8095))),
                  )
                : ListView(
                    children: [
                      // Catalogue order, not map order: the groups read
                      // power -> services -> industry -> the rest, and that
                      // ordering is meaningful to anyone who knows the 2D one.
                      for (final grp in kGroupLabels.keys)
                        if (groups[grp] != null) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
                            child: Text(kGroupLabels[grp] ?? grp,
                                style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.6,
                                    color: Color(0xFF4FC3F7))),
                          ),
                          for (final u in groups[grp]!) _paletteRow(u),
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  bool _matches(CityBuildingSpec u, String q) =>
      q.isEmpty ||
      u.label.toLowerCase().contains(q) ||
      u.type.toLowerCase().contains(q) ||
      (kGroupLabels[u.group] ?? '').toLowerCase().contains(q);

  Widget _paletteRow(CityBuildingSpec u) {
    // Compare by LABEL, not type: three spaceport sizes share a type, and
    // keying selection off it highlights all three at once.
    final sel = controller.selectedUtil.label == u.label;
    final locked = !city.unlocked(u);
    final colour = Color(u.colorArgb);
    final open = controller.expandedLabel == u.label;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      InkWell(
        onTap: () => controller.pickUtil(u),
        child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: sel ? colour.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: sel ? colour : const Color(0xFF223247)),
        ),
        child: Row(children: [
          Icon(u.icon,
              size: 14, color: locked ? const Color(0xFF5A6B7D) : colour),
          const SizedBox(width: 6),
          Expanded(
            child: Text(u.label,
                style: TextStyle(
                    fontSize: 11,
                    color: locked
                        ? const Color(0xFF6D8095)
                        : const Color(0xFFD6E2EE))),
          ),
          Text(_summary(u),
              style: const TextStyle(fontSize: 9, color: Color(0xFF6D8095))),
          const SizedBox(width: 8),
          Text(
            locked ? 'pop ${u.unlockPop}' : '${u.buildCost.round()} ore',
            style: TextStyle(
                fontSize: 10,
                color: locked
                    ? const Color(0xFFFFB74D)
                    : const Color(0xFF7FE0A0)),
          ),
          InkWell(
            onTap: () {
              controller.expandedLabel = open ? null : u.label;
              controller.changed();
            },
            child: Icon(open ? Icons.expand_less : Icons.expand_more,
                size: 14, color: const Color(0xFF6D8095)),
          ),
        ]),
      ),
      ),
      if (open) _effectDetail(u),
    ]);
  }

  /// The full effect breakdown - the 2D builder's expandable detail, brought
  /// across whole. The one-line summary is for scanning; this is for deciding.
  Widget _effectDetail(CityBuildingSpec s) {
    Widget line(String l, String v, Color c) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            Expanded(
                child: Text(l,
                    style: const TextStyle(
                        fontSize: 10, color: Color(0xFF6D8095)))),
            Text(v,
                style: TextStyle(
                    fontSize: 10, fontFamily: 'monospace', color: c)),
          ]),
        );
    const good = Color(0xFF7FE0A0);
    const bad = Color(0xFFFFB74D);
    const info = Color(0xFF4FC3F7);
    // Power output is shown AS BUILT HERE: solar on Mars is not solar on
    // Earth, and the nameplate figure would be a lie at the point of deciding.
    final pf = city.powerFactor(s.type);
    return Container(
      margin: const EdgeInsets.only(left: 18, right: 4, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x22101820),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (s.housing > 0) line('Housing', '+${s.housing}', good),
        if (s.jobs > 0) line('Jobs', '${s.jobs}', info),
        if (s.powerOutput > 0)
          line(
              'Power',
              pf == 1.0
                  ? '+${s.powerOutput.toStringAsFixed(0)}'
                  : '+${(s.powerOutput * pf).toStringAsFixed(0)} '
                      '(x${pf.toStringAsFixed(2)} here)',
              good),
        if (s.powerDraw > 0)
          line('Power draw', '-${s.powerDraw.toStringAsFixed(0)}', bad),
        if (s.computeOutput > 0)
          line('Compute', '+${s.computeOutput.toStringAsFixed(0)}', good),
        if (s.computeDraw > 0)
          line('Compute use', '-${s.computeDraw.toStringAsFixed(0)}', bad),
        for (final e in s.inputs.entries)
          line('Needs ${Commodity.name(e.key)}',
              '-${e.value.toStringAsFixed(1)}/s', bad),
        for (final e in s.outputs.entries)
          line('Makes ${Commodity.name(e.key)}',
              '+${e.value.toStringAsFixed(1)}/s', good),
        for (final e in s.services.entries)
          line('${e.key} service', '${e.value.toStringAsFixed(0)} pop', info),
        if (s.pollution > 0)
          line('Pollution', '+${s.pollution.toStringAsFixed(1)}/s', bad),
        if (s.pollution < 0)
          line('Scrubs', '${s.pollution.toStringAsFixed(1)}/s', good),
        if (s.storageBonus > 0)
          line('Storage', '+${s.storageBonus.toStringAsFixed(0)}', good),
        if (s.deathcareRate > 0)
          line('Deathcare', '${s.deathcareRate.toStringAsFixed(1)}/s', info),
        line(
            'Site',
            '${s.siteMetres().width.round()}x'
                '${s.siteMetres().depth.round()} m',
            const Color(0xFF9FB4CC)),
        line('Build', '${s.buildCost.toStringAsFixed(0)} ore',
            city.stockOf('ore') >= s.buildCost ? good : bad),
      ]),
    );
  }

  /// One-line effect summary, so a row says what the building DOES without
  /// needing the 2D builder's expandable detail panel.
  String _summary(CityBuildingSpec u) {
    final bits = <String>[];
    if (u.housing > 0) bits.add('+${u.housing} hab');
    if (u.jobs > 0) bits.add('${u.jobs} jobs');
    if (u.powerOutput > 0) bits.add('+${u.powerOutput.round()} pw');
    if (u.powerDraw > 0) bits.add('-${u.powerDraw.round()} pw');
    for (final e in u.outputs.entries) {
      bits.add('+${Commodity.name(e.key)}');
    }
    if (u.siteWidthM > 0) {
      bits.add('${(u.siteWidthM / 1000).toStringAsFixed(1)}km site');
    }
    return bits.take(3).join('  ');
  }

}
