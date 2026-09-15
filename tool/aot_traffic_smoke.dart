// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// An AOT smoke run of agent traffic: the dev colony the City Builder
/// founds, its agents on, ticked headless — compiled with
/// `dart compile exe`, because the JIT every test runs in does not compile
/// the traffic code the way the profile and release builds do.
///
/// Why it exists: the readout's first pass read through a null picture in
/// the AOT build only (a flow promotion this SDK's AOT build got wrong;
/// agent_traffic_readout.dart `_lotsStep`), and the City Builder died with
/// a native access violation 25–35 s in while every test passed. A native
/// crash exits this process non-zero; test/traffic/bench/aot_smoke_test.dart
/// compiles and runs it (a bench: `--dart-define=ACRO_BENCH=true`).
///
///     dart compile exe tool/aot_traffic_smoke.dart -o build/aot_smoke.exe
///     build/aot_smoke.exe [ticks]
library;

import 'dart:io';

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';

void main(List<String> args) {
  final ticks = args.isEmpty ? 4000 : int.parse(args.first);
  final c = CityStarterKit.found(
    bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
    config: const CityConfig(
        bodyId: 'earth',
        latitude: -45.03,
        longitude: 168.66,
        biome: Biome.forest),
    start: CityStart.standard,
    id: 'city-dev',
    name: 'Dev Colony',
    agentTraffic: true,
  );
  for (var i = 0; i < ticks; i++) {
    // The empty kit first — the crash was on its first pass — then a zoned
    // town, whose growth, commuters and noise take every other path; and
    // the agents off and on again, which starts their tables afresh.
    if (i == ticks ~/ 4) {
      const uses = [
        ParcelUse.residential,
        ParcelUse.residential,
        ParcelUse.commercial,
        ParcelUse.industrial,
      ];
      var k = 0;
      for (final lot in c.layout.autoParcels.toList()) {
        if (c.parcelBuildings.containsKey(lot.id)) continue;
        c.layout.setUse(lot.id, uses[k++ % uses.length]);
      }
    }
    if (i == ticks ~/ 2) c.agents.enabled = false;
    if (i == ticks ~/ 2 + 40) c.agents.enabled = true;
    c.advance(0.5);
  }
  final r = c.trafficReadout;
  stdout.writeln('aot traffic smoke: $ticks ticks, ${c.agents.stats.spawned} '
      'spawned, ${r.passes} passes, tax x${r.taxLandValueFactor}');
}
