// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../parts/attach_node.dart';
import '../parts/part_catalog.dart';
import '../parts/part_def.dart';
import '../shared/quaternion.dart';
import '../shared/vector3.dart';
import 'craft_design.dart';

/// Save/load for a [CraftDesign] as plain JSON-able maps.
///
/// Persists the AUTHORED design — which catalog part, where, turned which way,
/// in which stage, bolted to what — and nothing derived. Part specs themselves
/// are reference data resolved from a [PartCatalog] at load time, so rebalancing
/// a tank's dry mass improves every saved craft instead of baking a stale copy
/// into each file.
///
/// Versioned with an explicit [schemaVersion]. Readers accept anything at or
/// below their own version and default fields they do not find; a file from the
/// FUTURE is rejected rather than silently loaded with parts missing, because a
/// craft that quietly loses a stage is worse than one that refuses to open.
///
/// The mapping is lossless: positions, rotations, stages, the root, and the
/// whole attach tree survive a round trip exactly. Actual file IO is an
/// infrastructure concern and lives outside the domain.
class CraftDesignCodec {
  static const int schemaVersion = 1;

  const CraftDesignCodec();

  // ---------------- encode ----------------

  Map<String, dynamic> encode(CraftDesign design) => {
        'schema': schemaVersion,
        'name': design.name,
        if (design.rootId != null) 'root': design.rootId,
        'parts': [for (final p in design.parts) _part(p)],
      };

  /// Compact per-part form. Defaults are omitted rather than written out —
  /// most parts sit at stage 0 with no roll, and a craft file that is mostly
  /// `"q":[1,0,0,0]` is harder to diff by eye when a design misbehaves.
  Map<String, dynamic> _part(PlacedPart p) => {
        'id': p.instanceId,
        'def': p.def.id,
        'p': [p.position.x, p.position.y, p.position.z],
        if (p.stage != 0) 'stage': p.stage,
        if (!_isIdentity(p.rotation))
          'q': [p.rotation.w, p.rotation.x, p.rotation.y, p.rotation.z],
        if (p.attachment != null)
          'att': {
            'parent': p.attachment!.parentInstanceId,
            'pn': p.attachment!.parentNode,
            'cn': p.attachment!.childNode,
          },
      };

  static bool _isIdentity(Quaternion q) =>
      q.w == 1 && q.x == 0 && q.y == 0 && q.z == 0;

  // ---------------- decode ----------------

  /// Rebuild a design, resolving every `def` id through [catalog].
  ///
  /// Catalogs compose — `PartCatalog([...PartCatalog.standard().all, ...mod])`
  /// — so a craft using parts from more than one roster loads from a merged
  /// catalog rather than needing a codec that knows about rosters.
  ///
  /// Throws [FormatException] on a malformed or too-new file, and [StateError]
  /// (from [CraftDesign.fromParts]) when the parts load but the attach tree
  /// they describe is not a valid forest.
  CraftDesign decode(Map<String, dynamic> json, {required PartCatalog catalog}) {
    final schema = (json['schema'] as num?)?.toInt() ?? schemaVersion;
    if (schema > schemaVersion) {
      throw FormatException('craft design schema $schema is newer than '
          '$schemaVersion — this build cannot read it');
    }
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('craft design is missing a name');
    }
    final raw = json['parts'];
    if (raw is! List) {
      throw const FormatException('craft design is missing its parts list');
    }

    final parts = <PlacedPart>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw const FormatException('craft design part entry is not an object');
      }
      parts.add(_decodePart(entry.cast<String, dynamic>(), catalog));
    }

    // Attachments may point forward as well as back — re-parenting an early
    // part onto a later one is legal in the editor — so the whole list is built
    // before the tree is validated.
    return CraftDesign.fromParts(
      name: name,
      parts: parts,
      rootId: json['root'] as String?,
    );
  }

  PlacedPart _decodePart(Map<String, dynamic> j, PartCatalog catalog) {
    final instanceId = j['id'];
    if (instanceId is! String || instanceId.isEmpty) {
      throw const FormatException('craft design part has no instance id');
    }
    final defId = j['def'];
    if (defId is! String) {
      throw FormatException('part "$instanceId" has no catalog def id');
    }
    final def = catalog.byId(defId);
    if (def == null) {
      // Dropping the part would silently change the craft's mass, CoM, and
      // delta-v, so refuse instead: the player needs to know a part is gone.
      throw FormatException(
          'part "$instanceId" references unknown catalog part "$defId"');
    }
    return PlacedPart(
      def: def,
      instanceId: instanceId,
      position: _vector(j['p']),
      stage: (j['stage'] as num?)?.toInt() ?? 0,
      rotation: _quaternion(j['q']),
      attachment: _attachment(j['att'], instanceId),
    );
  }

  PartAttachment? _attachment(Object? raw, String instanceId) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw FormatException('part "$instanceId" has a malformed attachment');
    }
    final parent = raw['parent'], pn = raw['pn'], cn = raw['cn'];
    if (parent is! String || pn is! String || cn is! String) {
      throw FormatException('part "$instanceId" attachment is missing a '
          'parent id or node name');
    }
    return PartAttachment(
      parentInstanceId: parent,
      parentNode: pn,
      childNode: cn,
    );
  }

  /// JSON has one number type, so a whole-valued double comes back as an int;
  /// every read goes through [num] to survive that.
  static Vector3 _vector(Object? raw) {
    if (raw == null) return Vector3.zero;
    if (raw is! List || raw.length != 3) {
      throw const FormatException('expected a [x,y,z] position');
    }
    return Vector3(
      (raw[0] as num).toDouble(),
      (raw[1] as num).toDouble(),
      (raw[2] as num).toDouble(),
    );
  }

  static Quaternion _quaternion(Object? raw) {
    if (raw == null) return Quaternion.identity;
    if (raw is! List || raw.length != 4) {
      throw const FormatException('expected a [w,x,y,z] rotation');
    }
    return Quaternion(
      (raw[0] as num).toDouble(),
      (raw[1] as num).toDouble(),
      (raw[2] as num).toDouble(),
      (raw[3] as num).toDouble(),
    );
  }
}
