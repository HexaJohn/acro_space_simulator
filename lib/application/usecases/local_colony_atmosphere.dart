// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A one-colony planet for the flat sandbox (docs/plans/terraforming.md,
/// phase-2 open item, built in phase 3).
library;

import '../../domain/colony/city/city_sim.dart';
import '../../domain/planetary/planet_atmosphere.dart';
import '../../domain/planetary/planet_atmosphere_service.dart';
import '../../domain/universe/celestial_body.dart';

/// The planetary-atmosphere phase of the world tick, for ONE colony with no
/// world around it.
///
/// The stand-alone city builder (`CityBuilderScreen(driveLocally: true)`)
/// steps its colony with `CitySim.advance` alone. With no
/// [PlanetAtmosphereService] behind it, its towers vented into nothing:
/// Temp, Press, Water, Habitability and breathability all stood at the
/// reference however many towers ran, while the same colony in the world
/// changed its planet. This is the same service on one inventory, seeded from
/// the colony's reference body and integrated after every step exactly as
/// the tick does — flows recorded against the step's dt, integrated, the body
/// republished to the colony past the same tolerance — so a sandbox Mars
/// moves as the world's Mars would.
///
/// Re-siting the colony to another world (the sandbox's planet picker) seeds
/// that world afresh: the sandbox has one planet at a time, and the old one's
/// air is not kept.
class LocalColonyAtmosphere {
  LocalColonyAtmosphere({this.service = const PlanetAtmosphereService()});

  final PlanetAtmosphereService service;

  PlanetAtmosphere? _state;
  CelestialBody? _reference;
  CelestialBody? _published;

  /// The inventory being integrated, or null for a world with none (a star,
  /// a giant).
  PlanetAtmosphere? get state => _state;

  /// Integrate [city]'s air over the [dt] seconds its last advance covered.
  void step(CitySim city, double dt) {
    final id = city.body.id.value;
    if (_reference?.id.value != id) _seed(city);
    final state = _state;
    final reference = _reference;
    city.planetAir = state;
    if (state == null || reference == null) return;
    // A re-pick of the same world hands the colony the reference body back;
    // it must go on breathing the air this world now has.
    if (!identical(city.body, _published) && _published != null) {
      city.body = state.applyTo(reference);
      _published = city.body;
    }
    if (dt > 0) {
      state.pendingFlows.addColony(
        pollutionRate: city.emissionRate,
        oxygenatorRun: city.oxygenatorRun,
        o2HarvestRate: city.o2HarvestRate,
        towers: city.towerRuns,
        dt: dt,
        colony: city.id,
        colonyName: city.name,
      );
    }
    if (state.isAtRest) return;
    final flows = state.takePendingFlows();
    service.advance(state, flows ?? AtmosphereFlows(), dt: dt);
    if (!state.needsPublish()) return;
    city.body = state.applyTo(reference);
    _published = city.body;
    state.markPublished();
  }

  void _seed(CitySim city) {
    final id = city.body.id;
    CelestialBody? ref;
    for (final b in city.bodies) {
      if (b.id == id) ref = b;
    }
    final reference = ref ?? city.body;
    _reference = reference;
    _published = reference;
    _state = PlanetAtmosphere.seed(reference);
    // A new world: the land is judged afresh against its climate rather
    // than read as having moved from the old one's.
    city.climate.reset();
  }
}
