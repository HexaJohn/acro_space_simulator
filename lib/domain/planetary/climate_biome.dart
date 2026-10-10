// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The land follows the climate (docs/plans/terraforming.md §5.5, phase 3).
///
/// The old rule was a slider: run Terraforming Towers until a meter read
/// 100% and a barren, desert or volcanic colony turned to grassland — on a
/// Mars whose air had not moved at all. The air is real now, so the land can
/// answer to IT: a colony's biome is re-derived when its world's derived
/// temperature, pressure and humidity cross the same bands
/// [SurfaceConditions] already uses for habitability and flora (the
/// Armstrong limit, the liquid-water band, the scorching line, wet air).
///
/// Three rules make it safe to run every tick:
///  * **Only a CHANGE of band moves the biome.** The band the colony was
///    founded (or loaded, or re-sited) under is recorded, never judged: a
///    desert founded on Earth is a desert on a temperate, humid world, and
///    stays one. An untouched world never changes band, so its colonies keep
///    their founding biome exactly.
///  * **Hysteresis.** Leaving a band takes crossing its edge by a margin, so
///    a world sitting on a line — a Mars warmed to 268 K, a sky at the
///    Armstrong limit — cannot flicker between two biomes.
///  * **Determinism.** A pure function of the sky and the recorded band; no
///    clock, no randomness. The band is saved with the colony.
library;

import 'planet_surface.dart';
import 'surface_conditions.dart';

/// A climate band: the coarse state of a world's surface air that decides
/// what can grow on it.
enum ClimateBand {
  /// Below the Armstrong limit: nothing living stands in the open.
  airless,

  /// Air, but colder than liquid water.
  frozen,

  /// Liquid-water temperatures under dry air.
  temperateDry,

  /// Liquid-water temperatures under humid air.
  temperateWet,

  /// Hotter than anything grows in.
  scorching,
}

/// Where a colony's land stands against its world's climate. Mutable state,
/// saved.
class ClimateBiome {
  ClimateBiome();

  /// Pressure (atm) under which the land counts as airless: the Armstrong
  /// limit [SurfaceConditions.armstrongAtm].
  static const double airlessAtm = SurfaceConditions.armstrongAtm;

  /// Coldest liquid-water temperature (K) — [SurfaceConditions]' liquid band.
  static const double frozenK = 268;

  /// Where it is too hot to grow (K) — the 'Scorching' line of
  /// [SurfaceConditions.summary].
  static const double scorchingK = 330;

  /// Humidity above which the air is wet enough to green the land.
  static const double wetHumidity = 0.05;

  /// Margins a band's edge must be crossed by before the colony leaves it.
  static const double temperatureMarginK = 5;
  static const double pressureMargin = 0.25; // ×(1 ± this) on the limit
  static const double humidityMargin = 0.01;

  /// The band the colony's land is in, or null before it has been judged.
  ClimateBand? band;

  /// The world [band] was judged on. A colony re-sited to another world
  /// starts again there, unjudged, rather than reading the move as a change
  /// of climate — the sandbox's planet picker would otherwise turn a desert
  /// the player chose into whatever the jump from Mars to Earth implies.
  String? bodyId;

  /// The band [sky] puts a colony in, given the band it is [current]ly in
  /// (null: no history, judge on the plain lines).
  static ClimateBand classify(SurfaceConditions sky, {ClimateBand? current}) {
    bool was(ClimateBand b) => current == b;
    // Airless: hard to leave, hard to enter.
    final airLine = current == null
        ? airlessAtm
        : was(ClimateBand.airless)
            ? airlessAtm * (1 + pressureMargin)
            : airlessAtm * (1 - pressureMargin);
    if (sky.pressureAtm < airLine) return ClimateBand.airless;

    final t = sky.temperatureK;
    final temperate =
        was(ClimateBand.temperateDry) || was(ClimateBand.temperateWet);
    final frozenLine = was(ClimateBand.frozen)
        ? frozenK + temperatureMarginK
        : temperate
            ? frozenK - temperatureMarginK
            : frozenK;
    if (t < frozenLine) return ClimateBand.frozen;
    final scorchLine = was(ClimateBand.scorching)
        ? scorchingK - temperatureMarginK
        : temperate
            ? scorchingK + temperatureMarginK
            : scorchingK;
    if (t > scorchLine) return ClimateBand.scorching;

    // Inside the frost margin the air's humidity reads nothing — it counts
    // only liquid-band vapour — so a temperate world dipping a few kelvin
    // under the line would read "dry" and bake its grass to desert on the
    // way to freezing it. It keeps its wetness until it really freezes.
    if (temperate && t < frozenK && current != null) return current;

    final wetLine = was(ClimateBand.temperateWet)
        ? wetHumidity - humidityMargin
        : was(ClimateBand.temperateDry)
            ? wetHumidity + humidityMargin
            : wetHumidity;
    return sky.humidity >= wetLine
        ? ClimateBand.temperateWet
        : ClimateBand.temperateDry;
  }

