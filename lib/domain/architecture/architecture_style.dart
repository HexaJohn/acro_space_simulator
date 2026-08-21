// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What KIND of city this is, expressed as numbers a generator can use.
///
/// The generators already decide how big a building is — from its function and
/// its lot. What they had no way to say is what it should look like, so every
/// building in every colony came out as the same setback box with ribbon
/// glazing. That is a real idiom (a suburban office park), it is just not the
/// one that makes a street read as a street.
///
/// A style is the vocabulary of an urban idiom, and almost all of it is about
/// two things that have nothing to do with the building's function:
///
///   * WHERE IT SITS. A downtown block is continuous because its buildings
///     stand on the property line and touch their neighbours; the parking is
///     behind, off an alley. Take the setbacks to zero and a row of ordinary
///     boxes becomes a street wall — this single change does more for the look
///     of a city than any amount of facade detail.
///   * HOW THE WALL IS DIVIDED. Masonry cities are PUNCHED: piers of brick
///     with windows between them, a heavy base, a cornice at the top. Curtain
///     wall is RIBBON: continuous glass, no piers. The two never read as each
///     other whatever texture you hang on them.
///
/// Everything here is in metres and real: a shopfront really is about 4.5 m
/// tall, a structural bay really is about 5 m, and the numbers being real is
/// what stops a generated street from drifting out of scale with the people
/// and cars in it.
library;

import '../colony/city/city_building_spec.dart';

/// Masonries carried by the facade atlas, banded along its U axis.
///
/// Declared HERE rather than beside the bake because the geometry pass has to
/// know the count to map a band, and the geometry pass is domain code that
/// cannot see the renderer. The bake reads it back.
const int kFacadeMaterials = 8;

/// Band indices, named. Order is the bake's; changing it recolours every
/// building in every save.
class FacadeMaterial {
  FacadeMaterial._();
  static const int redBrick = 0;
  static const int buffBrick = 1;
  static const int terracotta = 2;
  static const int limestone = 3;
  static const int paintedRender = 4;
  static const int darkBrick = 5;
  static const int precast = 6;
  static const int metalPanel = 7;
}

/// How a wall is divided between solid and glass.
enum FacadeRhythm {
  /// Continuous horizontal glazing, no piers. Curtain wall and industrial
  /// glazing — the current look, kept because it is right for some things.
  ribbon,

  /// Vertical piers with an opening punched between each pair. Every masonry
  /// city in the reference photographs, and most of every other city too.
  punched,
}

class ArchitectureStyle {
  const ArchitectureStyle({
    required this.id,
    required this.label,
    required this.note,
    this.frontSetbackM = 3,
    this.sideSetbackM = 3,
    this.rearSetbackM = 3,
    this.parkingBehind = false,
    this.groundStoreyM = 3.6,
    this.upperStoreyM = 3.6,
    this.rhythm = FacadeRhythm.ribbon,
    this.bayM = 5.0,
    this.pierM = 1.0,
    this.reliefM = 0.22,
    this.openingFrac = 0.55,
    this.storefront = false,
    this.signBandM = 0.9,
    this.blankPartyWalls = false,
    this.parapetM = 0,
    this.corniceProjectionM = 0,
    this.corniceBandM = 0,
    this.roofClutterPer100M2 = 0,
    this.stepbackAboveFloors = 4,
    this.podiumFloors = 2,
    this.corniceDatumFloors = 1,
    this.zoneFloors = const {},
    this.zoneFloorSpread = 0.5,
    this.awnings = false,
    this.fireEscapes = false,
    this.bayProjectionM = 0,
    this.materials = const [FacadeMaterial.precast],
  });

  final String id;
  final String label;

  /// One line for the studio, describing what this kit is FOR.
  final String note;

  // ---- Siting ------------------------------------------------------------

  /// Property line to building face on the street side. Zero is a street wall.
  final double frontSetbackM;

  /// Property line to building face at the sides. Zero means the building
  /// runs the full width of its lot and touches its neighbours.
  final double sideSetbackM;

  /// Rear yard — where the alley, the loading bay and the car park live.
  final double rearSetbackM;

  /// Put the car park BEHIND the building rather than between it and the
  /// street. A front lot is the strip-mall pattern: it is what breaks a
  /// downtown block open, and no amount of frontage detail survives it.
  final bool parkingBehind;

  // ---- Storeys -----------------------------------------------------------

  /// Ground floor height. Retail wants far more than an office storey, and a
  /// taller base is half of why a commercial street reads as commercial.
  final double groundStoreyM;
  final double upperStoreyM;

  // ---- The wall ----------------------------------------------------------

  final FacadeRhythm rhythm;

  /// Structural bay: pier centre to pier centre.
  final double bayM;

