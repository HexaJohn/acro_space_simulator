// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Scalability presets for the fragment-bound passes, so a weak GPU can buy
/// back frame time without turning features off outright.
///
/// WHAT IS AND IS NOT WORTH SCALING. The volumetric passes are overwhelmingly
/// fragment-bound: clouds march up to 40 view samples per pixel and light each
/// one with a 5-step march toward the sun, so the worst case is ~240 density
/// evaluations for a single pixel of limb. And each of those evaluations is
/// itself ~24 procedural noise calls (there is no cloud texture — the weather
/// map is fbm-of-fbm computed from scratch per sample), so the presets scale
/// THREE things: how many samples march, how many octaves each sample costs
/// ([CloudRenderMode.reduced]), and whether a march happens at all
/// ([CloudRenderMode.flat] — a single-sample textured shell). The SHELL
/// MESHES, by contrast, are ~1k and ~4.6k quads — nothing, next to that — so
/// the presets leave the geometry alone.
///
/// That is not only a cost judgement. The surface proxy shells are pinned at
/// 96x48 for a REASON documented in both node files: a facet chord at 48x24
/// sags ~13.6 km below the true sphere on Earth, deeper than the proxy's
/// ~6.4 km lift, so facet interiors fall inside the opaque planet, fail the
/// depth test, and the disc haze disappears the moment the camera enters the
/// shell. Tessellation there is a correctness constraint tied to the lift, not
/// a quality dial, and a scalability slider must not touch it.
///
/// [QualityLevel.high] reproduces the pre-slider numbers EXACTLY, so the
/// default ships the look the shaders were tuned against; low and medium are
/// the savings and ultra is headroom.
library;

/// One rung of the scalability ladder.
enum QualityLevel {
  low,
  medium,
  high,
  ultra;

  String get label => switch (this) {
        low => 'Low',
        medium => 'Medium',
        high => 'High',
        ultra => 'Ultra',
      };

  /// Slider position, so the UI can move between rungs by number.
  double get position => index.toDouble();

  static QualityLevel fromPosition(double v) =>
      values[v.round().clamp(0, values.length - 1)];

  static QualityLevel? byName(String? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }
}

/// HOW the cloud layer is drawn — the technique axis, orthogonal to the
/// sample counts.
///
/// Wire codes are what `clouds.frag` switches on in `quality.w`; 0 is
/// reserved as the "block never packed" sentinel, which the shader treats as
/// [full] so an untaught caller cannot accidentally select the cheap path.
enum CloudRenderMode {
  /// No raymarch. One full-field sample where the ray crosses the mid-shell
  /// sphere, one Lo sample sunward for the shadow cue, Beer's law over the
  /// geometric chord. ~35 noise evaluations per pixel. Gives up in-layer
  /// parallax and lump-by-lump self-shadow — near invisible from orbit,
  /// where a weak GPU pays the whole-disc bill.
  flat(1),

  /// The full march over a cheaper field: fbm2 warp, four-octave base
  /// (mean-matched), two-octave erosion, no cirrus veil. Same weather map,
  /// ~14 noise calls per view sample instead of ~24.
  reduced(2),

  /// The shipped volumetric path, untouched.
  full(3);

  const CloudRenderMode(this.wire);

  /// The value packed into `quality.w`.
  final int wire;

  String get label => switch (this) {
        flat => 'textured shell',
        reduced => 'reduced volumetric',
        full => 'full volumetric',
      };
}

/// What the cloud march costs at a given rung.
///
/// The worst case per pixel is `viewSampleCap * (1 + lightSamples)` density
/// evaluations, which is what makes low ~6.7x cheaper than high rather than
/// the ~3x the view cap alone suggests — the light march is NESTED.
class CloudQuality {
  const CloudQuality({
    required this.viewSampleCap,
    required this.samplePitch,
    required this.lightSamples,
    this.mode = CloudRenderMode.full,
  });

  /// Hard cap on the view march. The shader's own compile-time maximum is
  /// [kMaxCloudViewSamples]; this clamps under it at runtime.
  final int viewSampleCap;

  /// Samples per shell thickness of chord — the ADAPTIVE part. A nadir ray's
  /// chord is about one thickness, so this is also what a downward-looking
  /// ray actually spends; only long limb chords climb to the cap.
  final double samplePitch;

  /// Steps of the self-shadow march toward the sun, per view sample.
  final int lightSamples;

  /// The rendering technique. [viewSampleCap], [samplePitch] and
  /// [lightSamples] only matter for the volumetric modes; [CloudRenderMode
  /// .flat] ignores all three.
  final CloudRenderMode mode;

