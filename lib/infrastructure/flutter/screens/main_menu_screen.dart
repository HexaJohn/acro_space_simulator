// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/material.dart';

import '../../../domain/universe/celestial_body.dart';
import '../../../domain/universe/real_solar_system.dart';
import '../../flutter_scene/render_backend.dart';
import '../../flutter_scene/vessel_nodes.dart';
import '../../sample_world.dart';
import '../simulation_view.dart';
import 'app_theme.dart';
import 'ascent_screen.dart';
import 'craft_assembly_screen.dart';
import 'city_builder_screen.dart';
import 'cloudscape_screen.dart';
import 'building_studio_screen.dart';
import 'city_studio_screen.dart';
import 'maneuver_planner_screen.dart';
import 'megastructure_screen.dart';
import 'mining_screen.dart';
import 'multiplayer_screen.dart';
import 'options_screen.dart';
import 'scatter_lab_screen.dart';

/// Top-level menu. The composition root's [home]; routes to the live sim and to
/// every feature screen so each implemented system has a place in the UI.
class MainMenuScreen extends StatelessWidget {
  const MainMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // A mesh bake costs ~a minute of parse + KTX2 transcode in a debug build;
    // start them while the player reads the menu so entering a flight only
    // realizes node graphs from the warm cache. Just the two whole-craft
    // models — every flight reachable from HERE (FLIGHT, ASCENT) spawns a
    // hand-built sample craft, which draws one of them. The part bakes belong
    // to craft built in CRAFT ASSEMBLY, and that screen warms them itself on
    // open; see [VesselNodes.prewarm] for why the menu must not queue them too.
    // After the first frame, so the menu paints before the loads contend for
    // the UI thread. Idempotent.
    WidgetsBinding.instance.addPostFrameCallback((_) => VesselNodes.prewarm());
    final items = <_MenuItem>[
      _MenuItem('FLIGHT', 'Launch the live solar-system simulation', Icons.rocket_launch,
          AppTheme.accent2, (c) => SimulationView(
                // The Apollo CSM (service module) + Lunar Module in a low lunar
                // orbit on the Moon's DAYLIGHT side, loose formation. No demo
                // orbiter — the scene is exactly these two craft. Boots the
                // flutter_scene backend so the baked glb models render.
                initialBackend: RenderBackend.flutterScene,
                spawnDemoOrbiter: false,
                injectedVessel: SampleWorld.buildLunarOrbiter(
                    id: 'moon-lander', name: 'Lunar Module'),
                trafficVessels: [
                  // Same orbit, ~14 m ahead — almost touching, no drift.
                  SampleWorld.buildLunarOrbiter(
                      id: 'csm', name: 'Service Module', alongTrackM: 14),
                ],
              )),
      _MenuItem('CRAFT ASSEMBLY', 'Build a vessel from the part catalog',
          Icons.precision_manufacturing, AppTheme.accent,
          (c) => const CraftAssemblyScreen()),
      _MenuItem('MANEUVER PLANNER', 'Plan transfers, circularization, plane changes',
          Icons.timeline, AppTheme.accent, (c) => const ManeuverPlannerScreen()),
      _MenuItem('LANDING', 'Descent + touchdown guidance over a colony', Icons.flight_land,
          AppTheme.warn, (c) => const AscentScreen(descent: true)),
      _MenuItem('ASCENT', 'Launch to orbit in the 3D sim — staged, real planet',
          Icons.rocket, AppTheme.accent2, (c) => SimulationView(
              injectedVessel: SampleWorld.buildSurfaceCraft(
                  RealSolarSystem.build().require(const BodyId('earth')),
                  name: 'Ascent Vehicle'))),
      _MenuItem('MINING', 'Survey deposits + run extraction', Icons.diamond,
          AppTheme.accent, (c) => const MiningScreen()),
      _MenuItem('CITY BUILDER', 'Found a colony: pick world, politics + difficulty',
          Icons.location_city, AppTheme.accent2, (c) => const NewCityScreen()),
      _MenuItem('MEGASTRUCTURES', 'Direct planet-to-stellar-scale construction',
          Icons.hub, AppTheme.accent, (c) => const MegastructureScreen()),
      _MenuItem('MULTIPLAYER', 'Sessions, players, command authority',
          Icons.groups, AppTheme.accent, (c) => const MultiplayerScreen()),
      _MenuItem('CITY STUDIO', 'Generate whole colonies to profile + tune',
          Icons.grid_view, AppTheme.accent2, (c) => const CityStudioScreen()),
      _MenuItem('BUILDING STUDIO', 'One block face: buildings, lots, frontage',
          Icons.apartment, AppTheme.accent2,
          (c) => const BuildingStudioScreen()),
      _MenuItem('SCATTER LAB', 'Preview procedural trees, plants + rocks',
          Icons.park, AppTheme.accent2, (c) => const ScatterLabScreen()),
      _MenuItem('CLOUDSCAPE', 'Tune the volumetric cloud decks per planet',
          Icons.cloud, AppTheme.accent2, (c) => const CloudscapeScreen()),
      _MenuItem('OPTIONS', 'Graphics, simulation, controls', Icons.settings,
          AppTheme.textDim, (c) => const OptionsScreen()),
    ];

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                const SizedBox(height: 28),
                const Text('ACRO SPACE SIMULATOR', style: AppTheme.title),
                const SizedBox(height: 4),
                const Text('mission control', style: AppTheme.dim),
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0x3300FF7F),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(kBuildStamp,
                      style: AppTheme.mono.copyWith(
                          color: AppTheme.accent2, fontSize: 11)),
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: LayoutBuilder(builder: (context, c) {
                      final cols = c.maxWidth > 540 ? 2 : 1;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final it in items)
                            SizedBox(
                              width: cols == 2
                                  ? (c.maxWidth - 12) / 2
                                  : c.maxWidth,
                              child: _MenuCard(item: it),
                            ),
                        ],
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuItem {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Widget Function(BuildContext) build;
  const _MenuItem(
      this.title, this.subtitle, this.icon, this.color, this.build);
}

class _MenuCard extends StatelessWidget {
  final _MenuItem item;
  const _MenuCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.panel,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: item.build),
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: item.color.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: item.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(item.icon, color: item.color, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title,
                        style: AppTheme.heading.copyWith(color: item.color)),
                    const SizedBox(height: 3),
                    Text(item.subtitle, style: AppTheme.dim),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppTheme.textDim),
            ],
          ),
        ),
      ),
    );
  }
}
