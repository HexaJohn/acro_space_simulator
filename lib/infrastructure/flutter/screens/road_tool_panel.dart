// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The road tool's rows on the editor strip, and the Traffic tool's.
///
/// Laid out the way a city builder's road panel is: how the tool lays a
/// road (the modes, and the snapping menu beside them); what it lays (the
/// road menu, a tab per group, every type shown — a locked one greyed with
/// the population that opens it, never hidden); how high (a vertical bar
/// next to the types, PAGE UP / PAGE DOWN's twin, with its step); and what
/// the stretch under the cursor would cost to build and to keep. Every
/// figure is read off the controller's last quote, so nothing here walks
/// the network: the host rebuilds this strip every frame.
library;

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/road_build.dart';
import '../../../domain/colony/city/road_catalog.dart';
import '../../../domain/colony/city/road_elevation.dart';
import '../../../domain/colony/city/road_snapper.dart';
import '../../../domain/colony/city/road_traffic_model.dart' show TripKind;
import 'app_theme.dart';
import 'city_edit_overlay.dart';

const Color _dim = Color(0xFF9FB4CC);
const Color _text = Color(0xFFD6E2EE);
const Color _edge = Color(0xFF2A3948);
const Color _faint = Color(0xFF6D8095);
const Color _good = Color(0xFF7FE0A0);
const Color _bad = Color(0xFFFF8A80);
const Color _warn = Color(0xFFFFB74D);
const Color _under = Color(0xFF5AA9E6);

/// A row that scrolls sideways rather than overflowing a narrow window —
/// a toolbar that overflows is a toolbar with unreachable tools on it.
Widget _row(List<Widget> children) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );

Widget _hint(String s) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(s, style: const TextStyle(fontSize: 10, color: _faint)),
    );

Widget _value(String s, Color color) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Text(s, style: TextStyle(fontSize: 10, color: color)),
    );

/// A chip in the strip's own style: outlined, filled when on.
Widget _chip({
  required String label,
  required bool on,
  required VoidCallback onTap,
  IconData? icon,
  Color accent = AppTheme.accent2,
  String? tooltip,
}) {
  final chip = Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: on ? accent.withValues(alpha: 0.20) : null,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: on ? accent : _edge),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: on ? accent : _dim),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: TextStyle(fontSize: 11, color: on ? accent : _dim)),
        ]),
      ),
    ),
  );
  return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
}

/// Whole metres when whole, else one decimal.
String _m(double v) => (v - v.roundToDouble()).abs() < 1e-9
    ? v.round().toString()
    : v.toStringAsFixed(1);

String _perWeek(double v) => '§${v.toStringAsFixed(2)}/wk';

/// The Road tool's rows.
class RoadToolPanel extends StatelessWidget {
  const RoadToolPanel(
      {super.key, required this.controller, required this.city});

