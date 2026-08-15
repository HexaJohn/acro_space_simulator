// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Games undersize heavy infrastructure because their maps are bounded. This
/// one is not, so a nuclear station, a solar farm and a quarry are built at the
/// scale the real things occupy.
void main() {
  const rules = BuildingMassingRules();

  CityBuildingSpec spec(String label) =>
      kUtilCatalog.firstWhere((s) => s.label == label);

  Parcel lot(double w, double d) => Parcel(
        id: 'lot',
        polygon: [Vec2(-w / 2, 0), Vec2(w / 2, 0), Vec2(w / 2, d), Vec2(-w / 2, d)],
        frontage: (Vec2(-w / 2, 0), Vec2(w / 2, 0)),
      );

  test('power stations occupy real ground', () {
    // Utility solar runs roughly 2 hectares per megawatt.
    expect(spec('Solar Farm').siteArea(), greaterThan(500000)); // > 0.5 km²
    expect(spec('Solar Array').siteArea(), closeTo(4e6, 1)); // 4 km²
    // A fission station with its switchyard, cooling and exclusion area.
    expect(spec('Fission Reactor').siteArea(), greaterThan(1.4e6));
    expect(spec('Fusion Plant').siteArea(),
        greaterThan(spec('Fission Reactor').siteArea()));
  });

  test('a solar farm is a field of rows, not one enormous shed', () {
    final farm = spec('Solar Farm');
    expect(farm.siteKind, SiteKind.field);
    final m = rules.massFor(farm, lot(900, 900));

    // Many low rows, none of them a building-height slab.
    expect(m.volumes.length, greaterThan(30));
    final racks = m.volumes.where((v) => v.floors == 0);
    expect(racks.length, greaterThan(30));
    for (final r in racks) {
      expect(r.height, lessThan(6),
          reason: 'a panel rack is waist-to-head height, not a warehouse');
    }
    // And it spreads across its site rather than stacking.
    expect(m.footprint.width, greaterThan(700));
    expect(m.height, lessThan(10));
  });

  test('the large quarry is enormous, and stepped', () {
    final quarry = spec('Quarry');
    expect(quarry.siteKind, SiteKind.pit);
    expect(quarry.siteArea(), closeTo(9e6, 1)); // 9 km²

    const shaper = CityTerrainShaper();
    // Depth and bench count follow the pit radius, so the headline hole is
    // hundreds of metres deep with dozens of terraces.
    final depth = shaper.pitDepthFor(quarry.siteMetres().width / 2);
    expect(depth, greaterThan(500));
    expect(shaper.benchesFor(quarry.siteMetres().width / 2),
        greaterThanOrEqualTo(20));

    // A small mine is a pit too, but a far smaller one.
    final mine = spec('Mine');
    expect(shaper.pitDepthFor(mine.siteMetres().width / 2), lessThan(depth / 4));
  });

  test('a quarry builds plant on the rim, not a shed over the hole', () {
    final m = rules.massFor(spec('Quarry'), lot(3000, 3000));
    for (final v in m.volumes) {
      // Everything stands well off centre — the middle is the excavation.
      expect(v.x.abs() + v.y.abs(), greaterThan(1000));
    }
    expect(m.footprint.width, lessThan(3000));
  });

  test('a starport is an apron with a tower, sized for real vehicles', () {
    final port = spec('Starport (3×6)');
    expect(port.siteKind, SiteKind.pad);
    expect(port.siteMetres().depth, greaterThan(4000));

    final m = rules.massFor(port, lot(3400, 4400));
    final apron = m.volumes.first;
    expect(apron.height, lessThan(1), reason: 'the apron is hardstanding');
    expect(apron.width, greaterThan(3000));
    expect(m.height, greaterThan(20), reason: 'the control tower stands up');
  });

  test('street-scale buildings are untouched by the retune', () {
    final shop = kZoneSpecs['commercial']![Density.low]!;
    expect(shop.siteKind, SiteKind.building);
    // No explicit site: falls back to the cell footprint, as before.
    expect(shop.siteMetres().width, 24);
    final m = rules.massFor(shop, lot(30, 40));
    expect(m.footprint.width, lessThan(30));
  });
}
