// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/climate_biome.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/planetary/surface_conditions.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The land follows the climate (docs/plans/terraforming.md §5.5, phase 3):
/// a colony's biome turns when its world's derived sky crosses a band, with
/// hysteresis, deterministically — and never on a world nothing has
/// changed, so a colony keeps the biome it was founded with.
void main() {
  final system = RealSolarSystem.build();
  final bodies = system.all.where((b) => !b.isStar).toList();
  CelestialBody body(String id) => system.require(BodyId(id));
  const atm = 101325.0;

  SurfaceConditions sky({
    double t = 288,
    double p = 1,
    double humidity = 0.1,
  }) =>
      SurfaceConditions(
        temperatureK: t,
        pressureAtm: p,
        waterActivity: 0.5,
        o2Fraction: 0.2,
        toxicFraction: 0,
        insolation: 1,
        gravityG: 1,
        radiation: 0,
        airDensity: p,
        surfaceMoisture: 0.5,
        humidity: humidity,
        floraPotential: 1,
      );

  group('bands', () {
    test('the reference worlds sit where they should', () {
      ClimateBand of(String id) =>
          ClimateBiome.classify(SurfaceConditions.of(body(id)));
      expect(of('earth'), ClimateBand.temperateWet);
      expect(of('mars'), ClimateBand.airless);
      expect(of('moon'), ClimateBand.airless);
      expect(of('venus'), ClimateBand.scorching);
      expect(of('titan'), ClimateBand.frozen);
    });

    test('a band is hard to leave: hysteresis on every edge', () {
      ClimateBand from(ClimateBand c, SurfaceConditions s) =>
          ClimateBiome.classify(s, current: c);
      // Frozen ↔ temperate about 268 K.
      expect(from(ClimateBand.frozen, sky(t: 270)), ClimateBand.frozen);
      expect(from(ClimateBand.frozen, sky(t: 274)), ClimateBand.temperateWet);
      expect(from(ClimateBand.temperateWet, sky(t: 265)),
          ClimateBand.temperateWet);
      expect(from(ClimateBand.temperateWet, sky(t: 262)), ClimateBand.frozen);
      // Temperate ↔ scorching about 330 K.
      expect(from(ClimateBand.temperateWet, sky(t: 333)),
          ClimateBand.temperateWet);
      expect(from(ClimateBand.temperateWet, sky(t: 336)),
          ClimateBand.scorching);
      expect(from(ClimateBand.scorching, sky(t: 327)), ClimateBand.scorching);
      // Airless about the Armstrong limit.
      expect(from(ClimateBand.airless, sky(p: 0.07)), ClimateBand.airless);
      expect(from(ClimateBand.airless, sky(p: 0.09)), ClimateBand.temperateWet);
      expect(from(ClimateBand.temperateWet, sky(p: 0.055)),
          ClimateBand.temperateWet);
      expect(from(ClimateBand.temperateWet, sky(p: 0.045)), ClimateBand.airless);
      // Wet ↔ dry about 5% humidity.
      expect(from(ClimateBand.temperateWet, sky(humidity: 0.045)),
          ClimateBand.temperateWet);
      expect(from(ClimateBand.temperateWet, sky(humidity: 0.035)),
          ClimateBand.temperateDry);
      expect(from(ClimateBand.temperateDry, sky(humidity: 0.055)),
          ClimateBand.temperateDry);
    });

    test('a world sitting on a line cannot flicker', () {
      final c = ClimateBiome();
      var biome = Biome.barren;
      // Record frozen, then warm across the line once.
      c.update(onBody: 'x', sky: sky(t: 250), biome: biome);
      biome = c.update(onBody: 'x', sky: sky(t: 280), biome: biome) ?? biome;
      expect(biome, Biome.grassland);
      // Then wobble ±3 K about the 268 K line for a long while.
      var turns = 0;
      for (var i = 0; i < 1000; i++) {
        final t = 268 + (i.isEven ? 3.0 : -3.0);
        final next = c.update(onBody: 'x', sky: sky(t: t), biome: biome);
        if (next != null) {
          turns++;
          biome = next;
        }
      }
      expect(turns, 0);
      expect(biome, Biome.grassland);
    });

    test('the first judgement only records, and a new world starts over', () {
      final c = ClimateBiome();
      expect(c.update(onBody: 'mars', sky: sky(p: 0.001), biome: Biome.barren),
          isNull);
      expect(c.band, ClimateBand.airless);
      // Re-sited to Earth: recorded afresh, not read as Mars greening.
      expect(c.update(onBody: 'earth', sky: sky(), biome: Biome.barren),
          isNull);
      expect(c.band, ClimateBand.temperateWet);
      expect(c.bodyId, 'earth');
    });

    test('mountains and lava lakes are geology', () {
      for (final b in ClimateBand.values) {
        expect(ClimateBiome.transition(Biome.mountains, b), Biome.mountains);
        expect(ClimateBiome.transition(Biome.volcano, b), Biome.volcano);
      }
      // The old slider's three, now earned.
      for (final b in [Biome.barren, Biome.desert, Biome.volcanic]) {
        expect(ClimateBiome.transition(b, ClimateBand.temperateWet),
            Biome.grassland);
      }
    });

    test('saved and restored; anything unknown loads unjudged', () {
      final c = ClimateBiome()
        ..update(onBody: 'mars', sky: sky(t: 250), biome: Biome.barren);
      final d = ClimateBiome()..restore(c.toJson());
      expect(d.band, ClimateBand.frozen);
      expect(d.bodyId, 'mars');
      expect((ClimateBiome()..restore({'band': 'boiling', 'body': 'x'})).band,
          isNull);
      expect((ClimateBiome()..restore(null)).band, isNull);
    });
  });

  group('in a colony', () {
    CitySim found(String bodyId, Biome biome) => CitySim.found(
          CityConfig(bodyId: bodyId, gridSize: 16, biome: biome),
          bodies: bodies,
        );

    test('an untouched Earth never changes any colony\'s biome', () {
      for (final b in Biome.values) {
        final city = found('earth', b);
        for (var i = 0; i < 40; i++) {
          city.advance(0.5);
        }
        expect(city.biome, b, reason: b.name);
        expect(city.climate.band, ClimateBand.temperateWet);
      }
    });

    /// Mars with [pO2Atm] of oxygen, water vapour to [h2oFraction], and
    /// enough agent for [tempK].
    CelestialBody warmMars(double tempK,
        {double pO2Atm = 0.3, double h2oFraction = 0.02}) {
      final a = PlanetAtmosphere.seed(body('mars'))!;
      a.add(
          AtmosphereGas.oxygen,
          a.molesForPartialPressure(
                  a.moles, AtmosphereGas.oxygen, pO2Atm * atm) -
              a.molesOf(AtmosphereGas.oxygen));
      a.add(AtmosphereGas.water, a.totalMoles * h2oFraction);
      a.greenhouseAgentMoles = 0;
      a.greenhouseAgentMoles = a.agentMolesForTemperature(tempK);
      return a.applyTo(body('mars'));
    }

    test('a warming Mars greens a barren colony — once — and freezes back',
        () {
      final city = found('mars', Biome.barren);
      city.advance(0.5);
      expect(city.climate.band, ClimateBand.airless);
      expect(city.biome, Biome.barren);

      city.body = warmMars(285);
      expect(city.sky.temperatureK, closeTo(285, 0.5));
      city.advance(0.5);
      expect(city.biome, Biome.grassland, reason: 'warm, thick, wet air');

      // Cooled to just under the liquid line: inside the margin, no change.
      city.body = warmMars(265);
      for (var i = 0; i < 10; i++) {
        city.advance(0.5);
      }
      expect(city.biome, Biome.grassland);

      // Well under it: the grass freezes to tundra.
      city.body = warmMars(255);
      city.advance(0.5);
      expect(city.biome, Biome.tundra);
    });

    test('the band and biome survive a save', () {
      final city = found('mars', Biome.barren)..advance(0.5);
      city.body = warmMars(285);
      city.advance(0.5);
      expect(city.biome, Biome.grassland);
      final back = CitySim.fromJson(city.toJson(), bodies: bodies);
      expect(back.biome, Biome.grassland);
      expect(back.climate.band, city.climate.band);
      expect(back.climate.bodyId, 'mars');
    });
  });
}
