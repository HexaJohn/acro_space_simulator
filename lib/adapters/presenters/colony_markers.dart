// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where the known colonies are, as HUD markers over the flight view: each
/// colony's centre on the ground, projected onto the screen from wherever the
/// camera is — orbit, another body, the surface — the way trajectory lines are
/// drawn whatever the distance.
///
/// Pure: the colonies (as body-fixed ground points), the frame's body poses
/// and the camera's projection in; the markers that can be seen out. A marker
/// is hidden behind its own body's horizon, behind any other body, behind the
/// eye, and when the camera is nearly at it (the colony itself is then the
/// thing on screen).
library;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';

/// What a marker says about its colony, which its colour shows.
enum ColonyMarkerStatus {
  /// Takes the player's orders.
  yours,

  /// Restless enough to matter: in standoff, or its port seized.
  unrest,

  /// Held by the player's garrison.
  occupied,

  /// Broken away.
  independent,

  /// An operation is being fought there.
  battle,
}

/// One colony to mark.
class ColonyMarkerInput {
  const ColonyMarkerInput({
    required this.id,
    required this.name,
    required this.bodyId,
    required this.bodyFixed,
    required this.status,
    this.hideWithinM = kColonyMarkerNearM,
  });
  final String id;
  final String name;
  final String bodyId;

  /// Its centre on the ground, body-fixed metres.
  final Vector3 bodyFixed;
  final ColonyMarkerStatus status;

  /// No marker with the eye this close: the colony itself is on screen.
  final double hideWithinM;
}

/// One marker as seen: screen pixels from the screen centre (x right, y up,
/// as `SceneCamera.projectPx` gives them) and the eye's distance to it.
class ColonyMark {
  const ColonyMark({
    required this.id,
    required this.name,
    required this.status,
    required this.x,
    required this.y,
    required this.distanceM,
  });
  final String id;
  final String name;
  final ColonyMarkerStatus status;
  final double x, y;
  final double distanceM;
}

/// The camera is "at" a colony inside this range, m: no marker.
const double kColonyMarkerNearM = 3000;

/// The colony open in the editor is the view's subject: marked only from
/// this far out, m, where it has shrunk to a speck.
const double kOpenColonyMarkerNearM = 50000;

/// The markers [colonies] make in the frame [bodies], seen from the eye at
/// [focus] + [eyeOffset] (world metres) through [project] (focus-relative
/// world point → centre-relative pixels, null behind the eye), nearest first.
List<ColonyMark> projectColonyMarkers({
  required List<ColonyMarkerInput> colonies,
  required Map<String, BodySnapshot> bodies,
  required Vector3 focus,
  required Vector3 eyeOffset,
  required ({double x, double y})? Function(Vector3 rel) project,
}) {
  final eye = focus + eyeOffset;
  final out = <ColonyMark>[];
  for (final c in colonies) {
    final b = bodies[c.bodyId];
    if (b == null) continue;
    final centre = Vector3(b.px, b.py, b.pz);
    final at = centre + Quaternion(b.qw, b.qx, b.qy, b.qz).rotate(c.bodyFixed);
    final toEye = eye - at;
    final d = toEye.length;
    if (d < c.hideWithinM) continue;
    // Its own body: on the near side of the horizon. The ground point sits
    // on the sphere, so the plane through it, square to its radial, is the
    // horizon's: the eye must be above that plane.
    if ((at - centre).dot(toEye) <= 0) continue;
    if (_hiddenByAnother(c.bodyId, eye, at, bodies)) continue;
    final p = project(at - focus);
    if (p == null) continue;
    out.add(ColonyMark(id: c.id, name: c.name, status: c.status, x: p.x, y: p.y, distanceM: d));
  }
  out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
  return out;
}

/// Whether a body other than [ownId] stands between [eye] and [at].
bool _hiddenByAnother(String ownId, Vector3 eye, Vector3 at, Map<String, BodySnapshot> bodies) {
  final seg = at - eye;
  final len2 = seg.dot(seg);
  if (len2 <= 0) return false;
  for (final b in bodies.values) {
    if (b.id == ownId || b.radius <= 0) continue;
    final c = Vector3(b.px, b.py, b.pz);
    final t = ((c - eye).dot(seg) / len2).clamp(0.0, 1.0);
    final closest = eye + seg * t;
    if ((closest - c).length < b.radius) return true;
  }
  return false;
}

/// A distance as a marker reads it: tenths of a km close, whole km out to a
/// million, Gm past that.
String colonyMarkerDistance(double m) {
  if (m < 10e3) return '${(m / 1000).toStringAsFixed(1)} km';
  if (m < 1e9) return '${(m / 1000).round()} km';
  return '${(m / 1e9).toStringAsFixed(1)} Gm';
}
