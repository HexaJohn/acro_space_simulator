// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../domain/parts/part_catalog.dart';
import '../../domain/parts/part_def.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';

/// How one part type binds to baked art: which `.fsceneb` to draw, how big a
/// model unit is, how the export's authored axis differs from the body frame,
/// and where the mesh sits relative to the part origin.
///
/// Built FROM the catalog's [PartDef] render fields rather than restating them
/// (see [PartModelLibrary]). The renderer still needs this type because a
/// `PartSnapshot` carries only a type key, never a `PartDef` — but the values
/// in it are the catalog's, so art and physics cannot disagree about how big a
/// part is.
class PartModel {
  /// The bake. Not committed (the source models are licensed for use but not
  /// redistribution), so this path is routinely absent on a fresh clone — that
  /// is a stand-in, not an error. Absent on WEB too, by build policy; see
  /// [PartModelLibrary.assetFor].
  final String asset;

  /// Model units -> METRES, straight from [PartDef.modelScale].
  final double scale;

  /// Correction applied ON TOP of the standard glTF Y-up -> body Z-up fix, for
  /// exports whose authored axis is not the nose. Straight from
  /// [PartDef.modelRotation].
  final Quaternion rotation;

  /// Translation that seats the mesh on the PART ORIGIN: METRES in the part
  /// frame (Z-up, nose on +Z), straight from [PartDef.modelOffset]. Applied
  /// after [scale] and [rotation], so it reads in the part's own corrected
  /// axes — see `VesselNodes.partModelTransform` for the composition and why
  /// that order is the only usable one.
  final Vector3 offset;

  /// Longest component of [PartDef.size], METRES: the size of a UNIFORMLY
  /// scaled stand-in. `PartSnapshot` carries no bounding size, so without a
  /// route back to the catalog every part would draw as a 1 m blob.
  ///
  /// A caller that can scale per axis should read [PartDef.size] itself through
  /// [PartModelLibrary.defFor] — this collapses a box to one number, which
  /// draws a 1.25 x 1.25 x 1.9 m tank as a 1.9 m cube.
  final double fallbackSizeM;

  const PartModel({
    required this.asset,
    this.scale = 1.0,
    this.rotation = Quaternion.identity,
    this.offset = Vector3.zero,
    this.fallbackSizeM = 1.0,
  });

  /// This binding with one or more of the ART transform values replaced; the
  /// asset and the part's real size are not calibration and never change.
  /// Backs [PartModelLibrary.calibrate].
  PartModel withTransform({
    double? scale,
    Quaternion? rotation,
    Vector3? offset,
  }) =>
      PartModel(
        asset: asset,
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
        offset: offset ?? this.offset,
        fallbackSizeM: fallbackSizeM,
      );
}

/// Type key -> the catalog facts the renderer needs about a part: whether the
/// catalog knows it at all, which [PartDef] it is, what art it binds to, how
/// big it is, and whether it makes thrust. For craft rendered from their PART
/// LIST.
///
/// The key is `PartSnapshot.type`, which is the catalog [PartDef.id].
/// Lookups are pure map reads — no I/O, no GPU — because the render loop asks
/// "is this craft a catalog assembly?" for every vessel every frame before it
/// decides how to draw it.
///
/// ## Why the renderer needs the whole [PartDef], not just the art
///
/// A `PartSnapshot` carries a type key and a placement and nothing else — no
/// size, no category, no shape. Everything a renderer must know to draw a part
/// it has no bake for therefore has to be recovered from the catalog through
/// this key, which is why [defFor] exists alongside [lookup]: the procedural
/// stand-in is chosen by [PartDef.category] and scaled to [PartDef.size], and
/// neither is anywhere on the wire.
///
/// ## The catalog is the source of truth
///
/// Entries are SEEDED from [PartCatalog.standard]: every part that declares a
/// [PartDef.modelAsset] gets a binding built from its own `modelAsset`,
/// `modelScale`, `modelRotation`, `modelOffset` and `size`. Nothing here
/// restates those numbers.
///
/// That is deliberate and load-bearing. A part's attach nodes, its inertia box
/// and its art are all measured off the SAME export, so a scale written down
/// twice is a scale that will eventually be two different numbers — and the
/// failure is silent: the craft still flies correctly and simply looks wrong,
/// with parts floating out of their joints by the ratio between the two.
///
/// Adding art to a part is therefore a catalog edit — `modelAsset:` on the
/// [PartDef] — and never a change here. The one thing that may be set from
/// outside is a LIVE CALIBRATION override ([calibrate]), which is a dev tool
/// for settling a new export's numbers by screenshot and is meant to end up
/// pasted back into the catalog.
///
/// ## Web
///
/// There are no part bakes on web and there is no way to add one from this
/// file: see [assetFor] for what web draws instead and what it would take to
/// change that.
///
/// Keys are matched on a normalised form ([normalizeKey]): lower case with
/// runs of `-`, `_` and whitespace collapsed to a single `_`. Catalog ids are
/// kebab-case (`eagle-rcs-block`) while bakes are named after their `.glb`
/// basenames (`rcs_block.fsceneb`), so normalising means a hyphen/underscore
/// slip between the two cannot silently produce a craft with no art.
class PartModelLibrary {
  PartModelLibrary._();

