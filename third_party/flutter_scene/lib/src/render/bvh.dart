import 'dart:typed_data';

import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:vector_math/vector_math.dart';

/// A bounding volume hierarchy over the bounded [RenderItem]s of a
/// [RenderScene].
///
/// Built from each item's world-space AABB. A render pass queries it with
/// its view frustum to collect potentially-visible items without testing
/// every item in the scene.
///
/// Engine-internal; rebuilt by [RenderScene] when the scene changes.
class Bvh {
  Bvh._(this._root, this._pool);

  /// Builds a BVH over [items]. Every item must have a non-null
  /// [RenderItem.worldBounds].
  ///
  /// The build is O(n log n): it works over an index array, splitting
  /// each range at the median of the longest centroid axis with an
  /// in-place selection, so no per-level list copies or closure sorts
  /// happen. Pass the previous tree as [reuse] to recycle its node
  /// objects (and their AABBs) instead of allocating ~2n fresh ones; the
  /// reused tree must not be queried afterwards, since its nodes now
  /// belong to the new one.
  factory Bvh.build(List<RenderItem> items, {Bvh? reuse}) {
    final pool = reuse?._pool ?? <_BvhNode>[];
    if (items.isEmpty) return Bvh._(null, pool);
    final builder = _Builder(items, pool);
    return Bvh._(builder.build(0, items.length), pool);
  }

  final _BvhNode? _root;

  // Every node of this tree, handed to the next build so it can reuse
  // them. A full rebuild otherwise allocates a node and an AABB per item
  // twice over, which the city's tile streaming would do every few
  // seconds.
  final List<_BvhNode> _pool;

  /// Calls [visit] once for every live item whose world AABB intersects
  /// [frustum]. Leaves whose item was flagged [RenderItem.bvhDead] (removed
  /// from the scene since this tree was built) are skipped.
  void query(Frustum frustum, void Function(RenderItem) visit) {
    _query(_root, frustum, visit);
  }

  static void _query(
    _BvhNode? node,
    Frustum frustum,
    void Function(RenderItem) visit,
  ) {
    if (node == null) return;
    if (!frustum.intersectsWithAabb3(node.bounds)) return;
    final item = node.item;
    if (item != null) {
      if (!item.bvhDead) visit(item);
      return;
    }
    _query(node.left, frustum, visit);
    _query(node.right, frustum, visit);
  }

  /// Recomputes every node's AABB from the leaves' current
  /// [RenderItem.worldBounds] without changing the tree topology.
  ///
  /// Valid only while the item set and each leaf's item are unchanged
  /// since the build; a moved item is fine, an added or removed one
  /// needs a rebuild (a removed one is tolerated as a dead leaf: its
  /// bounds are left as built, which is conservative because the query
  /// never visits it). Cheaper than a rebuild (O(n), no sort), but tree
  /// quality degrades as items drift from their build-time grouping.
  void refit() {
    _refit(_root);
  }

  static void _refit(_BvhNode? node) {
    if (node == null) return;
    final item = node.item;
    if (item != null) {
      // A dead leaf's item may have lost its bounds after removal; keep
      // the build-time box rather than read a null.
      if (!item.bvhDead) node.bounds.copyFrom(item.worldBounds!);
      return;
    }
    _refit(node.left);
    _refit(node.right);
    node.bounds
      ..copyFrom(node.left!.bounds)
      ..hull(node.right!.bounds);
  }
}

/// The scratch state of one [Bvh.build]: the items, their centroids in a
/// flat primitive array, the index permutation the split partitions in
/// place, and the node pool being (re)filled.
class _Builder {
  _Builder(this.items, this.pool)
    : centroids = Float64List(items.length * 3),
      order = Int32List(items.length) {
    for (int i = 0; i < items.length; i++) {
      final bounds = items[i].worldBounds!;
      final min = bounds.min;
      final max = bounds.max;
      centroids[i * 3] = (min.x + max.x) * 0.5;
      centroids[i * 3 + 1] = (min.y + max.y) * 0.5;
      centroids[i * 3 + 2] = (min.z + max.z) * 0.5;
      order[i] = i;
    }
  }

  final List<RenderItem> items;
  final List<_BvhNode> pool;