  final CityEditController controller;
  final CitySim city;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _row([
          _modeChip(RoadToolMode.straight, Icons.straight),
          _modeChip(RoadToolMode.curved, Icons.turn_slight_right),
          _modeChip(RoadToolMode.freeform, Icons.gesture),
          _modeChip(RoadToolMode.upgrade, Icons.upgrade),
          const SizedBox(width: 6),
          RoadSnapButton(controller: c),
          const SizedBox(width: 10),
          _slider('Frontage', c.frontageM, 8, 80, (v) => c.frontageM = v),
          _slider('Depth', c.lotDepthM, 12, 120, (v) => c.lotDepthM = v),
        ]),
        const SizedBox(height: 4),
        _row([
          for (final g in RoadGroup.values)
            _chip(
              label: g.label,
              on: c.roadGroup == g,
              accent: AppTheme.accent,
              onTap: () {
                c.roadGroup = g;
                c.changed();
              },
            ),
        ]),
        const SizedBox(height: 4),
        _row([
          _elevationBar(),
          _stepSelector(),
          const SizedBox(width: 6),
          for (final t in kRoadCatalog)
            if (t.group == c.roadGroup) _typeCell(t),
        ]),
        const SizedBox(height: 3),
        _readouts(),
      ]),
    );
  }

  Widget _modeChip(RoadToolMode m, IconData icon) => _chip(
        label: m.label,
        icon: icon,
        on: controller.mode == m,
        onTap: () => controller.setMode(m),
        tooltip: switch (m) {
          RoadToolMode.straight => 'Click the start, then the end',
          RoadToolMode.curved =>
            'Click the start, the point the curve bends toward, then the end',
          RoadToolMode.freeform =>
            'Each stretch carries on smoothly from the last',
          RoadToolMode.upgrade => 'Click a road to change it to the type '
              'selected. Right-click a one-way road to reverse it',
        },
      );

  /// A cell of the road menu: its short name and its price per cell, or —
  /// while it is still locked — greyed, with the population that opens it.
  Widget _typeCell(RoadType t) {
    final locked = !city.roadTypeUnlocked(t);
    final on = controller.roadType.id == t.id;
    return Tooltip(
      message: roadTypeTooltip(t, locked: locked),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          onTap: () => controller.pickRoadType(t, unlocked: !locked),
          child: Container(
            constraints: const BoxConstraints(minWidth: 72),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color: on ? const Color(0x552A3948) : null,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: on ? Colors.white : _edge),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(roadTypeShortLabel(t),
                    style: TextStyle(
                        fontSize: 10, color: locked ? _faint : _text)),
                Text(
                  locked
                      ? 'opens at ${t.unlockPop} pop'
                      : '${formatMoney(t.costPerCell)}/cell',
                  style: TextStyle(fontSize: 9, color: locked ? _warn : _good),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The elevation, as a vertical bar beside the road types: raise, the
  /// height, lower — PAGE UP and PAGE DOWN on the screen.
  Widget _elevationBar() {
    final e = controller.elevationM;
    final label =
        e.abs() < 1e-6 ? 'Ground' : '${e > 0 ? '+' : '−'}${_m(e.abs())} m';
    final color = e > 0 ? AppTheme.accent2 : (e < 0 ? _under : _dim);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _edge),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _arrow(Icons.keyboard_arrow_up, 'Raise the road (Page Up)',
            () => controller.stepElevation(1)),
        SizedBox(
          width: 52,
          child: Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 10, color: color, fontWeight: FontWeight.bold)),
        ),
        _arrow(Icons.keyboard_arrow_down, 'Lower the road (Page Down)',
            () => controller.stepElevation(-1)),
      ]),
    );
  }

  Widget _arrow(IconData icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Icon(icon, size: 16, color: _text),
          ),
        ),
      );

  /// What one PAGE UP / PAGE DOWN moves the road by.
  Widget _stepSelector() => Padding(
        padding: const EdgeInsets.only(left: 3),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final s in RoadElevation.stepChoicesM)
            Tooltip(
              message: 'Page Up / Page Down move the road ${_m(s)} m',
              child: InkWell(
                onTap: () => controller.setElevationStep(s),
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 1),
                  width: 36,
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  decoration: BoxDecoration(
                    color: controller.elevationStepM == s
                        ? AppTheme.accent2.withValues(alpha: 0.20)
                        : null,
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(
                        color: controller.elevationStepM == s
                            ? AppTheme.accent2
                            : _edge),
                  ),
                  child: Text('${_m(s)} m',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 9,
                          color: controller.elevationStepM == s
                              ? AppTheme.accent2
                              : _dim)),
                ),
              ),
            ),
        ]),
      );

  /// What the stretch under the cursor would be: its length, its price
  /// (red when the treasury cannot pay it), its upkeep, its grade against
  /// the limit, how much of it is bridge or tunnel — and, amber, why it
  /// cannot be built.
  Widget _readouts() {
    final c = controller;
    final items = <Widget>[];
    if (c.mode == RoadToolMode.upgrade) {
      final q = c.upgradeQuote;
      if (q == null) {
        items.add(_hint('Click a road to make it a ${c.roadType.label} · '
            'right-click a one-way road to reverse it'));
      } else {
        items.add(_value('Upgrade ${formatMoney(q.cost)}',
            q.refusal == RoadRefusal.funds ? _bad : _good));
        items.add(_value('${_perWeek(q.upkeepPerWeek)} upkeep', _dim));
        items.add(_value('${q.lengthM.round()} m', _text));
        if (!q.ok && q.reason != c.blocked) items.add(_value(q.reason, _warn));
      }
      return _row(items);
    }
    final p = c.preview;
    if (p == null) {
      items.add(_hint(c.anchor == null
          ? 'Click the ground to start a road'
          : 'Click to lay the next stretch · right-click or Esc to stop'));
      return _row(items);
    }
    final q = p.quote;
    items.add(_value('${q.lengthM.round()} m', _text));
    if (p.placesControl) {
      items.add(_hint('Click to set the point the curve bends toward'));
      return _row(items);
    }
    final short = q.refusal == RoadRefusal.funds || q.cost > city.funds;
    items.add(_value(formatMoney(q.cost), short ? _bad : _good));
    items.add(_value('${_perWeek(q.upkeepPerWeek)} upkeep', _dim));
    if (c.previewGradePct != null) {
      final steep = q.gradePct > q.gradeLimitPct + 1e-9;
      items.add(_value(
          'Grade ${q.gradePct.toStringAsFixed(1)}% / ${_m(q.gradeLimitPct)}%',
          steep ? _bad : _dim));
    }
    final lowPiers = q.structureM - q.bridgeM;
    if (q.bridgeM > 0.5) {
      items.add(_value('Bridge ${q.bridgeM.round()} m', AppTheme.accent));
    }
    if (lowPiers > 0.5) {
      items.add(_value('Elevated ${lowPiers.round()} m', AppTheme.accent));
    }
    if (q.tunnelM > 0.5) {
      items.add(_value('Tunnel ${q.tunnelM.round()} m', _under));
    }
    if (!q.ok && q.reason != c.blocked) items.add(_value(q.reason, _warn));
    return _row(items);
  }

  Widget _slider(String label, double value, double lo, double hi,
      void Function(double) set) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label ${value.round()}m',
          style: const TextStyle(fontSize: 10, color: _dim)),
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
}

