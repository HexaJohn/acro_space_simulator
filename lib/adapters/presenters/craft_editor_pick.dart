// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import '../../domain/craft/craft_design.dart';
import '../../domain/shared/vector3.dart';
import 'craft_editor_camera.dart';

/// The only geometry [CraftEditorPick.pickTarget] needs from a candidate: where
/// the attach node sits in the craft frame, its unit OUTWARD normal, and its
/// mating diameter in metres.
///
/// Passed as an extractor rather than a concrete type so this file stays a pure
/// function of camera and geometry. The editor supplies
/// `(tp) => (position: tp.target.positionInCraft,
///           direction: tp.target.directionInCraft, size: tp.target.size)`.
typedef TargetMarker = ({Vector3 position, Vector3 direction, double size});

/// The candidate the cursor resolved to, plus how many DISTINCT markers were in
/// range.
///
/// [alternatives] drives the cycle hint: a player who can see that three nodes
/// are under the cursor reaches for Tab instead of orbiting blindly. It counts
/// what is on screen, not what is legal behind it — one marker is one
/// alternative however many mates it can accept — because a hint promising four
/// candidates over a single chevron sends the player through three presses that
/// move nothing.
class PickedTarget<T> {
  final T pairing;
  final int alternatives;
  const PickedTarget(this.pairing, {required this.alternatives});
}

/// Screen-space picking for the craft editor: which attach target is under the
/// cursor, and which placed part is under the cursor.
///
/// Both are pure functions of `(camera, geometry, cursor)` with no widget, no
/// GPU and no scene graph, which is what lets the whole editor keep working
/// before a `.fsceneb` bake lands and forever if one fails to load.
class CraftEditorPick {
  const CraftEditorPick._();

  /// Grab radius for a mouse, logical pixels. Generous enough to forgive a hand
  /// tremor, tight enough that two nodes 40 px apart are never both candidates.
  static const double grabPxMouse = 22.0;

  /// Grab radius for a finger. 30 px is a >= 44 px tap diameter — a thumb, which
  /// is precisely why the rule is expressed in pixels and not in metres.
  static const double grabPxTouch = 30.0;

  /// Width of one ranking ring, logical pixels. Candidates inside the same ring
  /// are treated as equally close on screen and separated by depth instead.
  static const double ringPx = 8.0;

  /// Marker radius bounds, logical pixels. The floor keeps a 0.25 m RCS ring
  /// visible and hittable with the whole craft in frame; the ceiling stops a
  /// 4.2 m hull ring from swallowing the part it sits on at close zoom.
  ///
  /// [maxMarkerPx] must stay at or below [grabPxMouse]. The accept radius below
  /// is capped by the grab radius and floored by the drawn radius, so a marker
  /// painted wider than a mouse can reach would be a target refusing clicks
  /// inside its own outline — the exact failure the floor exists to remove.
  static const double minMarkerPx = 6.0;
  static const double maxMarkerPx = 20.0;

  /// A node whose outward normal points this far away from the eye is on the
  /// far side of the hull: picking demotes it two rings and the overlay draws
  /// it hollow and dim, so what is faint is exactly what is hard to hit.
  static const double awayFacingDot = 0.35;

  /// The radius a node marker occupies on screen at view depth [depthM],
  /// logical pixels. [sizeM] is the node's mating diameter, so the unclamped
  /// radius is half of it projected.
  ///
  /// THE one radius rule. The overlay paints with it and [pickTarget] accepts
  /// with it, because a marker that is drawn and a marker that can be clicked
  /// have to be one circle: two rules drift silently, and what the player sees
  /// then is a full-size, fully coloured node that ignores the pointer.
  static double markerRadiusPx(
          CraftEditorCamera cam, double sizeM, double depthM) =>
      (sizeM * 0.5 * cam.pxPerMetreAt(depthM)).clamp(minMarkerPx, maxMarkerPx);

