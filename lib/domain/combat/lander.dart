// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Troop landers: the squads an operation sends, flown down as real vessels
/// onto its landing zone (docs/plans/combat.md §7B).
///
/// The record is the operation's (saved with it); the vessel is the world's.
/// The world's lander flight spawns one per record, flies it by the shuttles'
/// landing guidance, and tells the operation when it is down or lost. The
/// operation's transit ends when every lander has done one or the other.
library;

import 'dart:math' as math;

import 'formation.dart';

/// Where a lander is.
enum LanderState {
  /// Not yet flying: it spawns once the operation has mustered.
  pending,

  /// In the air, on its powered descent.
  descending,

  /// Down at the LZ; its squads are on the ground.
  landed,

  /// Lost before touchdown, with everyone aboard.
  lost,

  /// Flown home after the operation ended (or it never flew).
  departed,
}

class LanderRecord {
  LanderRecord({
    required this.vesselId,
    required this.formationIds,
    required this.offE,
    required this.offN,
    this.state = LanderState.pending,
  });

  final String vesselId;

  /// The squads aboard, by formation id.
  final List<int> formationIds;

  /// Its touchdown point's offset from the LZ, colony east/north metres.
  final double offE, offN;

  LanderState state;

  /// Down or lost (or gone home): nothing more to wait for.
  bool get settled =>
      state != LanderState.pending && state != LanderState.descending;

  Map<String, dynamic> toJson() => {
        'vessel': vesselId,
        'squads': List<int>.of(formationIds),
        'e': offE,
        'n': offN,
        'state': state.name,
      };

  factory LanderRecord.fromJson(Map<String, dynamic> j) => LanderRecord(
        vesselId: j['vessel'] as String,
        formationIds: [for (final v in (j['squads'] as List)) (v as num).toInt()],
        offE: (j['e'] as num).toDouble(),
        offN: (j['n'] as num).toDouble(),
        state: LanderState.values.byName(j['state'] as String),
      );
}

/// Troopers a lander carries at most.
const int kLanderCapacity = 16;

/// Spacing of touchdown points round the LZ, m: wider than a lander's
/// guidance tolerance, so no two come down on each other.
const double kLanderSpacingM = 40;

/// Packs the [squads] (in id order) into landers of at most
/// [kLanderCapacity] troopers — a squad is never split — numbered from
/// [firstIndex] for operation [opId]. Touchdown points spiral out from the LZ
/// by the golden angle, so a reinforcement wave's landers fall between the
/// first wave's rather than on them.
List<LanderRecord> packLanders(int opId, List<Formation> squads, {int firstIndex = 0}) {
  final out = <LanderRecord>[];
  var aboard = <int>[];
  var load = 0;
  void close() {
    if (aboard.isEmpty) return;
    final k = firstIndex + out.length;
    // Golden-angle spiral: the k-th point at radius spacing·sqrt(k+1).
    final r = kLanderSpacingM * math.sqrt(k + 1.0);
    final a = k * 2.399963229728653;
    out.add(LanderRecord(
      vesselId: 'force-$opId-$k',
      formationIds: aboard,
      offE: r * math.cos(a),
      offN: r * math.sin(a),
    ));
    aboard = <int>[];
    load = 0;
  }

  for (final f in squads) {
    if (load > 0 && load + f.count > kLanderCapacity) close();
    aboard.add(f.id);
    load += f.count;
  }
  close();
  return out;
}
