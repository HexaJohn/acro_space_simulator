import 'chemical_element.dart';

/// A catalog of chemical elements with real properties. Covers the
/// mining/space-relevant subset of the periodic table — structural metals,
/// fuels/volatiles, noble gases, rare earths, and fissiles — structured so the
/// remaining elements can be appended to reach all 118 without code changes
/// elsewhere (every consumer looks them up by symbol or atomic number).
class PeriodicTable {
  final Map<String, ChemicalElement> _bySymbol;
  final Map<int, ChemicalElement> _byNumber;

  PeriodicTable(Iterable<ChemicalElement> elements)
      : _bySymbol = {for (final e in elements) e.symbol: e},
        _byNumber = {for (final e in elements) e.atomicNumber: e};

  Iterable<ChemicalElement> get all => _bySymbol.values;
  ChemicalElement? bySymbol(String s) => _bySymbol[s];
  ChemicalElement? byNumber(int z) => _byNumber[z];

  Iterable<ChemicalElement> inCategory(ElementCategory c) =>
      _bySymbol.values.where((e) => e.category == c);

  factory PeriodicTable.standard() => PeriodicTable(const [
        // period 1
        ChemicalElement(atomicNumber: 1, symbol: 'H', name: 'Hydrogen', atomicMass: 1.008, densityKgPerM3: 70, category: ElementCategory.nonmetal, crustalAbundance: 0.0014),
        ChemicalElement(atomicNumber: 2, symbol: 'He', name: 'Helium', atomicMass: 4.0026, densityKgPerM3: 0.1786, category: ElementCategory.nobleGas, crustalAbundance: 8e-9),
        // light + common
        ChemicalElement(atomicNumber: 3, symbol: 'Li', name: 'Lithium', atomicMass: 6.94, densityKgPerM3: 534, category: ElementCategory.alkaliMetal, crustalAbundance: 2e-5),
        ChemicalElement(atomicNumber: 4, symbol: 'Be', name: 'Beryllium', atomicMass: 9.0122, densityKgPerM3: 1850, category: ElementCategory.alkalineEarthMetal, crustalAbundance: 2.8e-6),
        ChemicalElement(atomicNumber: 5, symbol: 'B', name: 'Boron', atomicMass: 10.81, densityKgPerM3: 2340, category: ElementCategory.metalloid, crustalAbundance: 1e-5),
        ChemicalElement(atomicNumber: 6, symbol: 'C', name: 'Carbon', atomicMass: 12.011, densityKgPerM3: 2267, category: ElementCategory.nonmetal, crustalAbundance: 0.0002),
        ChemicalElement(atomicNumber: 7, symbol: 'N', name: 'Nitrogen', atomicMass: 14.007, densityKgPerM3: 1.251, category: ElementCategory.nonmetal, crustalAbundance: 1.9e-5),
        ChemicalElement(atomicNumber: 8, symbol: 'O', name: 'Oxygen', atomicMass: 15.999, densityKgPerM3: 1.429, category: ElementCategory.nonmetal, crustalAbundance: 0.461),
        ChemicalElement(atomicNumber: 9, symbol: 'F', name: 'Fluorine', atomicMass: 18.998, densityKgPerM3: 1.696, category: ElementCategory.halogen, crustalAbundance: 5.85e-4),
        ChemicalElement(atomicNumber: 10, symbol: 'Ne', name: 'Neon', atomicMass: 20.180, densityKgPerM3: 0.9, category: ElementCategory.nobleGas, crustalAbundance: 5e-9),
        ChemicalElement(atomicNumber: 11, symbol: 'Na', name: 'Sodium', atomicMass: 22.990, densityKgPerM3: 971, category: ElementCategory.alkaliMetal, crustalAbundance: 0.0236),
        ChemicalElement(atomicNumber: 12, symbol: 'Mg', name: 'Magnesium', atomicMass: 24.305, densityKgPerM3: 1738, category: ElementCategory.alkalineEarthMetal, crustalAbundance: 0.0233),
        ChemicalElement(atomicNumber: 13, symbol: 'Al', name: 'Aluminium', atomicMass: 26.982, densityKgPerM3: 2700, category: ElementCategory.postTransitionMetal, crustalAbundance: 0.0823),
        ChemicalElement(atomicNumber: 14, symbol: 'Si', name: 'Silicon', atomicMass: 28.085, densityKgPerM3: 2329, category: ElementCategory.metalloid, crustalAbundance: 0.282),
        ChemicalElement(atomicNumber: 15, symbol: 'P', name: 'Phosphorus', atomicMass: 30.974, densityKgPerM3: 1820, category: ElementCategory.nonmetal, crustalAbundance: 0.00105),
        ChemicalElement(atomicNumber: 16, symbol: 'S', name: 'Sulfur', atomicMass: 32.06, densityKgPerM3: 2070, category: ElementCategory.nonmetal, crustalAbundance: 3.5e-4),
        ChemicalElement(atomicNumber: 17, symbol: 'Cl', name: 'Chlorine', atomicMass: 35.45, densityKgPerM3: 3.214, category: ElementCategory.halogen, crustalAbundance: 1.45e-4),
        ChemicalElement(atomicNumber: 18, symbol: 'Ar', name: 'Argon', atomicMass: 39.948, densityKgPerM3: 1.784, category: ElementCategory.nobleGas, crustalAbundance: 3.5e-6),
        ChemicalElement(atomicNumber: 19, symbol: 'K', name: 'Potassium', atomicMass: 39.098, densityKgPerM3: 862, category: ElementCategory.alkaliMetal, crustalAbundance: 0.0209),
        ChemicalElement(atomicNumber: 20, symbol: 'Ca', name: 'Calcium', atomicMass: 40.078, densityKgPerM3: 1550, category: ElementCategory.alkalineEarthMetal, crustalAbundance: 0.0415),
        ChemicalElement(atomicNumber: 22, symbol: 'Ti', name: 'Titanium', atomicMass: 47.867, densityKgPerM3: 4506, category: ElementCategory.transitionMetal, crustalAbundance: 0.00565),
        ChemicalElement(atomicNumber: 24, symbol: 'Cr', name: 'Chromium', atomicMass: 51.996, densityKgPerM3: 7150, category: ElementCategory.transitionMetal, crustalAbundance: 1.02e-4),
        ChemicalElement(atomicNumber: 25, symbol: 'Mn', name: 'Manganese', atomicMass: 54.938, densityKgPerM3: 7440, category: ElementCategory.transitionMetal, crustalAbundance: 9.5e-4),
        ChemicalElement(atomicNumber: 26, symbol: 'Fe', name: 'Iron', atomicMass: 55.845, densityKgPerM3: 7874, category: ElementCategory.transitionMetal, crustalAbundance: 0.0563),
        ChemicalElement(atomicNumber: 27, symbol: 'Co', name: 'Cobalt', atomicMass: 58.933, densityKgPerM3: 8900, category: ElementCategory.transitionMetal, crustalAbundance: 2.5e-5),
        ChemicalElement(atomicNumber: 28, symbol: 'Ni', name: 'Nickel', atomicMass: 58.693, densityKgPerM3: 8908, category: ElementCategory.transitionMetal, crustalAbundance: 8.4e-5),
        ChemicalElement(atomicNumber: 29, symbol: 'Cu', name: 'Copper', atomicMass: 63.546, densityKgPerM3: 8960, category: ElementCategory.transitionMetal, crustalAbundance: 6e-5),
        ChemicalElement(atomicNumber: 30, symbol: 'Zn', name: 'Zinc', atomicMass: 65.38, densityKgPerM3: 7140, category: ElementCategory.transitionMetal, crustalAbundance: 7e-5),
        ChemicalElement(atomicNumber: 31, symbol: 'Ga', name: 'Gallium', atomicMass: 69.723, densityKgPerM3: 5910, category: ElementCategory.postTransitionMetal, crustalAbundance: 1.9e-5),
        ChemicalElement(atomicNumber: 32, symbol: 'Ge', name: 'Germanium', atomicMass: 72.63, densityKgPerM3: 5323, category: ElementCategory.metalloid, crustalAbundance: 1.5e-6),
        ChemicalElement(atomicNumber: 36, symbol: 'Kr', name: 'Krypton', atomicMass: 83.798, densityKgPerM3: 3.749, category: ElementCategory.nobleGas, crustalAbundance: 1e-10),
        ChemicalElement(atomicNumber: 40, symbol: 'Zr', name: 'Zirconium', atomicMass: 91.224, densityKgPerM3: 6520, category: ElementCategory.transitionMetal, crustalAbundance: 1.65e-4),
        ChemicalElement(atomicNumber: 42, symbol: 'Mo', name: 'Molybdenum', atomicMass: 95.95, densityKgPerM3: 10280, category: ElementCategory.transitionMetal, crustalAbundance: 1.2e-6),
        ChemicalElement(atomicNumber: 47, symbol: 'Ag', name: 'Silver', atomicMass: 107.868, densityKgPerM3: 10490, category: ElementCategory.transitionMetal, crustalAbundance: 7.5e-8),
        ChemicalElement(atomicNumber: 50, symbol: 'Sn', name: 'Tin', atomicMass: 118.71, densityKgPerM3: 7287, category: ElementCategory.postTransitionMetal, crustalAbundance: 2.3e-6),
        ChemicalElement(atomicNumber: 54, symbol: 'Xe', name: 'Xenon', atomicMass: 131.293, densityKgPerM3: 5.894, category: ElementCategory.nobleGas, crustalAbundance: 3e-11),
        ChemicalElement(atomicNumber: 57, symbol: 'La', name: 'Lanthanum', atomicMass: 138.905, densityKgPerM3: 6162, category: ElementCategory.lanthanide, crustalAbundance: 3.9e-5),
        ChemicalElement(atomicNumber: 58, symbol: 'Ce', name: 'Cerium', atomicMass: 140.116, densityKgPerM3: 6770, category: ElementCategory.lanthanide, crustalAbundance: 6.65e-5),
        ChemicalElement(atomicNumber: 60, symbol: 'Nd', name: 'Neodymium', atomicMass: 144.242, densityKgPerM3: 7010, category: ElementCategory.lanthanide, crustalAbundance: 4.15e-5),
        ChemicalElement(atomicNumber: 73, symbol: 'Ta', name: 'Tantalum', atomicMass: 180.948, densityKgPerM3: 16690, category: ElementCategory.transitionMetal, crustalAbundance: 2e-6),
        ChemicalElement(atomicNumber: 74, symbol: 'W', name: 'Tungsten', atomicMass: 183.84, densityKgPerM3: 19250, category: ElementCategory.transitionMetal, crustalAbundance: 1.25e-6),
        ChemicalElement(atomicNumber: 78, symbol: 'Pt', name: 'Platinum', atomicMass: 195.084, densityKgPerM3: 21450, category: ElementCategory.transitionMetal, crustalAbundance: 5e-9),
        ChemicalElement(atomicNumber: 79, symbol: 'Au', name: 'Gold', atomicMass: 196.967, densityKgPerM3: 19300, category: ElementCategory.transitionMetal, crustalAbundance: 4e-9),
        ChemicalElement(atomicNumber: 82, symbol: 'Pb', name: 'Lead', atomicMass: 207.2, densityKgPerM3: 11340, category: ElementCategory.postTransitionMetal, crustalAbundance: 1.4e-5),
        ChemicalElement(atomicNumber: 90, symbol: 'Th', name: 'Thorium', atomicMass: 232.038, densityKgPerM3: 11724, category: ElementCategory.actinide, crustalAbundance: 9.6e-6),
        ChemicalElement(atomicNumber: 92, symbol: 'U', name: 'Uranium', atomicMass: 238.029, densityKgPerM3: 19050, category: ElementCategory.actinide, crustalAbundance: 2.7e-6),
      ]);
}