  /// Width of the pier between two openings.
  final double pierM;

  /// How far the piers stand proud of the glass. Small, but it is the whole
  /// difference between a modelled wall and a printed one once the sun is
  /// anywhere off axis.
  final double reliefM;

  /// Fraction of the storey the opening occupies, sill to head.
  final double openingFrac;

  /// Glazed shopfront at street level, with a signage band over it.
  final bool storefront;
  final double signBandM;

  /// Leave the side walls blank. A building that shares its side walls has no
  /// windows there to share them with — and an END building's exposed blank
  /// party wall is one of the most recognisable things about a real block.
  final bool blankPartyWalls;

  // ---- The cap -----------------------------------------------------------

  /// Height of the parapet standing above the roof deck. A flat roof without
  /// one ends in a bare edge, which is the single most model-like thing a
  /// generated building can do.
  final double parapetM;

  /// How far the cornice oversails the wall below it.
  final double corniceProjectionM;

  /// Vertical depth of the cornice band.
  final double corniceBandM;

  // ---- The roof ----------------------------------------------------------

  /// Stair bulkheads, tanks, plant and vents per 100 m² of roof. Look at any
  /// picture taken from above a city: the roofs are not empty.
  final double roofClutterPer100M2;

  // ---- Massing -----------------------------------------------------------

  /// Floors above which the mass steps back to a tower on a podium.
  final int stepbackAboveFloors;

  /// How many floors the podium keeps when it does step back. A masonry base
  /// is a couple of storeys taller than a glass one — it has a cornice to
  /// land on.
  final int podiumFloors;

  /// How tall a building in each density band WANTS to be, before its tenant
  /// is consulted at all.
  ///
  /// Height in a real city is a property of the LAND, not of the occupier. A
  /// downtown tower is forty storeys because the ground under it is worth more
  /// than the building, and it would be forty storeys whoever leased it.
  /// Deriving floors purely from required-floor-area over footprint — which is
  /// what this did — ties architecture to game-balance numbers instead: a
  /// "Business District" spec asks for 60 jobs, which is 1,320 m², which on a
  /// full-lot footprint is TWO STOREYS. A whole generated downtown came out
  /// two and three storeys tall for exactly that reason.
  ///
  /// So the zone sets the target and the tenant's demand is a FLOOR under it,
  /// never a ceiling. Empty disables the whole idea and returns the old
  /// demand-only behaviour, which is what the setback kit still wants — an
  /// office park is not tall because its land is cheap, and that is the point
  /// of it.
  final Map<Density, int> zoneFloors;

  /// How far individual buildings stray from their band's target, as a
  /// fraction. Zero gives a downtown of identical towers, which is a skyline
  /// nowhere has.
  final double zoneFloorSpread;

  /// Target floors for [spec] under this kit, jittered deterministically by
  /// [seed]. Zero when the kit sets no target.
  int targetFloors(CityBuildingSpec spec, int seed) {
    final band = spec.zoneDensity;
    if (band == null) return 0;
    final base = zoneFloors[band] ?? 0;
    if (base <= 0) return 0;
    // A cheap deterministic scramble in [0,1): the same lot must come back the
    // same height every time the colony is regenerated.
    final h = (seed * 2654435761) & 0x7FFFFFFF;
    final t = (h % 10007) / 10007.0;
    return (base * (1 - zoneFloorSpread + t * zoneFloorSpread * 2))
        .round()
        .clamp(1, 200);
  }

  /// Snap floor counts to a multiple of this, so neighbours' cornices line up.
  ///
  /// One disables it. Two is enough: it halves the number of distinct
  /// rooflines on a block without flattening the skyline, which is roughly
  /// what a street built over thirty years to the same storey height looks
  /// like.
  final int corniceDatumFloors;

  /// Fabric awnings over the shopfronts.
  final bool awnings;

  /// Fire escapes on the back and the flanks. Instantly reads as American
  /// masonry, and it is a ladder and four landings.
  final bool fireEscapes;

  /// How far a bay window projects past the wall. Zero for none.
  final double bayProjectionM;

  /// Which bands of the facade atlas this kit builds in. A street where every
  /// wall is the same colour reads as one enormous building, however good the
  /// individual facades are — the variety is the point, and it costs nothing
  /// because it is one texture.
  final List<int> materials;

  /// The masonry for a building, deterministic in [seed].
  int materialFor(int seed) =>
      materials.isEmpty ? FacadeMaterial.precast : materials[seed.abs() % materials.length];

  bool get isStreetWall => frontSetbackM <= 0.01;

  /// Storey height for floor [index], counting from 0 at the ground.
  double storeyAt(int index) => index == 0 ? groundStoreyM : upperStoreyM;