  /// Global model-unit calibration multiplier, applied on top of each entry's
  /// [PartModel.scale] (and on top of any per-part [calibrate] override).
  /// Live-tunable from `ext.acro.camera?partScaleAll=` while calibrating a new
  /// part family: the renderer reapplies part transforms every frame, so a
  /// change lands on the next one. 1.0 means "trust the catalog".
  ///
  /// A sweep that settles on anything but 1.0 has found a wrong
  /// [PartDef.modelScale]; fold the result back into the catalog rather than
  /// leaving this off 1.0, or the next part family inherits the fudge.
  static double scaleMultiplier = 1.0;

  /// The catalog, read once and split into the tables the renderer indexes.
  /// ONE [PartCatalog.standard] build: it allocates the whole roster, and both
  /// tables are views of the same pass over it.
  static final ({
    Map<String, PartModel> models,
    Map<String, PartDef> defs,
  }) _tables = _seed();

  /// Bindings for parts that HAVE art, keyed by normalised catalog id.
  static Map<String, PartModel> get _models => _tables.models;

  /// EVERY catalog part, keyed the same way — the renderer's copy of the
  /// roster. Deliberately a separate table from [_models]: knowing what a part
  /// IS must not make the renderer think it has art (see [has] and
  /// [isCatalogPart], which answer different questions about the same key).
  static Map<String, PartDef> get _defs => _tables.defs;

  /// Live per-part overrides of the ART transform, keyed the same way. Empty
  /// unless a dev has called [calibrate]; checked before [_models] on the
  /// render path, which is one extra map read per part per frame.
  static final Map<String, PartModel> _calibrated = {};

  /// Build every table from the catalog in one pass. Runs once, lazily, on
  /// first lookup — building the standard catalog allocates a few dozen part
  /// definitions and is never on the render path.
  static ({
    Map<String, PartModel> models,
    Map<String, PartDef> defs,
  }) _seed() {
    final models = <String, PartModel>{};
    final defs = <String, PartDef>{};
    for (final def in PartCatalog.standard().all) {
      final key = normalizeKey(def.id);
      defs[key] = def;
      final asset = def.modelAsset;
      if (asset == null) continue;
      models[key] = PartModel(
        asset: asset,
        scale: def.modelScale,
        rotation: def.modelRotation,
        offset: def.modelOffset,
        fallbackSizeM: _longestSide(def.size),
      );
    }
    return (models: models, defs: defs);
  }

  /// The part's longest side, metres — the one number to hand a caller that
  /// can only apply a UNIFORM scale. The longest side is the only choice that
  /// never draws a stand-in smaller than the part it stands in for.
  static double _longestSide(Vector3 size) {
    var m = size.x;
    if (size.y > m) m = size.y;
    if (size.z > m) m = size.z;
    return m > 0 ? m : 1.0;
  }

  /// Memoised [normalizeKey] results. Type keys come from a fixed catalog, so
  /// this is bounded by the roster; it exists because the render loop
  /// normalises every part key of every vessel every frame.
  static final Map<String, String> _normalised = {};

