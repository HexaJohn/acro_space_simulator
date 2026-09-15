// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_program.dart';
import 'package:flutter_test/flutter_test.dart';

/// §3.3 constants copied from another module, pinned to their source
/// (site_access_constants.dart's rule: a copied value cannot drift).
void main() {
  test('kIndustrialGroups is exactly BuildingMassingRules._isIndustrial', () {
    // `_isIndustrial` is private; its public effect is the storey height a
    // massing takes. With an industrial storey no style uses, a probe spec of
    // group g masses at that storey iff g is industrial.
    const odd = 9.87;
    const rules = BuildingMassingRules(industrialStoreyM: odd);
    final parcel = Parcel(id: 'probe', polygon: const [
      Vec2(0, 0), Vec2(40, 0), Vec2(40, 50), Vec2(0, 50), //
    ]);
    bool massesIndustrial(String group) {
      final spec = CityBuildingSpec(
          type: 'probe-$group', label: 'Probe', colorArgb: 0, group: group,
          jobs: 20);
      return rules.massFor(spec, parcel).storeyM == odd;
    }

    // Every group the catalogues use, the listed ones, and a control that is
    // no group at all.
    final groups = <String>{
      for (final byDensity in kZoneSpecs.values)
        for (final s in byDensity.values) s.group,
      for (final s in kUtilCatalog) s.group,
      ...kIndustrialGroups,
      'not-a-group',
    }.toList()
      ..sort();
    for (final group in groups) {
      final spec = CityBuildingSpec(
          type: 'probe', label: 'Probe', colorArgb: 0, group: group);
      expect(isIndustrialSpec(spec), massesIndustrial(group), reason: group);
    }
    expect(massesIndustrial('ind'), isTrue);
    expect(massesIndustrial('res'), isFalse);
  });
}