  /// Height of the bottom [floors] storeys.
  double heightOf(int floors) =>
      floors <= 0 ? 0 : groundStoreyM + (floors - 1) * upperStoreyM;

  /// Openings across a wall of [spanM]. At least one, so a narrow return still
  /// gets a window rather than a blank panel.
  int baysAcross(double spanM) =>
      spanM <= 0 ? 0 : (spanM / bayM).round().clamp(1, 64);

  /// The kit the reference photographs are of: Chicago's Loop, Milwaukee's
  /// Third Ward, Wicker Park. Brick and terracotta, built to the property
  /// line, party walls, tall shopfront, punched windows between piers, a
  /// cornice, a parapet, and a roof covered in plant.
  ///
  /// Note the setbacks: all three zero. Everything else in here is detail on
  /// top of that decision.
  static const masonryStreet = ArchitectureStyle(
    id: 'masonry-street',
    label: 'Masonry street wall',
    note: 'Brick and terracotta on the property line — Loop, Third Ward, '
        'Wicker Park. Party walls, tall shopfront, cornice, parapet.',
    frontSetbackM: 0,
    sideSetbackM: 0,
    rearSetbackM: 6,
    parkingBehind: true,
    groundStoreyM: 4.6,
    upperStoreyM: 3.5,
    rhythm: FacadeRhythm.punched,
    bayM: 4.6,
    pierM: 1.1,
    reliefM: 0.26,
    openingFrac: 0.62,
    storefront: true,
    signBandM: 1.0,
    blankPartyWalls: true,
    parapetM: 1.1,
    corniceProjectionM: 0.55,
    corniceBandM: 0.8,
    roofClutterPer100M2: 1.6,
    stepbackAboveFloors: 8,
    podiumFloors: 3,
    corniceDatumFloors: 2,
    // A CBD, an inner ring of mid-rise, and houses at the edge. The spread is
    // wide on purpose: downtown towers that all stop at the same floor read as
    // one extruded block, and the tallest few are what make a skyline.
    zoneFloors: {
      Density.high: 34,
      Density.medium: 8,
      Density.low: 3,
    },
    zoneFloorSpread: 0.55,
    awnings: true,
    fireEscapes: true,
    bayProjectionM: 0.55,
    materials: [
      FacadeMaterial.redBrick,
      FacadeMaterial.buffBrick,
      FacadeMaterial.terracotta,
      FacadeMaterial.limestone,
      FacadeMaterial.paintedRender,
      FacadeMaterial.darkBrick,
    ],
  );

  /// What the generator did before styles existed: a freestanding box in the
  /// middle of its lot with continuous glazing and its car park out front.
  ///
  /// Kept, and kept as the DEFAULT, for two reasons. It is genuinely the right
  /// idiom for an office park, a retail box or a works — and it is the
  /// baseline every existing test measures against, so a style that changed it
  /// silently would be a style that could not be trusted.
  static const utilitarian = ArchitectureStyle(
    id: 'utilitarian',
    label: 'Utilitarian setback',
    note: 'Freestanding box, ribbon glazing, parking out front. Office park, '
        'retail shed, works.',
    materials: [FacadeMaterial.precast],
  );

  /// Airless and hostile worlds: mass over glass. Thick walls, a few small
  /// punched ports, no shopfront (there is no street to open onto — the
  /// pedestrians are in the tubes), a heavy parapet and a roof loaded with
  /// plant, because on a body with no air every building is its own life
  /// support.
  static const pressurised = ArchitectureStyle(
    id: 'pressurised',
    label: 'Pressurised regolith',
    note: 'Airless worlds: thick shielded walls, small ports, no shopfront, '
        'roof stacked with plant.',
    frontSetbackM: 2,
    sideSetbackM: 2,
    rearSetbackM: 4,
    parkingBehind: true,
    groundStoreyM: 3.2,
    upperStoreyM: 3.0,
    rhythm: FacadeRhythm.punched,
    bayM: 6.0,
    pierM: 3.4,
    reliefM: 0.35,
    openingFrac: 0.34,
    blankPartyWalls: true,
    parapetM: 0.8,
    corniceProjectionM: 0.25,
    corniceBandM: 0.4,
    roofClutterPer100M2: 3.2,
    stepbackAboveFloors: 6,
    materials: [FacadeMaterial.precast, FacadeMaterial.metalPanel],
  );

  /// Every kit, in the order the studio lists them.
  static const List<ArchitectureStyle> kits = [
    masonryStreet,
    utilitarian,
    pressurised,
  ];

  static ArchitectureStyle byId(String id) =>
      kits.firstWhere((s) => s.id == id, orElse: () => utilitarian);
}
