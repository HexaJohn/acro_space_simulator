import 'package:acro_space_simulator/domain/elements/chemical_element.dart';
import 'package:acro_space_simulator/domain/elements/periodic_table.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final table = PeriodicTable.standard();

  test('contains the common mining + space-relevant elements', () {
    for (final symbol in [
      'H', 'He', 'C', 'N', 'O', 'Al', 'Si', 'Ti', 'Fe', 'Ni',
      'Cu', 'U', 'Au', 'Pt', 'Li', 'Xe', 'W', 'Nd' // rare earth
    ]) {
      expect(table.bySymbol(symbol), isNotNull, reason: '$symbol should exist');
    }
  });

  test('elements have correct atomic numbers and ordering', () {
    expect(table.bySymbol('H')!.atomicNumber, 1);
    expect(table.bySymbol('Fe')!.atomicNumber, 26);
    expect(table.bySymbol('U')!.atomicNumber, 92);
  });

  test('elements carry real density and category data', () {
    final iron = table.bySymbol('Fe')!;
    expect(iron.densityKgPerM3, closeTo(7874, 50));
    expect(iron.category, ElementCategory.transitionMetal);

    final hydrogen = table.bySymbol('H')!;
    expect(hydrogen.category, ElementCategory.nonmetal);
  });

  test('crustal abundance is set and oxygen is the most abundant', () {
    final o = table.bySymbol('O')!;
    final au = table.bySymbol('Au')!;
    expect(o.crustalAbundance, greaterThan(au.crustalAbundance)); // O >> Au
    expect(au.crustalAbundance, greaterThan(0));
  });

  test('lookups by atomic number work', () {
    expect(table.byNumber(8)!.symbol, 'O');
    expect(table.byNumber(92)!.symbol, 'U');
  });

  test('fissile / noble-gas / rare-earth categories are represented', () {
    expect(table.all.any((e) => e.category == ElementCategory.actinide), isTrue);
    expect(table.all.any((e) => e.category == ElementCategory.nobleGas), isTrue);
    expect(table.all.any((e) => e.category == ElementCategory.lanthanide), isTrue);
  });

  test('every element has a unique symbol and positive atomic number', () {
    final symbols = <String>{};
    for (final e in table.all) {
      expect(e.atomicNumber, greaterThan(0));
      expect(symbols.add(e.symbol), isTrue, reason: 'dup ${e.symbol}');
    }
    expect(table.all.length, greaterThanOrEqualTo(40));
  });
}
