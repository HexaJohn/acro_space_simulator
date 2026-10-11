// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The three reference scenarios the calibration gate runs (docs/plans/
/// combat.md §7I), for `bin/combat_calibrate.dart` and the test alike: an
/// independent town laid out on a line, the port east and the seat west,
/// assaulted by troopers from barracks of 15.
library;

import '../launch/plan_operation.dart';
import '../launch/snapshots.dart';
import '../operation.dart';
import 'calibration.dart';

SourceSnapshot _source(int troopers) {
  final sites = <TrooperSource>[];
  var left = troopers, i = 0;
  while (left > 0) {
    final n = left > 15 ? 15 : left;
    sites.add(TrooperSource(
      siteId: 'b$i',
      type: 'barracks',
      jobs: 30,
      ready: true,
      available: n,
      kitPerTrooperDay: const {'rations': 2, 'guns': 0.2, 'ammo': 1.2},
    ));
    left -= n;
    i++;
  }
  return SourceSnapshot(
    colonyId: 'src',
    name: 'Garrison Town',
    bodyId: 'moon',
    sources: sites,
    stock: const {'rations': 9999, 'guns': 999, 'ammo': 9999, 'fuel': 999},
  );
}

LaunchSnapshot _town(int regulars, List<EmplacementSite> guns) => LaunchSnapshot(
      colonyId: 'rebels',
      bodyId: 'moon',
      population: 120,
      mood: 0.6,
      hunger: 0,
      severity: 0.4,
      wish: 0,
      spaceportJobs: 20,
      gunsInStock: 10,
      portSeized: false,
      independent: true,
      regulars: regulars,
      emplacements: guns,
      objectives: const [
        ObjectiveSite(kind: 'seat', siteId: 'hall', e: -300, n: 0, areaM2: 4000),
        ObjectiveSite(kind: 'port', siteId: 'pad', e: 300, n: 0, areaM2: 20000),
        ObjectiveSite(kind: 'lifeSupport', siteId: 'farm', e: 0, n: 200, areaM2: 160000),
        ObjectiveSite(kind: 'power', siteId: 'solar', e: 0, n: -250, areaM2: 600000),
      ],
    );

Operation Function(int seed) assaultScenario({int troopers = 30, int regulars = 0, List<EmplacementSite> guns = const []}) =>
    (seed) {
      final src = _source(troopers);
      return planColonyAssault(
        operationId: 100 + seed,
        target: _town(regulars, guns),
        sources: [src],
        draws: [for (final s in src.sources) TrooperDraw('src', s.siteId, s.available)],
        garrison: 2,
        kitDays: 6,
      ).operation!;
    };

/// A: an open town. B: regulars and a gun at the port. C: a defended town
/// against a bigger force.
final List<(String, Operation Function(int))> kCalibrationScenarios = [
  ('A open town', assaultScenario()),
  ('B regulars + gun', assaultScenario(regulars: 10, guns: const [EmplacementSite('gun-1', 280, 30, 4)])),
  (
    'C defended town',
    assaultScenario(troopers: 45, regulars: 20, guns: const [
      EmplacementSite('gun-1', 280, 30, 4),
      EmplacementSite('gun-2', -310, -20, 4),
    ])
  ),
];

/// Every scenario, compared.
List<CalibrationRow> calibrateAll({int seeds = 8}) => [
      for (final (name, build) in kCalibrationScenarios) calibrate(name, build, seeds: seeds),
    ];
