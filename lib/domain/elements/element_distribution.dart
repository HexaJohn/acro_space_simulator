import 'dart:math' as math;

import '../planetary/planet_surface.dart';
import '../vessel/resource_container.dart';
import 'chemical_element.dart';
import 'periodic_table.dart';

/// One element's local richness at a surface point.
class ElementYield {
  final ChemicalElement element;
  final double concentration; // 0..1
  const ElementYield(this.element, this.concentration);
}

/// Maps the periodic table onto a body's surface: each element has a noise
/// field (so it forms localized ore veins) scaled by its crustal abundance, so
/// common elements (Fe, Al, Si) are widespread and rich while rare ones (Au,
/// Pt, U) appear only in sparse, weak pockets — exactly the prospecting loop.
///
/// Reuses [PlanetSurface.oreConcentrationAt] for the deterministic noise, keyed
/// by atomic number so each element has its own vein pattern.
class ElementDistribution {
  final PlanetSurface surface;
  final PeriodicTable table;

  const ElementDistribution({required this.surface, required this.table});

  /// Concentration 0..1 of [symbol] at a surface point.
  double concentrationAt({
    required double latitude,
    required double longitude,
    required String symbol,
  }) {
    final element = table.bySymbol(symbol);
    if (element == null) return 0;

    // Deterministic vein noise, channelled by atomic number.
    final noise = surface.oreConcentrationAt(
      latitude: latitude,
      longitude: longitude,
      // Borrow a resource channel deterministically from the atomic number.
      resource: ResourceType.values[element.atomicNumber % ResourceType.values.length],
    );

    // Abundance weight: log-compressed crustal abundance (1e-9..0.46) -> ~0..1.
    final weight = _abundanceWeight(element.crustalAbundance);
    return (noise * weight).clamp(0.0, 1.0);
  }

  /// The [count] richest elements at a point, sorted descending.
  List<ElementYield> richestAt({
    required double latitude,
    required double longitude,
    int count = 5,
  }) {
    final yields = <ElementYield>[
      for (final e in table.all)
        ElementYield(
          e,
          concentrationAt(
              latitude: latitude, longitude: longitude, symbol: e.symbol),
        ),
    ];
    yields.sort((a, b) => b.concentration.compareTo(a.concentration));
    return yields.take(count).toList();
  }

  /// Map crustal abundance (mass fraction) to a 0..1 richness weight via log
  /// scaling. Oxygen (~0.46) -> ~1; gold (~4e-9) -> tiny.
  double _abundanceWeight(double abundance) {
    if (abundance <= 0) return 0;
    // log10 abundance ranges ~ -8.4 (Au) .. -0.34 (O); remap to [0,1].
    final logA = math.log(abundance) / math.ln10; // log10
    return ((logA + 9.0) / 9.0).clamp(0.0, 1.0);
  }
}