  // Centroid of each item's world AABB, xyz interleaved; the split key.
  final Float64List centroids;

  // Item indices; each build range [lo, hi) is a contiguous slice of this
  // array that the median selection rearranges in place.
  final Int32List order;

  int _used = 0;

  _BvhNode _takeNode() {
    if (_used < pool.length) return pool[_used++];
    final node = _BvhNode();
    pool.add(node);
    _used++;
    return node;
  }

  /// Builds the subtree over `order[lo..hi)` and returns its root.
  _BvhNode build(int lo, int hi) {
    final node = _takeNode();
    final bounds = node.bounds;

    // Node bounds: the hull of every item in the range. The centroid
    // extent per axis rides along in the same loop; it picks the split
    // axis below.
    bounds.copyFrom(items[order[lo]].worldBounds!);
    double cMinX = centroids[order[lo] * 3];
    double cMinY = centroids[order[lo] * 3 + 1];
    double cMinZ = centroids[order[lo] * 3 + 2];
    double cMaxX = cMinX, cMaxY = cMinY, cMaxZ = cMinZ;
    for (int i = lo + 1; i < hi; i++) {
      final index = order[i];
      bounds.hull(items[index].worldBounds!);
      final x = centroids[index * 3];
      final y = centroids[index * 3 + 1];
      final z = centroids[index * 3 + 2];
      if (x < cMinX) cMinX = x;
      if (x > cMaxX) cMaxX = x;
      if (y < cMinY) cMinY = y;
      if (y > cMaxY) cMaxY = y;
      if (z < cMinZ) cMinZ = z;
      if (z > cMaxZ) cMaxZ = z;
    }

    if (hi - lo == 1) {
      node
        ..item = items[order[lo]]
        ..left = null
        ..right = null;
      return node;
    }

    // Split the longest axis of the centroid spread at the median.
    int axis = 0;
    double longest = cMaxX - cMinX;
    final spanY = cMaxY - cMinY;
    if (spanY > longest) {
      axis = 1;
      longest = spanY;
    }
    if (cMaxZ - cMinZ > longest) {
      axis = 2;
    }
    final mid = (lo + hi) >> 1;
    _select(lo, hi, mid, axis);

    node.item = null;
    node.left = build(lo, mid);
    node.right = build(mid, hi);
    return node;
  }

  double _key(int position, int axis) => centroids[order[position] * 3 + axis];

  void _swap(int a, int b) {
    final t = order[a];
    order[a] = order[b];
    order[b] = t;
  }

  /// Rearranges `order[lo..hi)` so that position [k] holds the element it
  /// would hold if the range were sorted by centroid [axis], with every
  /// key before it no larger and every key after it no smaller
  /// (`nth_element`). Hoare partitioning around a median-of-three pivot;
  /// it copes with runs of equal keys (co-located instances) without the
  /// quadratic blow-up a Lomuto partition would show.
  void _select(int lo, int hi, int k, int axis) {
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      final a = _key(lo, axis);
      final b = _key(mid, axis);
      final c = _key(hi - 1, axis);
      final double pivot;
      if (a < b) {
        pivot = b < c ? b : (a < c ? c : a);
      } else {
        pivot = a < c ? a : (b < c ? c : b);
      }
      int i = lo;
      int j = hi - 1;
      while (i <= j) {
        while (_key(i, axis) < pivot) {
          i++;
        }
        while (_key(j, axis) > pivot) {
          j--;
        }
        if (i <= j) {
          _swap(i, j);
          i++;
          j--;
        }
      }
      // Now [lo..j] <= pivot and [i..hi) >= pivot; anything strictly
      // between holds the pivot value and is already in place.
      if (k <= j) {
        hi = j + 1;
      } else if (k >= i) {
        lo = i;
      } else {
        return;
      }
    }
  }
}

/// A tree node. Mutable so a rebuild can recycle it; a leaf holds exactly
/// one item and no children.
class _BvhNode {
  /// Non-null for a leaf, which holds exactly one render item.
  RenderItem? item;
  _BvhNode? left;
  _BvhNode? right;

  /// AABB enclosing every item under this node.
  final Aabb3 bounds = Aabb3();
}