  /// The nearest compatible target to [cursor], or null when nothing is in
  /// range. [markerOf] projects a candidate onto the geometry the ranking uses.
  ///
  /// Ranked in RINGS rather than by raw pixel distance. A pure `min(dPx)` picks
  /// the node on the FAR side of a tank whenever it happens to project one pixel
  /// nearer the cursor, which reads as the editor ignoring the click. Within an
  /// [ringPx] ring the candidates are equally close as far as the eye is
  /// concerned, so NEAREST TO THE CAMERA wins.
  ///
  /// [cycle] advances through the survivors in the same ranked order (Alt or Tab
  /// on desktop, repeat-tap on touch) so an ambiguous stack is always reachable.
  ///
  /// [identityOf] says which candidates are the SAME MARKER; by default every
  /// candidate is its own. Candidates sharing an identity collapse to the first
  /// one offered, which is what makes [PickedTarget.alternatives] and [cycle]
  /// count what is drawn rather than the mates behind it — a surface ring paired
  /// against a surface ring puts four legal mates on one chevron, and cycling
  /// through them would move the snap ring nowhere. Candidates sharing an
  /// identity MUST project to the same marker: the survivor keeps the first
  /// one's geometry.
  static PickedTarget<T>? pickTarget<T extends Object>(
    CraftEditorCamera cam,
    List<T> pairings,
    Offset cursor, {
    required TargetMarker Function(T pairing) markerOf,
    required bool touch,
    int cycle = 0,
    Object Function(T pairing)? identityOf,
  }) {
    final grab = touch ? grabPxTouch : grabPxMouse;
    // Keyed by identity and insertion-ordered, so which candidate survives a
    // collapsed group is the caller's order and never the sort's stability.
    final hits = <Object, ({int ring, double depth, T p})>{};

    for (final tp in pairings) {
      final key = identityOf == null ? tp : identityOf(tp);
      if (hits.containsKey(key)) continue;
      final t = markerOf(tp);
      final s = cam.project(t.position);
      if (s == null) continue;
      final depth = cam.depthOf(t.position);
      if (depth <= cam.nearM) continue;

      final dPx = (s - cursor).distance;
      // Accept radius = a SCREEN rule capped by a WORLD rule and floored by
      // what the marker actually PAINTS. The screen rule keeps the target
      // thumb-sized at every zoom; the world cap stops a zoomed-out view —
      // where the whole craft is 40 px tall — from snapping across the vehicle
      // to a node the player cannot even see; and the floor is the promise that
      // anywhere inside a drawn marker is inside its click target. Without it
      // the cap falls under [minMarkerPx] past about 55 m of eye distance and
      // the marker paints full size, in compatible colouring, while refusing
      // clicks — with nothing on screen to say why.
      final worldPx = 1.5 * math.max(t.size, 0.25) * cam.pxPerMetreAt(depth);
      final acceptPx =
          math.min(grab, math.max(worldPx, markerRadiusPx(cam, t.size, depth)));
      if (dPx > acceptPx) continue;

      // A node whose outward normal points away from the eye is on the far side
      // of a convex hull. Demote it two full rings rather than dropping it, so
      // it stays reachable by orbiting a little instead of vanishing.
      final away = t.direction.dot(cam.viewDirTo(t.position)) > awayFacingDot;
      hits[key] = (
        ring: (dPx / ringPx).floor() + (away ? 2 : 0),
        depth: depth,
        p: tp,
      );
    }
    if (hits.isEmpty) return null;
    final ranked = hits.values.toList()
      ..sort((a, b) =>
          a.ring != b.ring ? a.ring - b.ring : a.depth.compareTo(b.depth));
    return PickedTarget(ranked[cycle % ranked.length].p,
        alternatives: ranked.length);
  }

  /// The instance id of the nearest part under [cursor], or null.
  ///
  /// OBB-based, never mesh-based: picking therefore works on the first frame,
  /// before any bake has landed, and keeps working if one never does. The screen
  /// AABB of a rotated box over-covers by up to 41%, which is the right bias for
  /// a click target — easier to hit than to miss — and the depth ordering
  /// resolves the overlap that bias creates.
  static String? pickPart(
      CraftEditorCamera cam, CraftDesign design, Offset cursor) {
    String? hit;
    var hitDepth = double.infinity;
    for (final p in design.parts) {
      final depth = cam.depthOf(p.position);
      if (depth <= cam.nearM) continue;

      final h = p.def.size * 0.5;
      Rect? box;
      var clipped = false;
      for (final sx in const [-1.0, 1.0]) {
        for (final sy in const [-1.0, 1.0]) {
          for (final sz in const [-1.0, 1.0]) {
            final c = p.position +
                p.rotation.rotate(Vector3(sx * h.x, sy * h.y, sz * h.z));
            final s = cam.project(c);
            if (s == null) {
              clipped = true;
              break;
            }
            box = box == null
                ? Rect.fromPoints(s, s)
                : box.expandToInclude(Rect.fromPoints(s, s));
          }
          if (clipped) break;
        }
        if (clipped) break;
      }

      // 3 px of slop absorbs the difference between where the box edge lands and
      // where the player thinks the silhouette is.
      var inside = !clipped && box != null && box.inflate(3).contains(cursor);
      if (!inside) {
        // Rescue for thin parts: an 0.15 m solo thruster's box is about 6 px
        // across at working range, which is not a click target.
        final c = cam.project(p.position);
        final r =
            math.max(10.0, cam.pxPerMetreAt(depth) * p.def.size.length * 0.25);
        inside = c != null && (c - cursor).distance <= r;
      }
      if (inside && depth < hitDepth) {
        hit = p.instanceId;
        hitDepth = depth;
      }
    }
    return hit;
  }
}
