// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:flutter_test/flutter_test.dart';

/// One upload per pack per frame (flutter_scene, PATCHED): the depth
/// pre-pass and the colour pass draw the same instances of the same item at
/// the same transform, so the second pass binds the view the first emplaced
/// instead of pushing the same bytes through the shared instance host buffer
/// again. A city at close range measured ~4 MB of instance transforms a
/// frame, with shadow draws outnumbering colour draws two to one.
///
/// The rule pinned here: a view is reused only while BOTH the pack object
/// and the frame are the ones it was emplaced for. A repack (any instance
/// moved, the node moved, the winding flipped) makes a new pack object, and
/// a new frame cycles the buffer's storage — either must upload again, or a
/// draw would read bytes that have been overwritten.
void main() {
  test('the second pass of a frame reuses the first pass\'s view', () {
    final cache = PackedViewCache();
    final packed = Object(), view = Object();

    expect(cache.viewFor(packed, 7, ccw: true), isNull,
        reason: 'nothing emplaced yet');
    cache.remember(view, ccw: true);
    expect(cache.viewFor(packed, 7, ccw: true), same(view),
        reason: 'same pack, same frame: the depth pre-pass and the colour '
            'pass share one upload');
  });

  test('a new frame uploads again: its storage was cycled', () {
    final cache = PackedViewCache();
    final packed = Object();
    cache.viewFor(packed, 7, ccw: true);
    cache.remember(Object(), ccw: true);
    expect(cache.viewFor(packed, 8, ccw: true), isNull);
  });

  test('a repack uploads again, and drops the other parity too', () {
    final cache = PackedViewCache();
    final first = Object(), second = Object();
    cache.viewFor(first, 3, ccw: true);
    cache.remember(Object(), ccw: true);
    cache.viewFor(first, 3, ccw: false);
    cache.remember(Object(), ccw: false);
    expect(cache.viewFor(first, 3, ccw: true), isNotNull);

    // A moved instance repacks: a different object, even with equal bytes.
    expect(cache.viewFor(second, 3, ccw: true), isNull);
    expect(cache.viewFor(second, 3, ccw: false), isNull,
        reason: 'both parities dropped, not just the one asked for');
  });

  test('the two parities are cached apart', () {
    final cache = PackedViewCache();
    final packed = Object();
    final ccwView = Object(), cwView = Object();
    cache.viewFor(packed, 11, ccw: true);
    cache.remember(ccwView, ccw: true);
    expect(cache.viewFor(packed, 11, ccw: false), isNull);
    cache.remember(cwView, ccw: false);
    expect(cache.viewFor(packed, 11, ccw: true), same(ccwView));
    expect(cache.viewFor(packed, 11, ccw: false), same(cwView));
  });
}