  /// What [biome] becomes when its world's climate moves into [to].
  ///
  /// Each entry is what that land does under the new climate: grass where
  /// a dead or dry land gets warm, wet air (the old slider's barren / desert
  /// / volcanic → grassland, now earned); tundra where living land freezes;
  /// rock where the air goes; desert where it bakes. Mountains and lava
  /// lakes are geology and never change.
  static Biome transition(Biome biome, ClimateBand to) {
    if (biome == Biome.mountains || biome == Biome.volcano) return biome;
    return switch (to) {
      ClimateBand.airless => switch (biome) {
          Biome.ocean => Biome.iceCap,
          Biome.grassland ||
          Biome.forest ||
          Biome.wetland ||
          Biome.coastal ||
          Biome.tundra ||
          Biome.desert =>
            Biome.barren,
          _ => biome,
        },
      ClimateBand.frozen => switch (biome) {
          Biome.ocean => Biome.iceCap,
          Biome.grassland ||
          Biome.forest ||
          Biome.wetland ||
          Biome.coastal =>
            Biome.tundra,
          Biome.desert => Biome.barren,
          _ => biome,
        },
      ClimateBand.temperateWet => switch (biome) {
          Biome.barren ||
          Biome.desert ||
          Biome.volcanic ||
          Biome.tundra =>
            Biome.grassland,
          Biome.iceCap => Biome.wetland,
          _ => biome,
        },
      ClimateBand.temperateDry => switch (biome) {
          Biome.barren || Biome.iceCap || Biome.tundra => Biome.desert,
          Biome.grassland => Biome.desert,
          Biome.forest || Biome.wetland => Biome.grassland,
          _ => biome,
        },
      ClimateBand.scorching => switch (biome) {
          Biome.grassland ||
          Biome.forest ||
          Biome.wetland ||
          Biome.coastal ||
          Biome.ocean ||
          Biome.tundra ||
          Biome.iceCap =>
            Biome.desert,
          _ => biome,
        },
    };
  }

  /// Judge [sky] on world [onBody] for a colony whose land is [biome]:
  /// the biome it becomes if the climate has crossed into a new band, or
  /// null if nothing changes. The first judgement on a world only records
  /// its band.
  Biome? update({
    required String onBody,
    required SurfaceConditions sky,
    required Biome biome,
  }) {
    final current = bodyId == onBody ? band : null;
    final next = classify(sky, current: current);
    if (current == null) {
      band = next;
      bodyId = onBody;
      return null;
    }
    if (next == current) return null;
    band = next;
    final b = transition(biome, next);
    return b == biome ? null : b;
  }

  /// Forget the band, so the next judgement records rather than changes —
  /// for a colony re-sited or re-biomed by hand.
  void reset() {
    band = null;
    bodyId = null;
  }

  /// Saved form; null when nothing has been judged.
  Map<String, dynamic>? toJson() {
    final b = band;
    final id = bodyId;
    if (b == null || id == null) return null;
    return {'band': b.name, 'body': id};
  }

  /// Replace from [json] (from [toJson]); anything missing or unknown loads
  /// unjudged, and the next tick records the band the world is in.
  void restore(Object? json) {
    reset();
    if (json is! Map) return;
    final name = json['band'];
    final id = json['body'];
    if (name is! String || id is! String) return;
    for (final b in ClimateBand.values) {
      if (b.name == name) {
        band = b;
        bodyId = id;
        return;
      }
    }
  }
}
