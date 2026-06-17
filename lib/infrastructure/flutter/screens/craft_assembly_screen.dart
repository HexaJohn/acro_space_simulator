import 'package:flutter/material.dart';

import 'dart:math' as math;

import '../../../domain/dynamics/state_vector.dart';
import '../../../domain/parts/part_catalog.dart';
import '../../../domain/parts/part_def.dart';
import '../../../domain/parts/vessel_assembler.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/universe/celestial_body.dart';
import '../../../domain/universe/real_solar_system.dart';
import '../../../domain/vessel/vessel.dart';
import '../simulation_view.dart';
import 'app_theme.dart';

/// A place a craft can launch from, surfaced to the VAB so the player can build
/// then launch from a colony's pad/runway. [acceptsPlane] true = an airfield
/// (winged/jet craft); false = a spaceport (vertical rockets).
class LaunchSite {
  final String name;
  final bool acceptsPlane;

  /// Launch towers / pads at this site (its footprint tile count) — shown as
  /// pads across the bottom of the ascent view.
  final int pads;
  const LaunchSite(
      {required this.name, required this.acceptsPlane, this.pads = 1});
}

/// Craft assembly: pick parts from the [PartCatalog], stack them, and watch the
/// [VesselAssembler] bake them into a real [Vessel] live (mass, Δv, thrust, crew,
/// drag). Parts stack vertically (+Z); each gets its own staging group in order.
///
/// When opened from a colony with [launchSites], a LAUNCH action lets the player
/// fly the finished design from a compatible pad/runway (gated by craft type:
/// winged/jet -> airfield, otherwise -> spaceport).
class CraftAssemblyScreen extends StatefulWidget {
  /// World to launch from (defaults to Earth in the standalone VAB).
  final String? bodyId;

  /// Launch sites offered by the calling colony. Empty = standalone VAB (no
  /// launch action; design-only).
  final List<LaunchSite> launchSites;

  /// Colony site on the host body (degrees) — where the craft spawns to launch.
  final double latitude, longitude;

  const CraftAssemblyScreen({
    super.key,
    this.bodyId,
    this.launchSites = const [],
    this.latitude = 0,
    this.longitude = 0,
  });

  @override
  State<CraftAssemblyScreen> createState() => _CraftAssemblyScreenState();
}

class _CraftAssemblyScreenState extends State<CraftAssemblyScreen> {
  final _catalog = PartCatalog.standard();
  static const _assembler = VesselAssembler();
  final List<PlacedPart> _placed = [];
  int _nextId = 0;
  PartCategory _filter = PartCategory.commandPod;

  void _add(PartDef def) {
    setState(() {
      // Stack along +Z: each new part sits above the last by its half-heights.
      final z = _placed.fold(0.0, (s, p) => s + p.def.size.z) + def.size.z / 2;
      _placed.add(PlacedPart(
        def: def,
        instanceId: '${def.id}-${_nextId++}',
        position: Vector3(0, 0, z),
        stage: _placed.length,
      ));
    });
  }

  void _remove(int i) => setState(() => _placed.removeAt(i));

