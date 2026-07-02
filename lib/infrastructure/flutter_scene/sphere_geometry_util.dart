import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;

/// Unit UV sphere, Z-UP (poles on ±Z, matching the domain spin axis), with
/// the equirect U direction chosen to read correctly through the
/// image-level chirality flip in SceneRenderView.
///
/// Why not stock [fs.SphereGeometry]: its poles sit on ±Y (planets render
/// with a pole on the equator), and rotating it into place cannot fix the
/// texture chirality — the final image flip mirrors its map horizontally,
/// and no rotation un-mirrors. A first version of this builder showed a
/// pale backface veil: its triangle winding was inward (front faces
/// culled); the winding below is outward (CCW from outside).
fs.MeshGeometry uvSphereZUp({
  int segments = 96,
  int rings = 48,
}) {
  final positions = <double>[];
  final normals = <double>[];
  final texCoords = <double>[];
  final indices = <int>[];
  for (var r = 0; r <= rings; r++) {
    final phi = math.pi * r / rings; // 0..pi from +Z pole
    final v = r / rings; // v=0 north pole (equirect row order)
    for (var s = 0; s <= segments; s++) {
      final theta = 2 * math.pi * s / segments;
      final x = math.sin(phi) * math.cos(theta);
      final y = math.sin(phi) * math.sin(theta);
      final z = math.cos(phi);
      positions.addAll([x, y, z]);
      normals.addAll([x, y, z]);
      // U runs WITH theta: through the final flipX the map then reads
      // west-to-east correctly. (Mirror the sign here if geography ever
      // reads backwards again — one knob, one meaning.)
      texCoords.addAll([s / segments, v]);
    }
  }
  for (var r = 0; r < rings; r++) {
    for (var s = 0; s < segments; s++) {
      final a = r * (segments + 1) + s;
      final b = a + segments + 1;
      // Outward (counter-clockwise seen from outside the sphere).
      indices.addAll([a, a + 1, b, b, a + 1, b + 1]);
    }
  }
  return fs.MeshGeometry.fromArrays(
    positions: Float32List.fromList(positions),
    normals: Float32List.fromList(normals),
    texCoords: Float32List.fromList(texCoords),
    indices: indices,
  );
}
