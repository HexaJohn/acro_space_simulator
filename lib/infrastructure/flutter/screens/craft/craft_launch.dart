// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../domain/craft/craft_design.dart';
import '../../../../domain/dynamics/state_vector.dart';
import '../../../../domain/parts/vessel_assembler.dart';
import '../../../../domain/shared/quaternion.dart';
import '../../../../domain/shared/vector3.dart';
import '../../../../domain/universe/celestial_body.dart';
import '../../../../domain/universe/real_solar_system.dart';
import '../../../../domain/vessel/vessel.dart';
import '../../simulation_view.dart';
import '../app_theme.dart';
import '../craft_assembly_screen.dart';

/// The bridge from a [CraftDesign] to a flying [Vessel]: the bake the editor
/// shows stats for, the bake that spawns on a pad, and the type gate that
/// decides which pads will take it.
///
/// This is the one path out of the editor into the simulation, so it is kept
/// whole and separate from the widgets that call it. `craft_launch_path_test`
/// drives [surfaceCraft] directly — the spawn attitude at the poles is the sort
/// of thing that is trivially testable as a function and untestable through a
/// button.
///
/// Units: metres and radians in the craft body frame (Z-up, nose on +Z);
/// latitude/longitude are DEGREES, as the colony records them.
class CraftLaunch {
  const CraftLaunch._();

  static const VesselAssembler _assembler = VesselAssembler();

  /// The design baked at rest at the origin — what the stats pane reads.
  ///
  /// Null for an empty design rather than an empty vessel: the assembler would
  /// happily hand back a craft with one empty stage and zero mass, and every
  /// readout downstream would then have to decide what "0 kg" means.
  static Vessel? preview(CraftDesign design) {
    if (design.isEmpty) return null;
    return _assembler.assemble(
      id: 'design',
      name: 'Design',
      ownerId: 'player',
      parts: design.parts,
      state: const StateVector(position: Vector3.zero, velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
  }

  /// A winged or jet-powered craft launches like a PLANE (from an airfield);
  /// anything else is a vertical rocket (from a spaceport).
  static bool isPlane(Vessel v) => v.hasWings || v.hasJetEngine;

  /// Does any launch site accept this craft's type?
  static bool canLaunch(Vessel v, List<LaunchSite> sites) {
    final plane = isPlane(v);
    return sites.any((s) => s.acceptsPlane == plane);
  }

  /// Re-assemble the design ON the host body's surface at the colony's lat/long,
  /// at rest, nose radially out (up). The real 3D sim then flies the actual
  /// designed craft (with its real stages, so STAGE/decouple works).
  ///
  /// The two degenerate branches are load-bearing, not defensive: at the poles
  /// the outward normal is parallel to the craft's own +Z, and
  /// `unitZ.cross(outward)` is then the zero vector — normalising it would
  /// produce a NaN attitude and the craft would vanish from the world on the
  /// first integration step.
  static Vessel surfaceCraft({
    required CraftDesign design,
    String? bodyId,
    double latitude = 0,
    double longitude = 0,
  }) {
    final body = RealSolarSystem.build().require(BodyId(bodyId ?? 'earth'));
    final lat = latitude * math.pi / 180;
    final lon = longitude * math.pi / 180;
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
      parts: design.parts,
      state: StateVector(
        position: outward * body.radius,
        velocity: Vector3.zero,
        attitude: att,
      ),
      dominantBody: body.id,
      landed: true, // sits on the pad until the player throttles up
    );
  }
}

/// Launch bar: shows the detected craft type + a type-gated LAUNCH button.
///
/// Three things can stop a launch, and the bar says which: the colony has no
/// pad of the right kind, the craft is in pieces, or there is no craft. The
/// button being grey with no sentence beside it is the failure this widget
/// exists to prevent.
class CraftLaunchBar extends StatelessWidget {
  const CraftLaunchBar({
    super.key,
    required this.design,
    required this.vessel,
    required this.launchSites,
    this.bodyId,
    this.latitude = 0,
    this.longitude = 0,
    this.loosePartCount = 0,
    this.onLaunched,
  });

  /// The design that will be re-baked on the pad. Read at press time, not at
  /// build time, so the craft that flies is the craft on screen.
  final CraftDesign design;

  /// The at-rest bake the type gate reads. Supplied rather than derived so the
  /// pane and the bar cannot disagree about what the craft is.
  final Vessel vessel;

  final List<LaunchSite> launchSites;

  final String? bodyId;
  final double latitude, longitude;

  /// Unattached branches on the craft — `CraftEditorController.looseParts`
  /// length. Any at all disables LAUNCH: the whole design bakes into ONE rigid
  /// body, so a branch bolted to nothing still contributes its mass and inertia
  /// to a vehicle it is not structurally part of, and the craft flies wrong in
  /// a way nothing on the pad explains.
  final int loosePartCount;

  /// Called immediately before the sim route is pushed — the hook an autosave
  /// hangs off, so a craft is never lost by flying it.
  final VoidCallback? onLaunched;

  @override
  Widget build(BuildContext context) {
    final plane = CraftLaunch.isPlane(vessel);
    final compatible = CraftLaunch.canLaunch(vessel, launchSites);
    final needs = plane ? 'an airfield' : 'a spaceport';
    final loose = loosePartCount > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: AppTheme.bg,
      child: Row(
        children: [
          Icon(plane ? Icons.flight : Icons.rocket_launch,
              size: 18, color: loose ? AppTheme.danger : AppTheme.accent2),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              loose
                  // The player sees pieces, not attachment records: the craft
                  // plus each unattached branch.
                  ? 'Craft is in ${loosePartCount + 1} pieces — attach or delete '
                      'the loose parts.'
                  : compatible
                      ? '${plane ? "Spaceplane" : "Rocket"} · launches from $needs'
                      : 'No $needs at this colony to launch a ${plane ? "spaceplane" : "rocket"}.',
              style: loose
                  ? AppTheme.dim.copyWith(color: AppTheme.danger)
                  : AppTheme.dim,
            ),
          ),
          ElevatedButton.icon(
            onPressed:
                compatible && !loose ? () => _launch(context, vessel) : null,
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

  void _launch(BuildContext context, Vessel v) {
    final plane = CraftLaunch.isPlane(v);
    final sites = launchSites.where((s) => s.acceptsPlane == plane).toList();
    if (sites.isEmpty) return;
    void go(LaunchSite _) {
      onLaunched?.call();
      // Fly the actual designed craft in the real 3D sim, spawned on the host
      // world's surface at the colony's lat/long.
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SimulationView(
          injectedVessel: CraftLaunch.surfaceCraft(
            design: design,
            bodyId: bodyId,
            latitude: latitude,
            longitude: longitude,
          ),
        ),
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
}
