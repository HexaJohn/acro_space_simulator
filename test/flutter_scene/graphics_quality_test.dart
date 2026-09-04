// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The scalability ladder. Two things here are easy to get wrong silently and
// expensive to notice later:
//
//  - HIGH must reproduce the pre-slider constants exactly, or shipping the
//    slider changes the default look for everyone who never opens options.
//  - ULTRA must fit under the shaders' compile-time ceilings. GLSL needs a
//    constant loop bound, so the uniform can only clamp BELOW it; a preset
//    that asks for more is silently ignored and "Ultra" quietly renders as
//    whatever the ceiling happens to be.

import 'package:acro_space_simulator/infrastructure/flutter_scene/graphics_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(GraphicsQuality.reset);
  tearDown(GraphicsQuality.reset);

  group('the ladder', () {
    test('High is exactly what the shaders carried before the slider', () {
      // clouds.frag: VIEW_SAMPLES 40, pitch 10.0, LIGHT_SAMPLES 5, and the
      // full volumetric path — mode is part of the look, not just the cost.
      expect(CloudQuality.high.viewSampleCap, 40);
      expect(CloudQuality.high.samplePitch, 10);
      expect(CloudQuality.high.lightSamples, 5);
      expect(CloudQuality.high.mode, CloudRenderMode.full);
      expect(CloudQuality.ultra.mode, CloudRenderMode.full);
      // atmosphere.frag: VIEW_SAMPLES 12, LIGHT_SAMPLES 6.
      expect(LightingQuality.high.atmoViewSamples, 12);
      expect(LightingQuality.high.atmoLightSamples, 6);
      // environment_baker.dart: 256x128 on a 3 s floor.
      expect(LightingQuality.high.envBakeWidth, 256);
      expect(LightingQuality.high.envBakeHeight, 128);
      expect(LightingQuality.high.envBakeInterval, const Duration(seconds: 3));
    });

    test('High is the shipped default', () {
      expect(GraphicsQuality.master, QualityLevel.high);
      expect(GraphicsQuality.clouds.viewSampleCap,
          CloudQuality.high.viewSampleCap);
      expect(GraphicsQuality.lighting.atmoViewSamples,
          LightingQuality.high.atmoViewSamples);
    });

    test('Ultra fits under the shaders compile-time ceilings', () {
      expect(CloudQuality.ultra.viewSampleCap,
          lessThanOrEqualTo(kMaxCloudViewSamples));
      expect(CloudQuality.ultra.lightSamples,
          lessThanOrEqualTo(kMaxCloudLightSamples));
      expect(LightingQuality.ultra.atmoViewSamples,
          lessThanOrEqualTo(kMaxAtmoViewSamples));
      expect(LightingQuality.ultra.atmoLightSamples,
          lessThanOrEqualTo(kMaxAtmoLightSamples));
    });

    test('every rung is strictly cheaper than the one above it', () {
      for (var i = 1; i < QualityLevel.values.length; i++) {
        final lower = QualityLevel.values[i - 1];
        final upper = QualityLevel.values[i];
        final c = CloudQuality.of(lower), cu = CloudQuality.of(upper);
        // Noise cost, not sample count: the flat rung's nominal sample
        // fields are irrelevant to what it actually spends.
        expect(c.approxNoiseCost, lessThan(cu.approxNoiseCost),
            reason: 'clouds ${lower.name} -> ${upper.name}');
        expect(c.samplePitch, lessThan(cu.samplePitch),
            reason: 'cloud pitch ${lower.name} -> ${upper.name}');

        final l = LightingQuality.of(lower), lu = LightingQuality.of(upper);
        expect(l.worstCaseSamples, lessThan(lu.worstCaseSamples),
            reason: 'lighting ${lower.name} -> ${upper.name}');
        expect(l.envBakeWidth, lessThan(lu.envBakeWidth));
        // A cheaper rung must re-bake LESS often, not more.
        expect(l.envBakeInterval, greaterThan(lu.envBakeInterval));
      }
    });

    test('Low actually buys something worth the visual cost', () {
      // Low is the flat shell: one full + one Lo field evaluation against a
      // worst-case limb march. If a future edit quietly flips Low back to a
      // volumetric mode, the ratio collapses and this catches it.
      final ratio = CloudQuality.high.approxNoiseCost /
          CloudQuality.low.approxNoiseCost;
      expect(ratio, greaterThan(50.0),
          reason: 'cloud Low is $ratio x cheaper');
      final lRatio = LightingQuality.high.worstCaseSamples /
          LightingQuality.low.worstCaseSamples;
      expect(lRatio, greaterThan(3.0), reason: 'sky Low is $lRatio x cheaper');
    });

    test('the technique ladder is flat -> reduced -> full', () {
      expect(CloudQuality.low.mode, CloudRenderMode.flat);
      expect(CloudQuality.medium.mode, CloudRenderMode.reduced);
      // Wire codes are what clouds.frag switches on; 0 stays reserved as the
      // "block never packed" sentinel that the shader reads as full.
      expect(CloudRenderMode.flat.wire, 1);
      expect(CloudRenderMode.reduced.wire, 2);
      expect(CloudRenderMode.full.wire, 3);
      for (final m in CloudRenderMode.values) {
        expect(m.wire, isNot(0), reason: '0 is the unset sentinel');
      }
    });

    test('every rung has a sane pitch floor', () {
      // The shader clamps the adaptive count to at least min(pitch, cap), so a
      // pitch above the cap would pin every ray to the cap and throw the
      // adaptivity away.
      for (final level in QualityLevel.values) {
        final q = CloudQuality.of(level);
        expect(q.samplePitch, lessThan(q.viewSampleCap.toDouble()),
            reason: '${level.name}: pitch must stay under the cap');
      }
    });
  });

  group('master and overrides', () {
    test('the master moves everything that has no override', () {
      GraphicsQuality.setMaster(QualityLevel.low);
      expect(GraphicsQuality.cloudLevel, QualityLevel.low);
      expect(GraphicsQuality.lightingLevel, QualityLevel.low);
      expect(GraphicsQuality.clouds.viewSampleCap,
          CloudQuality.low.viewSampleCap);
      expect(GraphicsQuality.isCustom, isFalse);
    });

    test('an override departs from the master, and only for its own half', () {
      GraphicsQuality.setMaster(QualityLevel.high);
      GraphicsQuality.cloudOverride = QualityLevel.low;
      expect(GraphicsQuality.cloudLevel, QualityLevel.low);
      expect(GraphicsQuality.lightingLevel, QualityLevel.high);
      expect(GraphicsQuality.isCustom, isTrue);
    });

    test('an override equal to the master does not read as custom', () {
      // Dragging an override back onto the master must clear the CUSTOM label,
      // else it sticks forever with no way to shift it but the reset button.
      GraphicsQuality.setMaster(QualityLevel.medium);
      GraphicsQuality.cloudOverride = QualityLevel.medium;
      expect(GraphicsQuality.isCustom, isFalse);
    });

    test('moving the master drops the overrides', () {
      // The whole point of the master is "make everything cheaper". If a stale
      // override survived it, someone who had once set Clouds=Ultra could drag
      // the master to Low and see no improvement at all.
      GraphicsQuality.cloudOverride = QualityLevel.ultra;
      GraphicsQuality.lightingOverride = QualityLevel.ultra;
      GraphicsQuality.setMaster(QualityLevel.low);
      expect(GraphicsQuality.cloudOverride, isNull);
      expect(GraphicsQuality.lightingOverride, isNull);
      expect(GraphicsQuality.cloudLevel, QualityLevel.low);
    });

    test('resetOverrides leaves the master alone', () {
      GraphicsQuality.master = QualityLevel.medium;
      GraphicsQuality.cloudOverride = QualityLevel.ultra;
      GraphicsQuality.resetOverrides();
      expect(GraphicsQuality.master, QualityLevel.medium);
      expect(GraphicsQuality.cloudLevel, QualityLevel.medium);
    });
  });

  group('slider positions', () {
    test('round-trip through the slider position', () {
      for (final level in QualityLevel.values) {
        expect(QualityLevel.fromPosition(level.position), level);
      }
    });

    test('positions off the ends clamp instead of throwing', () {
      expect(QualityLevel.fromPosition(-3), QualityLevel.low);
      expect(QualityLevel.fromPosition(99), QualityLevel.ultra);
      // Slider values arrive as doubles mid-drag; they must snap, not crash.
      expect(QualityLevel.fromPosition(1.4), QualityLevel.medium);
      expect(QualityLevel.fromPosition(1.6), QualityLevel.high);
    });
  });

  group('persistence', () {
    test('round-trips master and overrides', () {
      GraphicsQuality.master = QualityLevel.low;
      GraphicsQuality.cloudOverride = QualityLevel.ultra;
      GraphicsQuality.lightingOverride = null;
      final stored = GraphicsQuality.toPrefs();

      GraphicsQuality.reset();
      GraphicsQuality.applyPrefs(stored);
      expect(GraphicsQuality.master, QualityLevel.low);
      expect(GraphicsQuality.cloudOverride, QualityLevel.ultra);
      expect(GraphicsQuality.lightingOverride, isNull);
    });

    test('"follows the master" survives a restart as itself', () {
      // Not as a copy of whatever the master happened to be — otherwise the
      // master slider stops working after the first relaunch.
      GraphicsQuality.setMaster(QualityLevel.medium);
      final stored = GraphicsQuality.toPrefs();
      expect(stored[GraphicsQuality.cloudKey], isNull);

      GraphicsQuality.applyPrefs(stored);
      GraphicsQuality.setMaster(QualityLevel.low);
      expect(GraphicsQuality.cloudLevel, QualityLevel.low);
    });

    test('empty or corrupt storage falls back to the shipped default', () {
      GraphicsQuality.applyPrefs(const {});
      expect(GraphicsQuality.master, QualityLevel.high);

      GraphicsQuality.applyPrefs(const {
        GraphicsQuality.masterKey: 'potato',
        GraphicsQuality.cloudKey: 'also-not-a-level',
      });
      expect(GraphicsQuality.master, QualityLevel.high);
      expect(GraphicsQuality.cloudOverride, isNull);
    });
  });
}
