// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The scatter lab's sample-scene diorama, headless: the patch hunt must land
// somewhere worth demonstrating (trees, cover), the layout must be
// deterministic, and every placed prop must sit inside the patch ON the
// ground the diorama's terrain mesh is built from — a prop floating over the
// demo patch would advertise a placement bug that isn't there.

import 'package:acro_space_simulator/domain/scatter/sample_scene_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final layout = SampleSceneLayout.resolve();

  test('the hunt finds a habitat-rich patch', () {
    final byLayer = <String, int>{};
    for (final p in layout.instances) {
      final l = SampleSceneLayout.layerOf(p.kind);
      byLayer[l] = (byLayer[l] ?? 0) + 1;
    }
    expect(layout.instances.length, greaterThan(20),
        reason: 'a near-empty diorama demonstrates nothing ($byLayer)');
    expect(byLayer['forest'] ?? 0, greaterThanOrEqualTo(3),
        reason: 'the hunt requires trees — the patch scoring regressed '
            '($byLayer)');
    expect(byLayer.length, greaterThanOrEqualTo(2),
        reason: 'a one-layer patch is not the mix the demo exists to show '
            '($byLayer)');
  });

  test('the layout is deterministic', () {
    final again = SampleSceneLayout.resolve();
    expect(again.centreDir.x, layout.centreDir.x);
    expect(again.instances.length, layout.instances.length);
    for (var i = 0; i < layout.instances.length; i++) {
      expect(again.instances[i].positionBF.x, layout.instances[i].positionBF.x);
      expect(again.instances[i].seed, layout.instances[i].seed);
    }
  });

  test('every prop is inside the patch, standing on the meshed ground', () {
    for (final p in layout.instances) {
      final local = layout.toLocal(p.positionBF);
      final r = (local.x * local.x + local.y * local.y);
      expect(r,
          lessThanOrEqualTo(SampleSceneLayout.patchHalfM *
              SampleSceneLayout.patchHalfM),
          reason: 'prop escaped the patch circle');
      // The ground mesh samples the same field along dirAt(x, y); a prop's
      // base must meet it. The two parametrisations (radial position vs
      // gnomonic grid) differ only by curvature over 60 m on a 300 km body —
      // millimetres.
      final ground = layout.groundHeightAt(local.x, local.y);
      expect((local.z - ground).abs(), lessThan(0.2),
          reason: 'prop floats ${(local.z - ground).toStringAsFixed(2)} m '
              'off the diorama ground at (${local.x.toStringAsFixed(1)}, '
              '${local.y.toStringAsFixed(1)})');
    }
  });
}
