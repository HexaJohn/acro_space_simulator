/// A surface liquid as a molecular/elemental mixture — the makeup of a world's
/// ocean / aquifer / lava lake. Components are keyed by a short symbol (e.g.
/// 'H2O', 'CH4', 'NH3', 'H2SO4', 'Fe', 'SiO2', 'oil') mapping to a fraction; the
/// mix derives its colour and physical character (molten, potable, combustible)
/// from the blend. Pollution can inject contaminants, shifting both.
///
/// Pure value object — no Flutter/IO. Colour is a packed ARGB int so the render
/// can tint water/lava/coast tiles to match what the liquid actually IS (a
/// methane sea on Titan, sulphuric on Venus, molten metal or lava on a wrecked
/// world).
class LiquidMix {
  /// Component symbol -> fraction (normalised to sum 1).
  final Map<String, double> components;

  LiquidMix(Map<String, double> components)
      : components = _normalise(components);

  /// Representative RGB for each component (0..255).
  static const Map<String, List<int>> _rgb = {
    'H2O': [40, 90, 160], // deep blue water
    'CH4': [180, 120, 60], // methane sea — orange-brown
    'C2H6': [160, 130, 80], // ethane
    'NH3': [120, 200, 200], // ammonia — pale cyan
    'H2SO4': [180, 170, 70], // sulphuric — sickly yellow
    'Fe': [90, 80, 80], // molten iron — dark metallic
    'SiO2': [200, 70, 20], // silicate lava — orange-red
    'lava': [220, 80, 20], // generic lava
    'oil': [30, 25, 20], // hydrocarbon pollution — near black
    'Hg': [150, 150, 160], // mercury — bright metal
    'N2': [120, 140, 200], // liquid nitrogen — pale blue
    'ice': [200, 220, 240], // frozen
  };

  /// Symbols that mean the liquid is MOLTEN (lethal heat) — lava/molten metal.
  static const Set<String> _molten = {'SiO2', 'lava', 'Fe', 'Hg'};
  /// Combustible hydrocarbons (a fuel feedstock).
  static const Set<String> _combustible = {'CH4', 'C2H6', 'oil'};

  /// Composition-weighted colour as a packed ARGB int. Falls back to a neutral
  /// blue-grey for an empty/unknown mix.
  int get colorArgb {
    if (components.isEmpty) return 0xFF44556B;
    var r = 0.0, g = 0.0, b = 0.0, w = 0.0;
    components.forEach((sym, f) {
      final c = _rgb[sym];
      if (c != null) {
        r += c[0] * f;
        g += c[1] * f;
        b += c[2] * f;
        w += f;
      }
    });
    if (w <= 0) return 0xFF44556B;
    int ch(double v) => (v / w).clamp(0, 255).round();
    return (0xFF << 24) | (ch(r) << 16) | (ch(g) << 8) | ch(b);
  }

  double _fracOfAny(Set<String> syms) {
    var s = 0.0;
    components.forEach((k, v) {
      if (syms.contains(k)) s += v;
    });
    return s;
  }

  /// Mostly molten rock/metal — a lava-lake "ocean", lethal to touch.
  bool get isMolten => _fracOfAny(_molten) > 0.5;

  /// Drinkable-ish (water-dominated + not too contaminated).
  bool get potable =>
      (components['H2O'] ?? 0) > 0.6 && (components['oil'] ?? 0) < 0.1 &&
      !isMolten;

  /// A hydrocarbon sea you can refine into fuel.
  bool get combustible => _fracOfAny(_combustible) > 0.4;

  /// Pollution level 0..1 (contaminant fraction: oil + heavy metals).
  double get pollution =>
      _fracOfAny({'oil', 'Hg', 'H2SO4'}).clamp(0.0, 1.0);

  /// A short label for the dominant component (UI).
  String get label {
    if (components.isEmpty) return 'None';
    final top = components.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return switch (top.key) {
      'H2O' => 'Water',
      'CH4' || 'C2H6' => 'Hydrocarbon',
      'NH3' => 'Ammonia',
      'H2SO4' => 'Sulphuric acid',
      'Fe' || 'Hg' => 'Molten metal',
      'SiO2' || 'lava' => 'Lava',
      'oil' => 'Polluted sludge',
      'N2' => 'Liquid nitrogen',
      'ice' => 'Ice',
      _ => top.key,
    };
  }

  /// Inject a contaminant (e.g. 'oil') at [amount] fraction — used when the
  /// colony pollutes its ocean. Returns a new, re-normalised mix.
  LiquidMix contaminated(String symbol, double amount) {
    final next = Map<String, double>.from(components);
    // Scale existing down, add the contaminant.
    final keep = (1 - amount).clamp(0.0, 1.0);
    next.updateAll((k, v) => v * keep);
    next[symbol] = (next[symbol] ?? 0) + amount;
    return LiquidMix(next);
  }

  static Map<String, double> _normalise(Map<String, double> raw) {
    final positive = <String, double>{};
    var total = 0.0;
    raw.forEach((k, v) {
      if (v > 0) {
        positive[k] = v;
        total += v;
      }
    });
    if (total == 0) return const {};
    return positive.map((k, v) => MapEntry(k, v / total));
  }

  // ---- Common factories ----
  factory LiquidMix.water() => LiquidMix(const {'H2O': 1.0});
  factory LiquidMix.methane() => LiquidMix(const {'CH4': 0.7, 'C2H6': 0.3});
  factory LiquidMix.ammonia() => LiquidMix(const {'NH3': 0.7, 'H2O': 0.3});
  factory LiquidMix.sulphuric() => LiquidMix(const {'H2SO4': 0.85, 'H2O': 0.15});
  factory LiquidMix.lava() => LiquidMix(const {'SiO2': 0.9, 'Fe': 0.1});
  factory LiquidMix.moltenMetal() => LiquidMix(const {'Fe': 0.7, 'Hg': 0.3});

  /// Pick the dominant surface liquid from a body's temperature + composition.
  /// Hot rocky worlds => lava; very cold => liquid methane/nitrogen; sulphur-
  /// rich hot => sulphuric; otherwise water (if it can be liquid at all).
  factory LiquidMix.forConditions({
    required double temperatureK,
    required double co2Fraction,
    required double methaneFraction,
  }) {
    if (temperatureK > 1200) return LiquidMix.lava();
    if (temperatureK > 700 && co2Fraction > 0.5) return LiquidMix.sulphuric();
    if (temperatureK > 600) return LiquidMix.moltenMetal();
    if (temperatureK < 120 && methaneFraction > 0.02) return LiquidMix.methane();
    if (temperatureK < 80) return LiquidMix(const {'N2': 1.0});
    return LiquidMix.water();
  }
}