/// One item of the snapping menu.
enum RoadSnapItem {
  roads('Roads'),
  angles('Angles'),
  grid('Zoning grid'),
  guides('Guidelines');

  const RoadSnapItem(this.label);
  final String label;

  bool isOn(RoadSnapOptions o) => switch (this) {
        RoadSnapItem.roads => o.roads,
        RoadSnapItem.angles => o.angles,
        RoadSnapItem.grid => o.zoningGrid,
        RoadSnapItem.guides => o.guidelines,
      };

  RoadSnapOptions toggled(RoadSnapOptions o) => switch (this) {
        RoadSnapItem.roads => o.copyWith(roads: !o.roads),
        RoadSnapItem.angles => o.copyWith(angles: !o.angles),
        RoadSnapItem.grid => o.copyWith(zoningGrid: !o.zoningGrid),
        RoadSnapItem.guides => o.copyWith(guidelines: !o.guidelines),
      };
}

/// The snapping button, a magnet beside the modes: its menu switches what
/// the cursor snaps to.
///
/// A popup MENU, not an anchored overlay: its route puts a barrier over
/// the world, so the click that dismisses it lands on the barrier — never
/// on the ground under it, where it would have started a road.
class RoadSnapButton extends StatelessWidget {
  const RoadSnapButton({super.key, required this.controller});

  final CityEditController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.snap;
    final any = s.roads || s.angles || s.zoningGrid || s.guidelines;
    return PopupMenuButton<RoadSnapItem>(
      tooltip: 'Snapping',
      color: const Color(0xF20B1017),
      onSelected: (item) => controller.setSnap(item.toggled(controller.snap)),
      itemBuilder: (_) => [
        for (final item in RoadSnapItem.values)
          CheckedPopupMenuItem<RoadSnapItem>(
            value: item,
            checked: item.isOn(s),
            child: Text(item.label,
                style: const TextStyle(fontSize: 12, color: _text)),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: any ? _dim : _edge),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CustomPaint(size: const Size(13, 13), painter: _MagnetPainter(on: any)),
          const SizedBox(width: 4),
          Text('Snap', style: TextStyle(fontSize: 11, color: any ? _text : _faint)),
        ]),
      ),
    );
  }
}

/// A horseshoe magnet: the icon set has none, and "snapping" is what the
/// magnet means in every editor the player has used.
class _MagnetPainter extends CustomPainter {
  const _MagnetPainter({required this.on});

  final bool on;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = w * 0.32;
    final cx = w / 2, cy = h * 0.55;
    final body = Paint()
      ..color = on ? _text : _faint
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.26;
    final u = Path()
      ..moveTo(cx - r, h * 0.2)
      ..lineTo(cx - r, cy)
      ..arcToPoint(Offset(cx + r, cy),
          radius: Radius.circular(r), clockwise: false)
      ..lineTo(cx + r, h * 0.2);
    canvas.drawPath(u, body);
    final tip = Paint()..color = on ? const Color(0xFFFF6E6E) : _faint;
    final tw = w * 0.26;
    canvas.drawRect(Rect.fromLTWH(cx - r - tw / 2, 0, tw, h * 0.22), tip);
    canvas.drawRect(Rect.fromLTWH(cx + r - tw / 2, 0, tw, h * 0.22), tip);
  }

  @override
  bool shouldRepaint(_MagnetPainter old) => old.on != on;
}

/// The Traffic tool's rows: which info view, and what it needs.
class TrafficToolPanel extends StatelessWidget {
  const TrafficToolPanel(
      {super.key, required this.controller, required this.city});