  /// Canonical form of a part type key: lower case, with runs of `-`, `_` and
  /// whitespace collapsed to a single `_`. `Eagle-Command-Pod`,
  /// `eagle_command_pod` and `eagle command pod` are the same part.
  static String normalizeKey(String key) {
    var out = StringBuffer();
    var pendingSep = false;
    var started = false;
    for (final rune in key.trim().toLowerCase().runes) {
      final c = String.fromCharCode(rune);
      if (c == '-' || c == '_' || c == ' ' || c == '\t') {
        pendingSep = started;
        continue;
      }
      if (pendingSep) {
        out.write('_');
        pendingSep = false;
      }
      out.write(c);
      started = true;
    }
    return out.toString();
  }

  static String _key(String typeKey) =>
      _normalised[typeKey] ??= normalizeKey(typeKey);

  /// The CATALOG binding for [typeKey], or null when the part has no art at
  /// all. Ignores live calibration on purpose — this is what the catalog says,
  /// which is what a test or an asset check wants. To DRAW a part, use
  /// [resolve].
  static PartModel? lookup(String typeKey) => _models[_key(typeKey)];

  /// The binding to DRAW [typeKey] with: the live [calibrate] override when one
  /// is in force, else the catalog binding; null when the part has no art.
  ///
  /// Resolved per frame rather than cached on the scene node, so a calibration
  /// sweep lands on the next frame without rebuilding the craft.
  static PartModel? resolve(String typeKey) {
    final k = _key(typeKey);
    return _calibrated[k] ?? _models[k];
  }

  /// Whether [typeKey] has art REGISTERED.
  ///
  /// Platform-independent on purpose: a craft is assembled from its parts on
  /// every platform, or it would change shape between desktop and web. Whether
  /// this platform can actually load the bake is [assetFor]'s question.
  ///
  /// This is a question about ART, not about provenance. It says whether a bake
  /// is worth starting for one part, NOT whether the craft carrying it is drawn
  /// from its parts — that is [isCatalogPart], and conflating the two is what
  /// makes a craft with no bakes yet draw as an unrelated model.
  static bool has(String typeKey) => _models.containsKey(_key(typeKey));

  /// Whether the catalog knows [typeKey] at all — i.e. whether the part was
  /// stamped from a [PartDef] rather than built by hand.
  ///
  /// The renderer's provenance test. `PartSnapshot.type` is `Part.assetKey`,
  /// which is the catalog id for an assembled craft and a DISPLAY NAME for a
  /// hand-built one, and only the assembler ([VesselAssembler]) and the save
  /// codec that round-trips its output ever stamp an id. So "the catalog claims
  /// this key" is exactly "this part came out of a craft someone assembled",
  /// which is what decides whether the part list is the craft.
  ///
  /// Asked once per part per frame, so it must stay a map read.
  static bool isCatalogPart(String typeKey) => _defs.containsKey(_key(typeKey));

  /// The catalog part behind [typeKey], or null when nothing in the catalog
  /// claims that key (every hand-built part, and any key from an older save).
  ///
  /// The renderer's only route back to the facts a `PartSnapshot` does not
  /// carry: [PartDef.category] and [PartDef.size], which together decide the
  /// procedural silhouette a part with no bake is drawn as and how big it is
  /// drawn. Returns the catalog's own instance — a shared, immutable template,
  /// never a copy.
  static PartDef? defFor(String typeKey) => _defs[_key(typeKey)];

  /// Whether the catalog part behind [typeKey] produces thrust
  /// ([PartDef.isEngine]) — a rocket or a jet.
  ///
  /// The renderer cannot ask a `PartSnapshot` this: it carries a type key and
  /// nothing else. Keyed off the catalog rather than off the spelling of the
  /// key because neither spelling is reliable — a catalog id is
  /// `eagle-thruster` or `merlin-1d`, and a hand-built vessel reports a display
  /// name (`Raptor`, `Booster`) instead, so a substring test for "engine"
  /// matches neither. FALSE for every key the catalog does not know, which
  /// includes every hand-built part: callers need a sensible answer for "no
  /// engine located", not a guess.
  static bool isEngine(String typeKey) => _defs[_key(typeKey)]?.isEngine ?? false;

