/// Periodic-table category of an element (drives extraction/refining behaviour
/// and UI grouping).
enum ElementCategory {
  nonmetal,
  nobleGas,
  alkaliMetal,
  alkalineEarthMetal,
  metalloid,
  postTransitionMetal,
  transitionMetal,
  lanthanide, // rare earths
  actinide, // fissiles
  halogen,
}

/// A chemical element with the real-world properties a space-mining game needs:
/// atomic number, symbol/name, bulk density, periodic category, and crustal
/// abundance (mass fraction) which drives how common its ore is. Value object.
class ChemicalElement {
  final int atomicNumber; // Z
  final String symbol; // 'Fe'
  final String name; // 'Iron'
  final double atomicMass; // u (g/mol)
  final double densityKgPerM3; // bulk solid/liquid density
  final ElementCategory category;

  /// Fraction of a typical rocky-planet crust by mass (0..1). Sets base ore
  /// richness; rare elements (Au, Pt, U) are far scarcer than O/Si/Fe.
  final double crustalAbundance;

  const ChemicalElement({
    required this.atomicNumber,
    required this.symbol,
    required this.name,
    required this.atomicMass,
    required this.densityKgPerM3,
    required this.category,
    required this.crustalAbundance,
  });

  bool get isFissile => category == ElementCategory.actinide;
  bool get isRareEarth => category == ElementCategory.lanthanide;
}