  Vessel? get _vessel {
    if (_placed.isEmpty) return null;
    return _assembler.assemble(
      id: 'design',
      name: 'Design',
      ownerId: 'player',
      parts: _placed,
      state: const StateVector(position: Vector3.zero, velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
  }

  /// A winged or jet-powered craft launches like a PLANE (from an airfield);
  /// anything else is a vertical rocket (from a spaceport).
  bool _isPlane(Vessel v) => v.hasWings || v.hasJetEngine;

  /// Does any launch site accept this craft's type?
  bool _canLaunch(Vessel v) {
    final plane = _isPlane(v);
    return widget.launchSites.any((s) => s.acceptsPlane == plane);
  }

  /// Re-assemble the design ON the host body's surface at the colony's lat/long,
  /// at rest, nose radially out (up). The real 3D sim then flies the actual
  /// designed craft (with its real stages, so STAGE/decouple works).
  Vessel _surfaceCraft() {
    final body =
        RealSolarSystem.build().require(BodyId(widget.bodyId ?? 'earth'));
    final lat = widget.latitude * math.pi / 180;
    final lon = widget.longitude * math.pi / 180;
    final outward = Vector3(
      math.cos(lat) * math.cos(lon),
      math.cos(lat) * math.sin(lon),
      math.sin(lat),
    ).normalized;
    final dot = Vector3.unitZ.dot(outward).clamp(-1.0, 1.0);
    final Quaternion att;
    if (dot > 0.99999) {
      att = Quaternion.identity;
    } else if (dot < -0.99999) {
      att = Quaternion.axisAngle(Vector3.unitX, math.pi);
    } else {
      att = Quaternion.axisAngle(
          Vector3.unitZ.cross(outward).normalized, math.acos(dot));
    }
    return _assembler.assemble(
      id: 'vab-craft',
      name: 'Design',
      ownerId: 'player',
      parts: _placed,
      state: StateVector(
        position: outward * body.radius,
        velocity: Vector3.zero,
        attitude: att,
      ),
      dominantBody: body.id,
      landed: true, // sits on the pad until the player throttles up
    );
  }

  void _launch(Vessel v) {
    final plane = _isPlane(v);
    final sites =
        widget.launchSites.where((s) => s.acceptsPlane == plane).toList();
    if (sites.isEmpty) return;
    void go(LaunchSite _) {
      // Fly the actual designed craft in the real 3D sim, spawned on the host
      // world's surface at the colony's lat/long.
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SimulationView(injectedVessel: _surfaceCraft()),
      ));
    }

    if (sites.length == 1) {
      go(sites.first);
      return;
    }
    // Multiple compatible sites: let the player pick.
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.panel,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(plane ? 'Choose an airfield' : 'Choose a spaceport',
                  style: AppTheme.heading),
            ),
            for (final s in sites)
              ListTile(
                leading: Icon(plane ? Icons.flight : Icons.rocket_launch,
                    color: AppTheme.accent2),
                title: Text(s.name, style: AppTheme.body),
                onTap: () {
                  Navigator.of(context).pop();
                  go(s);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = _vessel;
    return AppTheme.scaffold(
      context: context,
      title: 'CRAFT ASSEMBLY',
      actions: [
        if (_placed.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.delete_sweep, color: AppTheme.danger),
            tooltip: 'Clear',
            onPressed: () => setState(_placed.clear),
          ),
      ],
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 720;
        final catalog = _catalogPane();
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: catalog),
              const VerticalDivider(width: 1, color: Color(0xFF223247)),
              Expanded(flex: 4, child: _designPane(v)),
            ],
          );
        }
        // Narrow (mobile): NO outer page scroll. A bounded Column splits the
        // viewport between the catalog (top) and the design pane (bottom), each
        // of which scrolls internally and sizes to fit — so nothing runs off the
        // bottom of the screen.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 5, child: catalog),
            const Divider(height: 1, color: Color(0xFF223247)),
            Expanded(flex: 4, child: _designPane(v)),
          ],
        );
      }),
    );
  }

  Widget _catalogPane() {
    final cats = PartCategory.values
        .where((c) => _catalog.inCategory(c).isNotEmpty)
        .toList();
    final parts = _catalog.inCategory(_filter).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final cat in cats)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(_catLabel(cat),
                          style: TextStyle(
                              fontSize: 11,
                              color: _filter == cat
                                  ? AppTheme.bg
                                  : AppTheme.text)),
                      selected: _filter == cat,
                      selectedColor: AppTheme.accent,
                      backgroundColor: AppTheme.panelLight,
                      onSelected: (_) => setState(() => _filter = cat),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: parts.length,
            itemBuilder: (_, i) => _catalogRow(parts[i]),
          ),
        ),
      ],
    );
  }

  Widget _catalogRow(PartDef def) => Card(
        color: AppTheme.panel,
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          dense: true,
          leading: Icon(_catIcon(def.category), color: AppTheme.accent),
          title: Text(def.name, style: AppTheme.body),
          subtitle: Text(_partSummary(def), style: AppTheme.dim),
          trailing: IconButton(
            icon: const Icon(Icons.add_circle, color: AppTheme.accent2),
            onPressed: () => _add(def),
          ),
        ),
      );

  Widget _designPane(Vessel? v) {
    // The placed-parts list FILLS the remaining pane height (Expanded) and
    // scrolls internally — the pane lives in a bounded Column in both the wide
    // and narrow layouts, so nothing overflows the screen.
    final list = _placed.isEmpty
        ? const SizedBox()
        : ReorderableListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: _placed.length,
            onReorder: (a, b) => setState(() {
              if (b > a) b -= 1;
              final p = _placed.removeAt(a);
              _placed.insert(b, p);
            }),
            itemBuilder: (_, i) {
              final p = _placed[i];
              return Card(
                key: ValueKey(p.instanceId),
                color: AppTheme.panelLight,
                margin: const EdgeInsets.symmetric(vertical: 3),
                child: ListTile(
                  dense: true,
                  leading: Text('S${p.stage}',
                      style: AppTheme.mono.copyWith(color: AppTheme.warn)),
                  title: Text(p.def.name, style: AppTheme.body),
                  trailing: IconButton(
                    icon: const Icon(Icons.remove_circle_outline,
                        color: AppTheme.danger, size: 20),
                    onPressed: () => _remove(i),
                  ),
                ),
              );
            },
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          color: AppTheme.panel,
          child: v == null
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('Add parts to begin.',
                      textAlign: TextAlign.center, style: AppTheme.dim),
                )
              : _stats(v),
        ),
        if (v != null && widget.launchSites.isNotEmpty) _launchBar(v),
        Expanded(child: list),
      ],
    );
  }

  /// Launch bar: shows the detected craft type + a type-gated LAUNCH button.
  Widget _launchBar(Vessel v) {
    final plane = _isPlane(v);
    final canLaunch = _canLaunch(v);
    final needs = plane ? 'an airfield' : 'a spaceport';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: AppTheme.bg,
      child: Row(
        children: [
          Icon(plane ? Icons.flight : Icons.rocket_launch,
              size: 18, color: AppTheme.accent2),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              canLaunch
                  ? '${plane ? "Spaceplane" : "Rocket"} · launches from $needs'
                  : 'No $needs at this colony to launch a ${plane ? "spaceplane" : "rocket"}.',
              style: AppTheme.dim,
            ),
          ),
          ElevatedButton.icon(
            onPressed: canLaunch ? () => _launch(v) : null,
            icon: const Icon(Icons.flight_takeoff, size: 18),
            label: const Text('LAUNCH'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent2,
              foregroundColor: AppTheme.bg,
              disabledBackgroundColor: AppTheme.panelLight,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stats(Vessel v) {
    final dv = v.deltaVCapacity();
    final crew = v.crew?.count ?? 0;
    final partCount = v.allParts.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('VESSEL STATS', style: AppTheme.heading),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 8, children: [
          _stat('Mass', '${(v.mass / 1000).toStringAsFixed(2)} t'),
          _stat('Δv', '${dv.toStringAsFixed(0)} m/s', AppTheme.accent2),
          _stat('Parts', '$partCount'),
          _stat('Stages', '${v.stages.length}'),
          _stat('Crew', '$crew'),
          _stat('Wing area', '${v.totalWingArea.toStringAsFixed(1)} m²'),
        ]),
      ],
    );
  }

  Widget _stat(String label, String value, [Color? color]) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF223247)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppTheme.dim),
            Text(value,
                style: AppTheme.mono
                    .copyWith(color: color ?? AppTheme.text, fontSize: 14)),
          ],
        ),
      );

  String _partSummary(PartDef def) {
    final bits = <String>['${(def.dryMass).toStringAsFixed(0)} kg'];
    if (def.rocketEngine != null) {
      bits.add('${(def.rocketEngine!.maxThrustVacuum / 1000).toStringAsFixed(0)} kN');
    }
    if (def.jetEngine != null) {
      bits.add('${(def.jetEngine!.maxStaticThrust / 1000).toStringAsFixed(0)} kN jet');
    }
    if (def.crewCapacity > 0) bits.add('${def.crewCapacity} crew');
    if (def.resources.isNotEmpty) {
      final fuel = def.resources.fold(0.0, (s, r) => s + r.capacity);
      bits.add('${fuel.toStringAsFixed(0)} fuel');
    }
    if (def.wing != null) bits.add('wing ${def.wing!.area.toStringAsFixed(0)} m²');
    return bits.join('  ·  ');
  }

  String _catLabel(PartCategory c) => switch (c) {
        PartCategory.commandPod => 'Command',
        PartCategory.fuelTank => 'Fuel',
        PartCategory.rocketEngine => 'Rocket',
        PartCategory.jetEngine => 'Jet',
        PartCategory.intake => 'Intake',
        PartCategory.wing => 'Wing',
        PartCategory.controlSurface => 'Control',
        PartCategory.structural => 'Struct',
        PartCategory.decoupler => 'Decoupler',
        PartCategory.landingGear => 'Gear',
        PartCategory.parachute => 'Chute',
        PartCategory.science => 'Science',
        PartCategory.rcsThruster => 'RCS',
        PartCategory.heatShield => 'Heat',
      };

  IconData _catIcon(PartCategory c) => switch (c) {
        PartCategory.commandPod => Icons.airline_seat_recline_normal,
        PartCategory.fuelTank => Icons.local_gas_station,
        PartCategory.rocketEngine => Icons.local_fire_department,
        PartCategory.jetEngine => Icons.air,
        PartCategory.intake => Icons.input,
        PartCategory.wing => Icons.flight,
        PartCategory.controlSurface => Icons.tune,
        PartCategory.structural => Icons.view_in_ar,
        PartCategory.decoupler => Icons.unfold_more,
        PartCategory.landingGear => Icons.airline_seat_legroom_extra,
        PartCategory.parachute => Icons.paragliding,
        PartCategory.science => Icons.science,
        PartCategory.rcsThruster => Icons.control_camera,
        PartCategory.heatShield => Icons.shield,
      };
}
