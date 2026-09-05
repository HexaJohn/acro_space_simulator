import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/material/material.dart';
import 'package:vector_math/vector_math.dart';

/// Many copies of one [Geometry] / [Material] pair, each placed by its
/// own model transform.
///
/// Use an `InstancedMesh` for foliage, crowds, debris, or any scene that
/// holds many copies of the same mesh. Attach it to a node with an
/// [InstancedMeshComponent]; the whole set is then one render item, one
/// pipeline, and one cull test rather than one node per copy.
///
/// Phase 3c carries a per-instance transform only. The naive backend
/// still issues one draw call per instance.
/// {@category Scene graph}
class InstancedMesh {
  /// Creates an instanced mesh that draws [geometry] shaded by
  /// [material]. It starts with no instances; add them with
  /// [addInstance].
  InstancedMesh({required this.geometry, required this.material});

  /// The geometry drawn for every instance.
  final Geometry geometry;

  /// The material every instance is shaded with.
  final Material material;

  final List<Matrix4> _instances = [];

  Aabb3? _boundsCache;
  bool _boundsDirty = true;
  int _version = 0;

  /// The number of instances.
  int get instanceCount => _instances.length;

  /// Bumped by every instance change ([addInstance],
  /// [setInstanceTransform], [removeInstanceAt], [clearInstances]).
  ///
  /// The render item and the instance-transform pack cache compare it
  /// against the version they last saw, so a static instanced mesh (a
  /// city's street furniture, say) costs nothing per frame while a
  /// moving one (traffic) refreshes as before. Mutating a matrix from
  /// [instances] in place bypasses it; go through [setInstanceTransform].
  int get version => _version;

  /// Adds an instance placed by [transform] and returns its index.
  ///
  /// The matrix is copied, so later mutating [transform] does not affect
  /// the instance; use [setInstanceTransform] to move it.
  int addInstance(Matrix4 transform) {
    _instances.add(transform.clone());
    _boundsDirty = true;
    _version++;
    return _instances.length - 1;
  }

  /// Replaces the transform of the instance at [index].
  void setInstanceTransform(int index, Matrix4 transform) {
    _instances[index].setFrom(transform);
    _boundsDirty = true;
    _version++;
  }

  /// Removes the instance at [index]. Instances after it shift down by
  /// one, so their indices change.
  void removeInstanceAt(int index) {
    _instances.removeAt(index);
    _boundsDirty = true;
    _version++;
  }

  /// Removes every instance.
  void clearInstances() {
    _instances.clear();
    _boundsDirty = true;
    _version++;
  }

  /// The live per-instance transform list the render item iterates.
  @internal
  List<Matrix4> get instances => _instances;

  /// Aggregate AABB over every instance, in the instanced mesh's local
  /// space, or `null` when [geometry] has no computable bounds or there
  /// are no instances. Cached; recomputed after any instance change.
  @internal
  Aabb3? get aggregateBounds {
    if (_boundsDirty) {
      _boundsCache = _computeAggregateBounds();
      _boundsDirty = false;
    }
    return _boundsCache;
  }

  Aabb3? _computeAggregateBounds() {
    final base = geometry.localBounds;
    if (base == null || _instances.isEmpty) return null;
    final baseMin = base.min;
    final baseMax = base.max;
    final minX = baseMin.x, minY = baseMin.y, minZ = baseMin.z;
    final maxX = baseMax.x, maxY = baseMax.y, maxZ = baseMax.z;

    // Each instance's transformed box is folded straight into the running
    // hull as six doubles: per output axis, the translation plus the
    // smaller (larger) of each column entry times the box's min or max
    // along that input axis. That is the box the eight transformed
    // corners span, for any affine transform, with no temporaries; the
    // old per-instance `Aabb3.copy` made traffic-sized instance lists
    // allocate a few thousand objects a frame.
    double hullMinX = double.infinity;
    double hullMinY = double.infinity;
    double hullMinZ = double.infinity;
    double hullMaxX = double.negativeInfinity;
    double hullMaxY = double.negativeInfinity;
    double hullMaxZ = double.negativeInfinity;
    for (final transform in _instances) {
      final m = transform.storage;
      // Column-major: m[col * 4 + row]. Row `r` of the 3x3 block gathers
      // output axis `r` from the three input axes.
      double lo = m[12], hi = m[12];
      double a = m[0] * minX, b = m[0] * maxX;
      lo += a < b ? a : b;
      hi += a < b ? b : a;
      a = m[4] * minY;
      b = m[4] * maxY;
      lo += a < b ? a : b;
      hi += a < b ? b : a;
      a = m[8] * minZ;
      b = m[8] * maxZ;
      lo += a < b ? a : b;
      hi += a < b ? b : a;
      if (lo < hullMinX) hullMinX = lo;
      if (hi > hullMaxX) hullMaxX = hi;

      lo = m[13];
      hi = m[13];
      a = m[1] * minX;
      b = m[1] * maxX;
      lo += a < b ? a : b;
      hi += a < b ? b : a;
      a = m[5] * minY;
      b = m[5] * maxY;
      lo += a < b ? a : b;
      hi += a < b ? b : a;
      a = m[9] * minZ;
      b = m[9] * maxZ;
      lo += a < b ? a : b;
      hi += a < b ? b : a;
      if (lo < hullMinY) hullMinY = lo;
      if (hi > hullMaxY) hullMaxY = hi;

      lo = m[14];
      hi = m[14];
      a = m[2] * minX;
      b = m[2] * maxX;
      lo += a < b ? a : b;
      hi += a < b ? b : a;
      a = m[6] * minY;
      b = m[6] * maxY;
      lo += a < b ? a : b;
      hi += a < b ? b : a;
      a = m[10] * minZ;
      b = m[10] * maxZ;
      lo += a < b ? a : b;
      hi += a < b ? b : a;
      if (lo < hullMinZ) hullMinZ = lo;
      if (hi > hullMaxZ) hullMaxZ = hi;
    }
    return Aabb3.minMax(
      Vector3(hullMinX, hullMinY, hullMinZ),
      Vector3(hullMaxX, hullMaxY, hullMaxZ),
    );
  }
}
