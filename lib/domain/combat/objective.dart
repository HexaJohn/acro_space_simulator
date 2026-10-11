// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Objectives: what an operation is fought over (docs/plans/combat.md §2, §7.3).
///
/// Every objective is something the colony already has — its port, its seat,
/// its life support — so winning or losing one has a meaning outside the
/// battle. Phase 1 has two: the Port (the seized pads, airfields excluded) and
/// the attacker's landing zone.
library;

import 'dart:math' as math;

/// What an objective is. Append-only: saved by name.
enum ObjectiveKind { port, lz, seat, lifeSupport, power, depot, airfield }

/// One node of the battle graph.
class Objective {
  Objective({
    required this.id,
    required this.kind,
    required this.value,
    required this.width,
    this.fDef = 1.0,
    this.fAtt = 1.0,
    this.control = 0.0,
    this.heldS = 0,
    this.e = 0,
    this.n = 0,
  });

  final String id;
  final ObjectiveKind kind;

  /// How much the defender cares about holding it.
  final double value;

  /// Width: the most strength either side can bring to bear here at once. A
  /// port is a port; a bigger army does not fit more guns onto it.
  final double width;

  /// Fortification the DEFENDER fights behind, in [1, 2.2]: divides the
  /// attacker's fire. Kept apart from [fAtt] so a turret one side built cannot
  /// protect the other side raiding it (reference §10A.6).
  final double fDef;

  /// Fortification the ATTACKER fights behind; 1 in phase 1 (no base yet).
  final double fAtt;

  /// −1 defender holds, +1 attacker holds.
  double control;

  /// Consecutive seconds the attacker has held it at or above the win line.
  int heldS;

  /// Where it stands, in the target colony's east/north metres: what the
  /// battle is drawn at (docs/plans/combat.md §7B). The resolver never reads
  /// it — march times are on the links.
  final double e, n;

  /// The objective width for a footprint of [areaM2] square metres:
  /// `min(cap, 6 + 4·sqrt(m² / 10,000))` — a 1 ha port is about 10.
  static double widthFor(double areaM2, {double cap = 24}) =>
      math.min(cap, 6 + 4 * math.sqrt(math.max(0.0, areaM2) / 10000.0));

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'value': value,
        'width': width,
        if (fDef != 1.0) 'fDef': fDef,
        if (fAtt != 1.0) 'fAtt': fAtt,
        if (control != 0) 'c': control,
        if (heldS != 0) 'held': heldS,
        if (e != 0) 'e': e,
        if (n != 0) 'n': n,
      };

  factory Objective.fromJson(Map<String, dynamic> j) => Objective(
        id: j['id'] as String,
        kind: ObjectiveKind.values.byName(j['kind'] as String),
        value: (j['value'] as num).toDouble(),
        width: (j['width'] as num).toDouble(),
        fDef: (j['fDef'] as num?)?.toDouble() ?? 1.0,
        fAtt: (j['fAtt'] as num?)?.toDouble() ?? 1.0,
        control: (j['c'] as num?)?.toDouble() ?? 0,
        heldS: (j['held'] as num?)?.toInt() ?? 0,
        e: (j['e'] as num?)?.toDouble() ?? 0,
        n: (j['n'] as num?)?.toDouble() ?? 0,
      );
}

/// A march between two objectives, in whole seconds of operation time.
class ObjectiveLink {
  const ObjectiveLink(this.a, this.b, this.marchS);
  final String a, b;
  final int marchS;

  Map<String, dynamic> toJson() => {'a': a, 'b': b, 's': marchS};
  factory ObjectiveLink.fromJson(Map<String, dynamic> j) => ObjectiveLink(
      j['a'] as String, j['b'] as String, (j['s'] as num).toInt());
}

/// The battle graph: at most 8 nodes, kept in id order so every pass over it
/// visits them the same way.
class ObjectiveGraph {
  ObjectiveGraph(List<Objective> objectives, this.links)
      : objectives = [...objectives]..sort((x, y) => x.id.compareTo(y.id));

  final List<Objective> objectives;
  final List<ObjectiveLink> links;

  Objective? byId(String id) {
    for (final o in objectives) {
      if (o.id == id) return o;
    }
    return null;
  }

  Objective? firstOf(ObjectiveKind kind) {
    for (final o in objectives) {
      if (o.kind == kind) return o;
    }
    return null;
  }

  /// March time from [a] to [b]: the direct link if there is one, else 0 for
  /// the same node and [fallbackS] otherwise.
  int marchS(String a, String b, {int fallbackS = 300}) {
    if (a == b) return 0;
    for (final l in links) {
      if ((l.a == a && l.b == b) || (l.a == b && l.b == a)) return l.marchS;
    }
    return fallbackS;
  }

  Map<String, dynamic> toJson() => {
        'nodes': [for (final o in objectives) o.toJson()],
        if (links.isNotEmpty) 'links': [for (final l in links) l.toJson()],
      };

  factory ObjectiveGraph.fromJson(Map<String, dynamic> j) => ObjectiveGraph(
        [
          for (final o in (j['nodes'] as List))
            Objective.fromJson((o as Map).cast<String, dynamic>())
        ],
        [
          for (final l in (j['links'] as List? ?? const []))
            ObjectiveLink.fromJson((l as Map).cast<String, dynamic>())
        ],
      );
}