  /// Low doesn't march at all — the flat shell is what makes it a rung a
  /// genuinely weak GPU can stand on. Its sample fields are kept sane anyway
  /// so a hand-rolled preset that flips the mode back gets numbers, not junk.
  static const CloudQuality low = CloudQuality(
      viewSampleCap: 12,
      samplePitch: 4,
      lightSamples: 2,
      mode: CloudRenderMode.flat);
  static const CloudQuality medium = CloudQuality(
      viewSampleCap: 22,
      samplePitch: 6,
      lightSamples: 3,
      mode: CloudRenderMode.reduced);

  /// The shipped look: identical to the constants the shader carried before
  /// the slider existed.
  static const CloudQuality high =
      CloudQuality(viewSampleCap: 40, samplePitch: 10, lightSamples: 5);
  static const CloudQuality ultra =
      CloudQuality(viewSampleCap: 56, samplePitch: 14, lightSamples: 7);

  static CloudQuality of(QualityLevel level) => switch (level) {
        QualityLevel.low => low,
        QualityLevel.medium => medium,
        QualityLevel.high => high,
        QualityLevel.ultra => ultra,
      };

  /// Worst-case density evaluations for one pixel — what the preset is really
  /// trading. Used by the options screen to show the cost, and by the tests to
  /// assert the ladder is monotonic.
  int get worstCaseSamples => viewSampleCap * (1 + lightSamples);

  /// Estimated worst-case NOISE evaluations for one pixel, weighting each
  /// density call by what its field actually costs: ~24 vnoise for the full
  /// field, ~14 reduced, ~13 for the light march's Lo field, and the flat
  /// shell exactly one full + one Lo call. Coarse — it ignores early-outs —
  /// but it is the number the sample counts alone get badly wrong (a flat
  /// Low is ~96x cheaper than High, not the ~7x the counts suggest), so the
  /// options screen's ratio and the ladder tests trade on this.
  int get approxNoiseCost => switch (mode) {
        CloudRenderMode.flat => 24 + 13,
        CloudRenderMode.reduced => viewSampleCap * (14 + lightSamples * 13),
        CloudRenderMode.full => viewSampleCap * (24 + lightSamples * 13),
      };
}

/// What the atmosphere march and the reflection bake cost at a given rung.
class LightingQuality {
  const LightingQuality({
    required this.atmoViewSamples,
    required this.atmoLightSamples,
    required this.envBakeWidth,
    required this.envBakeInterval,
  });

  /// Steps along the view ray through the atmosphere shell. Unlike the cloud
  /// march this is a fixed count, not adaptive.
  final int atmoViewSamples;

  /// Steps toward the sun per view sample — nested, as in the cloud march.
  final int atmoLightSamples;

  /// Width of the equirect radiance capture craft reflect. Height is half.
  final int envBakeWidth;

  /// Floor on how often that capture may be re-rendered.
  final Duration envBakeInterval;

  int get envBakeHeight => envBakeWidth ~/ 2;

  static const LightingQuality low = LightingQuality(
      atmoViewSamples: 6,
      atmoLightSamples: 3,
      envBakeWidth: 96,
      envBakeInterval: Duration(seconds: 8));
  static const LightingQuality medium = LightingQuality(
      atmoViewSamples: 8,
      atmoLightSamples: 4,
      envBakeWidth: 160,
      envBakeInterval: Duration(seconds: 5));

  /// The shipped look: identical to the pre-slider constants.
  static const LightingQuality high = LightingQuality(
      atmoViewSamples: 12,
      atmoLightSamples: 6,
      envBakeWidth: 256,
      envBakeInterval: Duration(seconds: 3));
  static const LightingQuality ultra = LightingQuality(
      atmoViewSamples: 16,
      atmoLightSamples: 8,
      envBakeWidth: 384,
      envBakeInterval: Duration(seconds: 2));

  static LightingQuality of(QualityLevel level) => switch (level) {
        QualityLevel.low => low,
        QualityLevel.medium => medium,
        QualityLevel.high => high,
        QualityLevel.ultra => ultra,
      };

  int get worstCaseSamples => atmoViewSamples * (1 + atmoLightSamples);
}

/// Compile-time ceilings baked into the shaders. The uniform can only clamp
/// BELOW these — raising a preset past them silently does nothing, so the
/// tests pin ultra to them.
const int kMaxCloudViewSamples = 56;
const int kMaxCloudLightSamples = 7;
const int kMaxAtmoViewSamples = 16;
const int kMaxAtmoLightSamples = 8;

/// The live scalability settings.
///
/// Statics, because the render nodes that consume them are themselves statics
/// reached from four different screens (flight, terrain studio, city studio,
/// cloudscape) — the same arrangement `CloudNodes.hidden` and
/// `GravityGridNodes.enabled` already use. Reading them is free, so the nodes
/// re-read every frame and a change applies live rather than on next launch.
class GraphicsQuality {
  GraphicsQuality._();

