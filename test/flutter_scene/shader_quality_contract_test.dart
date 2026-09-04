// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The contract between the Dart presets and the GLSL that consumes them.
//
// GLSL needs a compile-time loop bound, so the quality uniform can only clamp
// BELOW the shader's own VIEW_SAMPLES / LIGHT_SAMPLES. That makes the failure
// mode silent in both directions: raise a preset past the ceiling and "Ultra"
// renders as the ceiling; lower the ceiling and every preset above it
// collapses onto it. Neither shows up as an error anywhere — the picture just
// stops responding to the slider.
//
// Reading the constants straight out of the .frag is the only way to keep the
// two files honest about each other.

import 'dart:io';

import 'package:acro_space_simulator/infrastructure/flutter_scene/graphics_quality.dart';
import 'package:flutter_test/flutter_test.dart';

int _constIntIn(String source, String name) {
  final m = RegExp(r'const\s+int\s+' + name + r'\s*=\s*(\d+)\s*;')
      .firstMatch(source);
  expect(m, isNotNull, reason: 'no `const int $name` in the shader');
  return int.parse(m!.group(1)!);
}

void main() {
  final clouds = File('shaders/clouds.frag');
  final atmosphere = File('shaders/atmosphere.frag');

  setUpAll(() {
    // Guards against a runner with a different working directory quietly
    // turning every assertion below into a vacuous pass.
    expect(clouds.existsSync(), isTrue, reason: 'run from the package root');
    expect(atmosphere.existsSync(), isTrue);
  });

  test('the Dart ceilings match the shader constants', () {
    final c = clouds.readAsStringSync();
    expect(_constIntIn(c, 'VIEW_SAMPLES'), kMaxCloudViewSamples);
    expect(_constIntIn(c, 'LIGHT_SAMPLES'), kMaxCloudLightSamples);

    final a = atmosphere.readAsStringSync();
    expect(_constIntIn(a, 'VIEW_SAMPLES'), kMaxAtmoViewSamples);
    expect(_constIntIn(a, 'LIGHT_SAMPLES'), kMaxAtmoLightSamples);
  });

  test('no preset asks for more than the shader can give', () {
    for (final level in QualityLevel.values) {
      final c = CloudQuality.of(level);
      expect(c.viewSampleCap, lessThanOrEqualTo(kMaxCloudViewSamples),
          reason: '${level.name} clouds would be silently clamped');
      expect(c.lightSamples, lessThanOrEqualTo(kMaxCloudLightSamples),
          reason: '${level.name} cloud light march would be silently clamped');

      final l = LightingQuality.of(level);
      expect(l.atmoViewSamples, lessThanOrEqualTo(kMaxAtmoViewSamples),
          reason: '${level.name} sky would be silently clamped');
      expect(l.atmoLightSamples, lessThanOrEqualTo(kMaxAtmoLightSamples));
    }
  });

  test('both shaders still declare the quality uniform', () {
    // The Dart side writes fixed float offsets into these blocks. Dropping or
    // reordering the member would corrupt neighbouring uniforms rather than
    // fail loudly, so pin that it is present and LAST — the offsets in
    // cloud_nodes/atmosphere_nodes assume it sits at the end of the block.
    for (final f in [clouds, atmosphere]) {
      final src = f.readAsStringSync();
      final block =
          RegExp(r'uniform\s+\w+\s*\{(.*?)\}', dotAll: true).firstMatch(src);
      expect(block, isNotNull, reason: '${f.path}: no uniform block');
      final members = RegExp(r'vec4\s+(\w+)\s*;')
          .allMatches(block!.group(1)!)
          .map((m) => m.group(1))
          .toList();
      expect(members.last, 'quality',
          reason: '${f.path}: quality must stay the last vec4 — the Dart '
              'packing writes it at a fixed offset');
    }
  });

  test('the float offsets the Dart side writes match the block sizes', () {
    // CloudInfo is 11 vec4s (44 floats), AtmosphereInfo 6 (24). Verified
    // against impellerc reflection: quality lands at float 40 and 20.
    final cloudMembers = RegExp(r'vec4\s+\w+\s*;')
        .allMatches(RegExp(r'uniform\s+CloudInfo\s*\{(.*?)\}', dotAll: true)
            .firstMatch(clouds.readAsStringSync())!
            .group(1)!)
        .length;
    expect(cloudMembers, 11);
    expect((cloudMembers - 1) * 4, 40, reason: 'quality starts at float 40');

    final atmoMembers = RegExp(r'vec4\s+\w+\s*;')
        .allMatches(
            RegExp(r'uniform\s+AtmosphereInfo\s*\{(.*?)\}', dotAll: true)
                .firstMatch(atmosphere.readAsStringSync())!
                .group(1)!)
        .length;
    expect(atmoMembers, 6);
    expect((atmoMembers - 1) * 4, 20, reason: 'quality starts at float 20');
  });

  test('the shader switches on the same mode codes the Dart enum carries', () {
    // The encoding lives in two files that nothing else ties together: a
    // renumbered enum or an edited shader literal would silently select the
    // wrong technique — flat where full was asked, or the sentinel path for
    // everything. Pin the exact literals on both sides.
    final c = clouds.readAsStringSync();
    expect(c.contains('cloud_info.quality.w == 1.0'), isTrue,
        reason: 'flat gate must test the flat wire code');
    expect(c.contains('cloud_info.quality.w == 2.0'), isTrue,
        reason: 'reduced gate must test the reduced wire code');
    expect(CloudRenderMode.flat.wire, 1);
    expect(CloudRenderMode.reduced.wire, 2);
    expect(CloudRenderMode.full.wire, 3,
        reason: 'full has no gate — any w not 1 or 2 (including the 0 '
            'sentinel) takes the full path, so 3 must stay off both literals');
  });

  test('the shells stay at the tessellation the depth proxy needs', () {
    // Not a quality knob, however tempting: a 48x24 facet chord sags ~13.6 km
    // below the true sphere on Earth — deeper than the proxy's ~6.4 km lift —
    // so the facet interiors fall inside the opaque planet, fail the depth
    // test, and the disc haze vanishes the moment the camera enters the shell.
    // Both node files document this; pin it so a future scalability pass
    // cannot quietly reintroduce the bug.
    for (final path in [
      'lib/infrastructure/flutter_scene/atmosphere_nodes.dart',
      'lib/infrastructure/flutter_scene/cloud_nodes.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src.contains('uvSphereZUp(segments: 96, rings: 48)'), isTrue,
          reason: '$path: the surface proxy must stay 96x48');
    }
  });
}
