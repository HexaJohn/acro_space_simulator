// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The web build refuses an integer literal that a double cannot hold
/// exactly: "The integer literal 0x5851F42D4C957F2D can't be represented
/// exactly in JavaScript". Nothing native notices — the VM compiles it and
/// every test passes — and the release's `flutter build web` job fails on
/// the tag. So the check is made here, over every source file the app is
/// built from.
void main() {
  test('no integer literal in lib/ is past what the web can hold exactly',
      () {
    final offenders = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final f in files) {
      final lines = codeLinesOf(f.readAsStringSync());
      for (var i = 0; i < lines.length; i++) {
        for (final literal in integerLiteralsIn(lines[i])) {
          if (!webExactLiteral(literal)) {
            offenders.add('${f.path}:${i + 1}: $literal');
          }
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'dart2js cannot compile these; build 64-bit mixing from '
            '32-bit arithmetic instead (see city_tile_bucketing.dart)');
  });

  test('the scan flags what dart2js refuses, and only that', () {
    expect(webExactLiteral('0x5851F42D4C957F2D'), isFalse);
    expect(webExactLiteral('9007199254740993'), isFalse);
    expect(webExactLiteral('9007199254740992'), isTrue);
    expect(webExactLiteral('0xFFFFFFFF'), isTrue);
    expect(webExactLiteral('0x1FFFFFFFFFFFFF'), isTrue);
    // A double holds 2^62 exactly, so the web takes it.
    expect(webExactLiteral('0x4000000000000000'), isTrue);
    expect(webExactLiteral('1_000_000'), isTrue);

    expect(integerLiteralsIn('final m = 0x5851F42D4C957F2D;'),
        ['0x5851F42D4C957F2D']);
    expect(integerLiteralsIn('x = 12345678901234567 + 7;'),
        ['12345678901234567', '7']);
    // Doubles are not integer literals, nor digits inside a name.
    expect(integerLiteralsIn('final d = 12345678901234567.5e3, v2 = x86;'),
        isEmpty);
    // Comments are not code.
    expect(
        codeLinesOf('a = 1; // 0x5851F42D4C957F2D\n'
            '/* 0x5851F42D4C957F2D\n 0x5851F42D4C957F2D */ b = 2;'),
        ['a = 1; ', '', ' b = 2;']);
  });
}

/// [source] line by line with its comments blanked, so a literal in a doc
/// comment is not taken for code. Block comments keep their line breaks,
/// so line numbers still match the file's.
List<String> codeLinesOf(String source) {
  final noBlocks = source.replaceAllMapped(RegExp(r'/\*[\s\S]*?\*/'),
      (m) => '\n' * '\n'.allMatches(m[0]!).length);
  return [
    for (final line in noBlocks.split('\n'))
      line.replaceFirst(RegExp(r'//.*$'), ''),
  ];
}

/// The integer literals in one line of code: hex, and decimal digits not
/// part of a double or a name. (A literal inside a string would be taken
/// too; none is past 2^53, and none should be.)
Iterable<String> integerLiteralsIn(String line) => [
      for (final m in RegExp(r'(?<![\w.$])0[xX][0-9a-fA-F][0-9a-fA-F_]*(?![\w$])')
          .allMatches(line))
        m[0]!,
      for (final m
          in RegExp(r'(?<![\w.$])\d[\d_]*(?![\w.$])').allMatches(line))
        m[0]!,
    ];

/// Whether the web can hold [literal] exactly: its value survives a round
/// trip through a double.
bool webExactLiteral(String literal) {
  final text = literal.replaceAll('_', '');
  final hex = text.startsWith('0x') || text.startsWith('0X');
  final value = hex
      ? BigInt.parse(text.substring(2), radix: 16)
      : BigInt.parse(text);
  return BigInt.from(value.toDouble()) == value;
}