  /// The master rung. Moving it moves everything that has no override.
  static QualityLevel master = QualityLevel.high;

  /// Per-feature departures from [master]. Null means "follow the master",
  /// which is what makes the master slider keep working after the user has
  /// touched it; a preset that COPIED the master on every move could never be
  /// told apart from one the user had deliberately set to the same value.
  static QualityLevel? cloudOverride;
  static QualityLevel? lightingOverride;

  static QualityLevel get cloudLevel => cloudOverride ?? master;
  static QualityLevel get lightingLevel => lightingOverride ?? master;

  static CloudQuality get clouds => CloudQuality.of(cloudLevel);
  static LightingQuality get lighting => LightingQuality.of(lightingLevel);

  /// Whether any override departs from the master — the UI shows CUSTOM.
  ///
  /// An override that MATCHES the master is not custom: the user dragged it
  /// back, and reporting that as custom would leave the label stuck.
  static bool get isCustom =>
      (cloudOverride != null && cloudOverride != master) ||
      (lightingOverride != null && lightingOverride != master);

  /// Move the master and drop the overrides — the "everything cheaper" path
  /// the slider exists for.
  static void setMaster(QualityLevel level) {
    master = level;
    cloudOverride = null;
    lightingOverride = null;
  }

  /// Clear the overrides without moving the master.
  static void resetOverrides() {
    cloudOverride = null;
    lightingOverride = null;
  }

  /// Terrain view culling: chunks outside the camera's view cone select a
  /// few LOD levels coarser (never vanish), which cuts the resident set, the
  /// meshing behind the camera and the triangle count near the ground at the
  /// price of a moment of coarse ground on a fast turn. Not a quality rung —
  /// it is on at every preset — so it does not count toward [isCustom].
  /// Read every frame by the scenes, which hand the streamer a view cone
  /// only while it is true.
  static bool terrainFrustumCull = true;

  /// What a city tile outside the lens's view cone becomes while
  /// [terrainFrustumCull] is on. Not a quality rung either.
  static CityOutOfView cityOutOfView = CityOutOfView.stepDown;

  /// Restore the shipped default.
  static void reset() {
    master = QualityLevel.high;
    terrainFrustumCull = true;
    cityOutOfView = CityOutOfView.stepDown;
    resetOverrides();
  }

  // --- Persistence -------------------------------------------------------
  // Keys are read by [load] at startup and written by [save] on every change.
  static const String masterKey = 'gfxQuality';
  static const String cloudKey = 'gfxQualityClouds';
  static const String lightingKey = 'gfxQualityLighting';
  static const String terrainFrustumCullKey = 'gfxTerrainFrustumCull';
  static const String cityOutOfViewKey = 'gfxCityOutOfView';

  /// Every key [applyPrefs] reads, for the loader to fetch.
  static const List<String> prefKeys = [
    masterKey,
    cloudKey,
    lightingKey,
    terrainFrustumCullKey,
    cityOutOfViewKey,
  ];

  /// Apply a persisted map. Separated from the `SharedPreferences` call so the
  /// decode is testable without a plugin binding.
  static void applyPrefs(Map<String, String?> stored) {
    master = QualityLevel.byName(stored[masterKey]) ?? QualityLevel.high;
    cloudOverride = QualityLevel.byName(stored[cloudKey]);
    lightingOverride = QualityLevel.byName(stored[lightingKey]);
    // Absent or unreadable = the shipped default (on); only an explicit
    // 'false' turns it off.
    terrainFrustumCull = stored[terrainFrustumCullKey] != 'false';
    cityOutOfView = CityOutOfView.byName(stored[cityOutOfViewKey]) ??
        CityOutOfView.stepDown;
  }

  /// The current settings as a persistable map. A null override is stored as
  /// null so "follows the master" survives a restart as itself.
  static Map<String, String?> toPrefs() => {
        masterKey: master.name,
        cloudKey: cloudOverride?.name,
        lightingKey: lightingOverride?.name,
        terrainFrustumCullKey: terrainFrustumCull.toString(),
        cityOutOfViewKey: cityOutOfView.name,
      };
}

/// What a city tile outside the lens's view cone becomes.
enum CityOutOfView {
  /// One tier below what its distance earns: near to mid, mid to far. A
  /// turn refines from a coarser city; nothing pops in from nowhere.
  stepDown,

  /// Silhouettes, whatever its distance.
  far,

  /// Not drawn. Built nodes are kept and re-attached the moment the tile
  /// is back in view; a tile that was never built pops in when the camera
  /// turns to it, and nothing behind the camera casts a shadow.
  hidden;

  static CityOutOfView? byName(String? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  String get label => switch (this) {
        CityOutOfView.stepDown => 'STEP DOWN',
        CityOutOfView.far => 'FAR',
        CityOutOfView.hidden => 'HIDDEN',
      };
}
