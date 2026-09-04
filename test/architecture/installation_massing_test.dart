// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

/// The plot an installation is really handed: its own site, no frontage.
Parcel _plot(CityBuildingSpec spec, {double scale = 1.0}) {
  final s = spec.siteMetres();
  final hw = s.width * scale / 2, hd = s.depth * scale / 2;
  return Parcel(
    id: 'site',
    polygon: [Vec2(-hw, -hd), Vec2(hw, -hd), Vec2(hw, hd), Vec2(-hw, hd)],
    manual: true,
  );
}

CityBuildingSpec _spec(String type) =>
    kUtilCatalog.firstWhere((s) => s.type == type);

void main() {
  const rules = BuildingMassingRules();

  test('each installation is built of the shapes its counterpart is', () {
    final expectations = <String, Set<MassShape>>{
      'wind': {MassShape.frustum, MassShape.rotor},
      'gas': {MassShape.gable, MassShape.frustum, MassShape.cylinder, MassShape.vehicle},
      'reactor': {
        MassShape.cylinder,
        MassShape.dome,
        MassShape.hyperboloid,
        MassShape.frustum,
        MassShape.gable,
        MassShape.box,
        MassShape.vehicle,
      },
      'fusion': {MassShape.cylinder, MassShape.frustum},
      'refinery': {MassShape.cylinder, MassShape.frustum},
      'steelmill': {MassShape.gable, MassShape.frustum, MassShape.cylinder},
      'datacenter': {MassShape.box, MassShape.cylinder},
      'assembly': {MassShape.box},
      'base': {MassShape.gable, MassShape.cylinder, MassShape.frustum},
      'airfield': {MassShape.gable, MassShape.frustum, MassShape.cylinder},
      'spaceport': {
        MassShape.cylinder,
        MassShape.frustum,
        MassShape.box,
        MassShape.dome,
        MassShape.gable,
        MassShape.vehicle,
      },
      'terraformer': {MassShape.frustum, MassShape.cylinder},
      'station': {MassShape.box},
      'freightyard': {MassShape.box},
      'farm': {MassShape.box},
      'solarthermal': {MassShape.frustum, MassShape.mirror, MassShape.cylinder, MassShape.gable},
      'solar': {MassShape.panel, MassShape.box},
      'aquifer': {MassShape.cylinder, MassShape.dome, MassShape.gable, MassShape.vehicle, MassShape.box},
      'solar-big': {MassShape.panel, MassShape.box},
    };
    expectations.forEach((type, shapes) {
      final spec = _spec(type);
      final m = rules.massFor(spec, _plot(spec));
      final got = m.volumes.map((v) => v.shape).toSet();
      for (final shape in shapes) {
        expect(got, contains(shape), reason: '$type lacks a ${shape.name}');
      }
    });
  });

  test('a refinery is mostly tanks; a wind farm is towers with rotors', () {
    final refinery = rules.massFor(_spec('refinery'), _plot(_spec('refinery')));
    final tanks =
        refinery.volumes.where((v) => v.shape == MassShape.cylinder).length;
    expect(tanks, greaterThanOrEqualTo(12));
    final wind = rules.massFor(_spec('wind'), _plot(_spec('wind')));
    final rotors = wind.volumes.where((v) => v.shape == MassShape.rotor);
    expect(rotors.length, 5);
    for (final r in rotors) {
      expect(r.z, greaterThan(60), reason: 'a rotor sits on top of its tower');
    }
  });

  test('every installation stays inside its own site, and shrinks to a small one',
      () {
    for (final spec in kUtilCatalog) {
      for (final scale in const [1.0, 0.3, 0.05]) {
        final plot = _plot(spec, scale: scale);
        final s = spec.siteMetres();
        final hw = s.width * scale / 2 + 0.5, hd = s.depth * scale / 2 + 0.5;
        final m = rules.massFor(spec, plot);
        for (final v in m.volumes) {
          expect(v.width.isFinite && v.depth.isFinite && v.height.isFinite,
              isTrue,
              reason: '${spec.label} at $scale');
          expect(v.width, greaterThan(0), reason: spec.label);
          expect(v.height, greaterThan(0), reason: spec.label);
          if (!spec.claimsOwnSite) continue;
          // A rotor's blades sweep past its footprint; everything else sits
          // inside the plot.
          if (v.shape == MassShape.rotor) continue;
          expect(v.x.abs() + v.width / 2, lessThanOrEqualTo(hw + 1e-6),
              reason: '${spec.label} at $scale overhangs east-west');
          expect(v.y.abs() + v.depth / 2, lessThanOrEqualTo(hd + 1e-6),
              reason: '${spec.label} at $scale overhangs north-south');
        }
      }
    }
  });

  test('a solar thermal farm is rings of mirrors about a tower per cell', () {
    final spec = _spec('solarthermal');
    final m = rules.massFor(spec, _plot(spec));
    double dist(MassBox a, MassBox b) =>
        math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    final towers = m.volumes
        .where((v) => v.shape == MassShape.frustum && v.height > 60)
        .toList();
    expect(towers, hasLength(2), reason: 'a 2400 m site holds two fields');
    final mirrors =
        m.volumes.where((v) => v.shape == MassShape.mirror).toList();
    expect(mirrors.length, greaterThan(3000));
    final site = spec.siteMetres();
    var nearTilt = 0.0, farTilt = 0.0;
    for (final h in mirrors) {
      expect(h.x.abs(), lessThan(site.width / 2));
      expect(h.y.abs(), lessThan(site.depth / 2));
      final t = towers.reduce((a, b) => dist(a, h) < dist(b, h) ? a : b);
      // Faces its own tower, looks up at the receiver, and stays out of
      // the power block's clearing.
      final bearing = math.atan2(t.y - h.y, t.x - h.x);
      var diff = (h.yaw - bearing) % (2 * math.pi);
      if (diff > math.pi) diff = 2 * math.pi - diff;
      expect(diff, lessThan(1e-6));
      expect(h.tilt, inInclusiveRange(0.3, 1.4));
      expect(dist(t, h), greaterThan(60));
      if (dist(t, h) < 120) nearTilt = h.tilt;
      if (dist(t, h) > 500) farTilt = h.tilt;
    }
    // The near rings lie back, the far ones stand up.
    expect(nearTilt, greaterThan(farTilt + 0.2));
    // A bigger plot is more towers, not a bigger field: three by two.
    final big = rules.massFor(spec, _plot(spec, scale: 1.5));
    expect(
        big.volumes
            .where((v) => v.shape == MassShape.frustum && v.height > 60)
            .length,
        6);
    // A smaller plot: one tower, and fewer mirrors than half of two.
    final small = rules.massFor(spec, _plot(spec, scale: 0.4));
    expect(
        small.volumes
            .where((v) => v.shape == MassShape.frustum && v.height > 60)
            .length,
        1);
    expect(small.volumes.where((v) => v.shape == MassShape.mirror).length,
        lessThan(mirrors.length ~/ 2));
  });

  test('a solar farm is tables in blocks, an inverter a block, and a yard', () {
    final farm = rules.massFor(_spec('solar'), _plot(_spec('solar')));
    final tables = farm.volumes.where((v) => v.shape == MassShape.panel).toList();
    expect(tables.length, greaterThan(2000));
    // Every table faces the same way and tips the same, like a real field.
    for (final t in tables) {
      expect(t.yaw, tables.first.yaw);
      expect(t.tilt, tables.first.tilt);
    }
    // Inverter pads: one per block, three by three on 780 m.
    final pads = farm.volumes.where((v) => v.height == 0.3 && v.width == 12).length;
    expect(pads, 9);
    // The far corners are bitten off: fewer tables in the last row's far
    // end than in the first row's.
    final ys = tables.map((t) => t.y).toSet().toList()..sort();
    int inRow(double y) => tables.where((t) => t.y == y).length;
    expect(inRow(ys.last), lessThan(inRow(ys.first)));
    // The array has the battery yard: forty containers to the farm's six.
    // A container: a box a little under three metres tall and as many wide.
    int containers(BuildingMassing m) => m.volumes
        .where((v) =>
            v.shape == MassShape.box &&
            v.height > 2.6 &&
            v.height < 3.0 &&
            v.depth < 3.0 &&
            v.width > 10)
        .length;
    expect(containers(farm), 6);
    final array = rules.massFor(_spec('solar-big'), _plot(_spec('solar-big')));
    expect(containers(array), 40);
    expect(array.volumes.where((v) => v.shape == MassShape.panel).length,
        greaterThan(tables.length * 2));
  });

  test('a massing respects the shape of its parcel, not just its box', () {
    // A tapered claimed plot for the solar farm: the box is 780 wide, the
    // back edge is half that.
    const w = 780.0, d = 780.0;
    final tapered = Parcel(
      id: 'taper',
      polygon: [
        const Vec2(-w / 2, -d / 2),
        const Vec2(w / 2, -d / 2),
        const Vec2(w * 0.25, d / 2),
        const Vec2(-w * 0.25, d / 2),
      ],
      manual: true,
    );
    final farm = rules.massFor(_spec('solar'), tapered);
    final boxed = rules.massFor(_spec('solar'), _plot(_spec('solar')));
    expect(farm.volumes.length, lessThan(boxed.volumes.length));
    expect(farm.volumes.where((v) => v.shape == MassShape.panel).length,
        greaterThan(1000));
    final c = tapered.centroid;
    for (final v in farm.volumes) {
      final ax = -math.sin(v.yaw), ay = math.cos(v.yaw);
      final hw = v.width / 2 - 0.5;
      for (final (x, y) in v.shape == MassShape.panel
          ? [(v.x + ax * hw, v.y + ay * hw), (v.x - ax * hw, v.y - ay * hw)]
          : [(v.x - hw, v.y - v.depth / 2 + 0.5), (v.x + hw, v.y + v.depth / 2 - 0.5)]) {
        expect(tapered.contains(Vec2(c.e + x, c.n + y)), isTrue,
            reason: 'a ${v.shape.name} stands over the line');
      }
    }
    // A street building on a tapered lot fits the rectangle inscribed in
    // it, so nothing is cut and nothing overhangs.
    final lot = Parcel(
      id: 'lot',
      polygon: [
        const Vec2(-15, 0),
        const Vec2(15, 0),
        const Vec2(9, 40),
        const Vec2(-9, 40),
      ],
      frontage: (const Vec2(-15, 0), const Vec2(15, 0)),
    );
    final clinic = rules.massFor(_spec('clinic'), lot);
    expect(clinic.volumes, isNotEmpty);
    final lc = lot.centroid;
    for (final v in clinic.volumes) {
      for (final sx in const [-0.5, 0.5]) {
        for (final sy in const [-0.5, 0.5]) {
          expect(
              lot.contains(Vec2(lc.e + v.x + v.width * sx * 0.98,
                  lc.n + v.y + v.depth * sy * 0.98)),
              isTrue,
              reason: 'the clinic overhangs its tapered lot');
        }
      }
    }
  });

  test('a cooling tower is a waisted shell on a ring of legs', () {
    final m = rules.massFor(_spec('reactor'), _plot(_spec('reactor')));
    final shells = m.volumes.where((v) => v.shape == MassShape.hyperboloid).toList();
    expect(shells, hasLength(2));
    for (final shell in shells) {
      expect(shell.z, greaterThan(5), reason: 'the shell stands on its legs');
      final legs = m.volumes.where((v) =>
          v.shape == MassShape.frustum &&
          v.height < 20 &&
          (v.x - shell.x).abs() < shell.width &&
          (v.y - shell.y).abs() < shell.depth);
      expect(legs.length, 20);
    }
    final domes = m.volumes.where((v) => v.shape == MassShape.dome).toList();
    expect(domes, hasLength(2));
    for (final dome in domes) {
      // Each dome caps a cylinder of its own diameter.
      expect(
          m.volumes.any((v) =>
              v.shape == MassShape.cylinder &&
              v.x == dome.x &&
              v.y == dome.y &&
              (v.top - dome.z).abs() < 1e-9 &&
              (v.width - dome.width).abs() < 1e-9),
          isTrue);
    }
    // The shell reads as a hyperboloid: the generator's rings narrow to a
    // waist and flare back out at the lip.
    const gen = BuildingGenerator();
    final built = gen.generate(_spec('reactor'), _plot(_spec('reactor')));
    expect(built.model.solid.triangleCount, greaterThan(3000));
  });

  test('a pumping station is two domed tanks, a pump house and blue pipe', () {
    final m = rules.massFor(_spec('aquifer'), _plot(_spec('aquifer')));
    final domes = m.volumes.where((v) => v.shape == MassShape.dome).toList();
    expect(domes, hasLength(2));
    for (final d in domes) {
      // A low dome: much wider than tall.
      expect(d.height, lessThan(d.width * 0.15));
      // On the tank's roof, less the plot's setback scaling.
      expect(d.z, closeTo(10, 0.6));
    }
    final blue = m.volumes.where((v) => v.material == FacadeMaterial.industrialBlue).length;
    expect(blue, greaterThan(20), reason: 'a pumping station is blue pipe');
    expect(m.volumes.where((v) => v.shape == MassShape.vehicle).length, 3);
  });

  test('a works is several materials and has its vehicles about', () {
    const gen = BuildingGenerator();
    for (final type in ['gas', 'reactor']) {
      final spec = _spec(type);
      final m = rules.massFor(spec, _plot(spec));
      final bands = m.volumes.map((v) => v.material).whereType<int>().toSet();
      expect(bands.length, greaterThanOrEqualTo(5), reason: '$type is one cladding');
      expect(bands, contains(FacadeMaterial.whiteMetal));
      expect(bands, contains(FacadeMaterial.steel));
      expect(bands, contains(FacadeMaterial.industrialBlue));
      final vehicles = m.volumes.where((v) => v.shape == MassShape.vehicle);
      expect(vehicles.length, greaterThanOrEqualTo(4), reason: '$type has no vehicles');
      // Every vehicle stands on the ground and is car- or truck-sized.
      for (final v in vehicles) {
        expect(v.z, 0);
        expect(v.width, inInclusiveRange(2.5, 14));
        expect(v.height, inInclusiveRange(1.5, 4));
      }
      for (final tier in BuildingDetail.values) {
        final built = gen.generate(spec, _plot(spec), detail: tier);
        for (final p in built.model.solid.positions) {
          expect(p.isFinite, isTrue);
        }
      }
    }
  });

  test('a spaceport is one launch complex per cell, on grass not concrete', () {
    int masts(BuildingMassing m) => m.volumes
        .where((v) => v.shape == MassShape.frustum && v.topScale == 0.35)
        .length;
    final byLabel = {for (final s in kUtilCatalog) if (s.type == 'spaceport') s.label: s};
    final single = rules.massFor(byLabel['Spaceport']!, _plot(byLabel['Spaceport']!));
    final complex = rules.massFor(
        byLabel['Spaceport Complex (2×4)']!, _plot(byLabel['Spaceport Complex (2×4)']!));
    final starport = rules.massFor(byLabel['Starport (3×6)']!, _plot(byLabel['Starport (3×6)']!));
    // Four lightning masts a pad.
    expect(masts(single), 4);
    expect(masts(complex), 32);
    expect(masts(starport), 72);
    // Half the pads carry a vehicle: a white cylinder under a nose cone.
    int vehicles(BuildingMassing m) => m.volumes
        .where((v) => v.shape == MassShape.frustum && v.topScale == 0.15)
        .length;
    expect(vehicles(starport), 9);
    // No slab covers the plot: the biggest flat thing is a road or an apron.
    for (final m in [single, complex, starport]) {
      final site = m.footprint;
      for (final v in m.volumes) {
        if (v.height > 0.6) continue;
        expect(v.width * v.depth, lessThan(site.width * site.depth * 0.05),
            reason: 'a slab the size of the site');
      }
    }
    // The bigger sites get the assembly building; the single pad does not.
    bool vab(BuildingMassing m) =>
        m.volumes.any((v) => v.shape == MassShape.box && v.height > 80 && v.width > 100);
    expect(vab(single), isFalse);
    expect(vab(complex), isTrue);
  });

  test('a heliostat is a pedestal in the solid and a plate in the glass', () {
    const gen = BuildingGenerator();
    final spec = _spec('solarthermal');
    for (final tier in BuildingDetail.values) {
      final built = gen.generate(spec, _plot(spec, scale: 0.4), detail: tier);
      expect(built.model.foliage.triangleCount, greaterThan(1000),
          reason: 'plates at ${tier.name}');
      expect(built.model.solid.triangleCount, greaterThan(1000),
          reason: 'pedestals at ${tier.name}');
    }
  });

  test('every shape emits geometry at every tier, and a rotor has three blades',
      () {
    const gen = BuildingGenerator();
    for (final type in ['wind', 'refinery', 'reactor', 'steelmill', 'park']) {
      final spec = _spec(type);
      for (final tier in BuildingDetail.values) {
        final built = gen.generate(spec, _plot(spec), detail: tier);
        expect(built.model.solid.triangleCount, greaterThan(0),
            reason: '$type at ${tier.name}');
        for (final p in built.model.solid.positions) {
          expect(p.isFinite, isTrue, reason: '$type at ${tier.name}');
        }
      }
    }
    // One rotor alone: three blades of two faces plus a hub box.
    final rotorOnly = BuildingMassing(
      volumes: const [
        MassBox(
            x: 0,
            y: 0,
            z: 80,
            width: 3,
            depth: 0.4,
            height: 38,
            glazed: false,
            shape: MassShape.rotor),
      ],
      storeyM: 3.2,
      floorArea: 0,
      entrance: (0, 0),
    );
    expect(rotorOnly.height, 118);
  });
}