  final CityEditController controller;
  final CitySim city;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _row([
          _chip(
              label: TrafficInfoView.routes.label,
              icon: Icons.alt_route,
              on: c.trafficView == TrafficInfoView.routes,
              onTap: () => c.setTrafficView(TrafficInfoView.routes)),
          _chip(
              label: TrafficInfoView.junctions.label,
              icon: Icons.traffic,
              on: c.trafficView == TrafficInfoView.junctions,
              onTap: () => c.setTrafficView(TrafficInfoView.junctions)),
          _chip(
              label: TrafficInfoView.adjust.label,
              icon: Icons.edit_road,
              on: c.trafficView == TrafficInfoView.adjust,
              onTap: () => c.setTrafficView(TrafficInfoView.adjust)),
        ]),
        const SizedBox(height: 4),
        switch (c.trafficView) {
          TrafficInfoView.routes => _routesRow(),
          TrafficInfoView.junctions => _row([
              _hint('Click a junction to switch its lights · click out '
                  'along one of its roads to toggle that stop sign'),
            ]),
          TrafficInfoView.adjust => _adjustRow(),
        },
      ]),
    );
  }

  Widget _routesRow() {
    final c = controller;
    final id = c.selectedRoadId;
    return _row([
      for (final k in TripKind.values) _kindChip(k),
      const SizedBox(width: 8),
      if (!city.roadTraffic.hasRun)
        _hint('Traffic is still being counted — let the colony run a moment')
      else if (id == null)
        _hint('Click a road to see the trips that use it')
      else
        _value('${city.roadNameOf(id)}: ${c.routeCount ?? 0} routes', _text),
    ]);
  }

  Widget _kindChip(TripKind k) {
    final on = controller.routeKinds.contains(k);
    final colour = Color(tripKindArgb(k) | 0xFF000000);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: () => controller.toggleRouteKind(k),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: on ? colour.withValues(alpha: 0.18) : null,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: on ? colour : _edge),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: on ? colour : _faint, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(tripKindLabel(k),
                style: TextStyle(fontSize: 11, color: on ? colour : _dim)),
          ]),
        ),
      ),
    );
  }

  Widget _adjustRow() {
    final c = controller;
    final id = c.selectedRoadId;
    if (id == null) {
      return _row([
        _hint('Click a road to adjust it'),
      ]);
    }
    final move = c.movePreview;
    return _row([
      _RoadNameField(
        key: ValueKey(id),
        initial: city.roadNameOf(id),
        onSubmitted: (v) => c.renameSelected(city, v),
      ),
      const SizedBox(width: 8),
      if (move != null && move.roadId == id)
        ..._moveReadouts(move.quote)
      else
        _hint('Drag an end circle to redraw the road · Enter renames it'),
    ]);
  }

  /// What the end being dragged would cost if it were let go here: the
  /// road's new length, what the re-lay adds (red when the treasury cannot
  /// pay it; nothing for a road made shorter — it is not a refund), its
  /// upkeep, and — amber — why it cannot be.
  List<Widget> _moveReadouts(RoadQuote q) {
    final short = q.refusal == RoadRefusal.funds || q.cost > city.funds;
    return [
      _value('${q.lengthM.round()} m', _text),
      _value(q.cost > 0.5 ? 'Re-lay ${formatMoney(q.cost)}' : 'Re-lay free',
          short ? _bad : _good),
      _value('${_perWeek(q.upkeepPerWeek)} upkeep', _dim),
      if (q.bridgeM > 0.5) _value('Bridge ${q.bridgeM.round()} m', AppTheme.accent),
      if (q.tunnelM > 0.5) _value('Tunnel ${q.tunnelM.round()} m', _under),
      if (!q.ok) _value(q.reason, _warn),
    ];
  }
}

/// The selected road's name, editable. Keyed by the road, so picking
/// another road starts the field again from that road's name.
class _RoadNameField extends StatefulWidget {
  const _RoadNameField(
      {super.key, required this.initial, required this.onSubmitted});

  final String initial;
  final ValueChanged<String> onSubmitted;

  @override
  State<_RoadNameField> createState() => _RoadNameFieldState();
}

class _RoadNameFieldState extends State<_RoadNameField> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial);
  final FocusNode _focus = FocusNode(debugLabel: 'road name');

  @override
  void dispose() {
    _focus.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Enter: the name is done, and the keyboard goes back to the world.
  ///
  /// A field's own Enter hands focus to its ROUTE's scope, which is an
  /// ancestor of the flight view's key node rather than the node — and
  /// keys only bubble up from focus, never down, so from then on PAGE UP,
  /// Esc, WASD, G and Z reached nothing (and beeped, on a Mac) until the
  /// world was clicked. Handed back to the scope's previous focus instead,
  /// they reach the view the moment the name is in.
  void _done() {
    _name.clearComposing();
    _focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 220,
        height: 28,
        child: TextField(
          controller: _name,
          focusNode: _focus,
          onEditingComplete: _done,
          style: const TextStyle(fontSize: 11, color: _text),
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.signpost, size: 14),
            prefixIconConstraints: BoxConstraints(minWidth: 26, minHeight: 26),
            hintText: 'Road name',
            hintStyle: TextStyle(fontSize: 11),
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 6),
          ),
          onSubmitted: widget.onSubmitted,
        ),
      );
}