  /// The bake to load for [typeKey] on this platform, or null when there is
  /// none.
  ///
  /// NULL ON WEB, always. The web build ships no part bakes and cannot: the
  /// full-res exports push the GitHub Pages build over its size threshold, and
  /// Release assets are not CORS-enabled to fetch at runtime (the same reason
  /// the whole-craft models carry hand-made `*-web.fsceneb` reductions —
  /// `VesselNodes._apolloModelWeb`). No part has such a reduction, so there is
  /// nothing for web to load.
  ///
  /// What web therefore draws for a kitbash craft is the procedural stand-in
  /// for every part — grey primitives, but at each part's REAL size ([has]
  /// stays true so the craft is still assembled from its parts, and
  /// [fallbackSizeM] still knows how big each one is), which is why the shape
  /// and the staging still read correctly there.
  ///
  /// Making web draw art means BAKING reduced part exports and giving
  /// [PartDef] a web asset field to name them — a catalog and pipeline change,
  /// not a renderer one. Until those bakes exist there is nothing here to
  /// switch on, so this file does not pretend to have a hook for them.
  static String? assetFor(String typeKey) =>
      kIsWeb ? null : lookup(typeKey)?.asset;

  /// Size of the procedural stand-in for [typeKey], metres: the part's own
  /// longest side when the catalog knows it, else 1 m — the honest answer when
  /// nothing available to the renderer says how big the part is.
  ///
  /// ONE uniform number, which is all a caller with no [PartDef] can use. A
  /// caller that has one ([defFor]) should scale each axis to [PartDef.size]
  /// instead, because the longest side draws a 1.25 x 1.25 x 1.9 m tank as a
  /// 1.9 m cube.
  static double fallbackSizeM(String typeKey) {
    final k = _key(typeKey);
    final def = _defs[k];
    return _models[k]?.fallbackSizeM ??
        (def == null ? 1.0 : _longestSide(def.size));
  }

  /// Every key with art: what this registry ACTUALLY holds, as opposed to what
  /// the catalog declares.
  ///
  /// The two are meant to be the same set, and `attach_node_data_test` compares
  /// them — a key here with no catalog part behind it is art nothing can ever
  /// draw, because every screen builds its craft out of catalog parts. Screens
  /// that warm bakes (the craft editor) enumerate the CATALOG rather than this,
  /// so they cannot warm art no part claims.
  static Iterable<String> get keys => _models.keys;

  /// Override the ART transform of [typeKey] live, for settling a new export's
  /// numbers by screenshot; null arguments keep whatever is already in force.
  /// No-op for a part with no art — there is nothing to place.
  ///
  /// A calibration is a MEASUREMENT IN PROGRESS, not a setting: the values
  /// belong on the [PartDef] once the screenshot agrees, and
  /// [calibrationSource] prints them as the Dart literals to paste there.
  /// Nothing in a shipping build calls this; the writer is the dev extension
  /// (`ext.acro.camera?part=...`).
  static void calibrate(
    String typeKey, {
    double? scale,
    Quaternion? rotation,
    Vector3? offset,
  }) {
    final k = _key(typeKey);
    final base = _calibrated[k] ?? _models[k];
    if (base == null) return;
    _calibrated[k] =
        base.withTransform(scale: scale, rotation: rotation, offset: offset);
  }

  /// Drop every override, restoring the catalog's own numbers.
  static void resetCalibration() => _calibrated.clear();

  /// What every calibrated part would have to say in the catalog to keep the
  /// pose it is being drawn with — one entry per part, each value a map of
  /// [PartDef] field name to a PASTEABLE Dart literal. Empty until something
  /// calls [calibrate].
  ///
  /// Emitted as source text rather than numbers because that is the only form
  /// that ends the calibration loop: the sweep is over when the three lines
  /// are in `lem_parts.dart` and this map is empty again.
  static Map<String, Map<String, String>> calibrationSource() => {
        for (final e in _calibrated.entries)
          e.key: {
            'modelScale': _num(e.value.scale),
            'modelRotation': 'Quaternion(${_num(e.value.rotation.w)}, '
                '${_num(e.value.rotation.x)}, ${_num(e.value.rotation.y)}, '
                '${_num(e.value.rotation.z)})',
            'modelOffset': 'Vector3(${_num(e.value.offset.x)}, '
                '${_num(e.value.offset.y)}, ${_num(e.value.offset.z)})',
          },
      };

  /// A double as a short Dart literal: enough digits to reproduce a
  /// screenshot-settled value, without the 17-digit tail that makes a pasted
  /// constant unreadable.
  static String _num(double v) {
    final s = v.toStringAsFixed(6);
    var out = s.replaceFirst(RegExp(r'0+$'), '');
    if (out.endsWith('.')) out += '0';
    return out;
  }
}
