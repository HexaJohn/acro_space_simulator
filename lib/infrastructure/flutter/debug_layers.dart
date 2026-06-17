/// Toggle flags for the renderer's draw layers — a debug panel flips these to
/// isolate what each pass contributes. All default on (normal render).
class DebugLayers {
  final bool skybox; // Milky Way backdrop
  final bool orbitRails; // celestial-body orbit ellipses
  final bool planetTexture; // textured sphere (surface map)
  final bool baseDisc; // flat shaded disc under the sphere
  final bool sphereShadow; // sphere night-side darkening pass
  final bool atmoHalo; // outer limb halo ring
  final bool atmoOverlay; // inner blue rim + dayside glow
  final bool navBall; // attitude nav-ball overlay
  final bool exaggerateStar; // floor the star to a min on-screen radius
  final bool exaggerateAtmosphere; // thicken gas-giant haze
  final bool infiniteFuel; // never drain propellant (cheat)
  final bool showSoi; // draw sphere-of-influence circles
  final bool cullDistant; // tilted-view cull of non-active bodies

  const DebugLayers({
    this.skybox = true,
    this.orbitRails = true,
    this.planetTexture = true,
    this.baseDisc = true,
    this.sphereShadow = true,
    this.atmoHalo = true,
    this.atmoOverlay = true,
    this.navBall = true,
    this.exaggerateStar = false, // off: the Sun draws at true (tiny) scale
    this.exaggerateAtmosphere = false,
    this.infiniteFuel = false,
    this.showSoi = false,
    this.cullDistant = true,
  });

  DebugLayers copyWith({
    bool? skybox,
    bool? orbitRails,
    bool? planetTexture,
    bool? baseDisc,
    bool? sphereShadow,
    bool? atmoHalo,
    bool? atmoOverlay,
    bool? navBall,
    bool? exaggerateStar,
    bool? exaggerateAtmosphere,
    bool? infiniteFuel,
    bool? showSoi,
    bool? cullDistant,
  }) {
    return DebugLayers(
      skybox: skybox ?? this.skybox,
      orbitRails: orbitRails ?? this.orbitRails,
      planetTexture: planetTexture ?? this.planetTexture,
      baseDisc: baseDisc ?? this.baseDisc,
      sphereShadow: sphereShadow ?? this.sphereShadow,
      atmoHalo: atmoHalo ?? this.atmoHalo,
      atmoOverlay: atmoOverlay ?? this.atmoOverlay,
      navBall: navBall ?? this.navBall,
      exaggerateStar: exaggerateStar ?? this.exaggerateStar,
      exaggerateAtmosphere: exaggerateAtmosphere ?? this.exaggerateAtmosphere,
      infiniteFuel: infiniteFuel ?? this.infiniteFuel,
      showSoi: showSoi ?? this.showSoi,
      cullDistant: cullDistant ?? this.cullDistant,
    );
  }

  /// Field equality so CustomPainter.shouldRepaint can compare.
  @override
  bool operator ==(Object other) =>
      other is DebugLayers &&
      other.skybox == skybox &&
      other.orbitRails == orbitRails &&
      other.planetTexture == planetTexture &&
      other.baseDisc == baseDisc &&
      other.sphereShadow == sphereShadow &&
      other.atmoHalo == atmoHalo &&
      other.atmoOverlay == atmoOverlay &&
      other.navBall == navBall &&
      other.exaggerateStar == exaggerateStar &&
      other.exaggerateAtmosphere == exaggerateAtmosphere &&
      other.infiniteFuel == infiniteFuel &&
      other.showSoi == showSoi &&
      other.cullDistant == cullDistant;

  @override
  int get hashCode => Object.hash(skybox, orbitRails, planetTexture, baseDisc,
      sphereShadow, atmoHalo, atmoOverlay, navBall, exaggerateStar,
      exaggerateAtmosphere, infiniteFuel, showSoi, cullDistant);
}
