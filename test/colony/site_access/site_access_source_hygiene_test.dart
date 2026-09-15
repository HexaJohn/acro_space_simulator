// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Site access generation's determinism rules, read off its SOURCE TEXT
/// (docs/plans/site-access.md §2.1, §3.9): the scan of
/// `traffic_source_hygiene_test.dart`, over `lib/domain/colony/city/site_access`.
///
/// Plans are derived, never saved, so a plan must come out the same on every
/// run and every isolate: no `Random`, no `hashCode` / `Object.hash` /
/// `identityHashCode`, no `DateTime` or `Stopwatch`, no iteration of a map or
/// a set (maps are for lookup), no trigonometry (C-11: stall keys are saved,
/// and web and native trig differ in the last bits). And the domain stays
/// pure: no `dart:ui`, no Flutter, no `dart:io`. Every file carries the
/// licence header.
void main() {
  test('site access keeps the determinism and purity rules', () {
    final dir = Directory(_dir);
    expect(dir.existsSync(), isTrue,
        reason: '$_dir was not found — run the suite from the repo root');
    final files = [
      for (final e in dir.listSync(recursive: true))
        if (e is File && e.path.endsWith('.dart')) e,
    ]..sort((a, b) => a.path.compareTo(b.path));
    expect(files.length, greaterThanOrEqualTo(7), reason: 'nothing was scanned');
    final offenders = <String>[
      for (final f in files)
        ..._offences(f.path.replaceAll(r'\', '/'), f.readAsStringSync()),
    ];
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('the scan flags what it means to, and only that', () {
    List<String> scan(String code) => _offences('$_dir/x.dart', '$_header\n$code\n');
    for (final bad in const [
      'final r = math.Random(7);',
      'final h = key.hashCode;',
      'final h = Object.hash(a, b);',
      'final h = identityHashCode(a);',
      'final t = DateTime.now();',
      'final w = Stopwatch()..start();',
      'for (final k in byId.keys) {}',
      'for (final e in byId.entries) {}',
      'byId.forEach((k, v) {});',
      'final all = byId.values.toList();',
      'final seen = <int>{};\nfor (final s in seen) {}',
      'final Map<String, int> m = {};\nfinal xs = [...m.keys];',
      'final a = math.atan2(y, x);',
      'final c = math.cos(t);',
      "import 'dart:ui';",
      "import 'package:flutter/foundation.dart';",
      "import 'dart:io';",
    ]) {
      expect(scan(bad), isNotEmpty, reason: 'should be flagged: $bad');
    }
    for (final ok in const [
      'for (final k in SiteProgram.values) {}',
      'final d = math.sqrt(x);',
      '// Random, DateTime, math.cos and byId.keys, in a comment',
      "final s = 'DateTime.now() in a string';",
      'final seen = <int>{};\nfinal has = seen.contains(3);',
      'final id = byId[key];',
      'final xs = <int>[];\nfor (final x in xs) {}',
    ]) {
      expect(scan(ok), isEmpty, reason: 'should pass: $ok');
    }
    expect(_offences('$_dir/x.dart', 'void f() {}\n'), isNotEmpty);
  });
}

const _dir = 'lib/domain/colony/city/site_access';

const _header = '// Copyright (c) 2026 John Peroutka\n'
    '//\n'
    '// This work is licensed under the PolyForm Noncommercial License '
    '1.0.0.\n'
    '// To view a copy of this license, visit '
    'https://polyformproject.org/licenses/noncommercial/1.0.0/';

final List<(RegExp, String)> _rules = [
  (RegExp(r'\bRandom\b'), 'dart:math Random — tie-break with xorshift32'),
  (
    RegExp(r'\.hashCode\b|\bidentityHashCode\b|\bObject\.hash'),
    'a platform hash — hash with fnv1a32'
  ),
  (RegExp(r'\bDateTime\b|\bStopwatch\b'), 'the wall clock'),
  (RegExp(r'\.(?:entries|keys)\b|\.forEach\('), 'iterates a map'),
  (
    RegExp(r'\bmath\.(?:sin|cos|tan|asin|acos|atan|atan2)\b'),
    'trigonometry — headings are frame unit vectors (C-11)'
  ),
];

/// Imports of the platform, checked on the raw line (strings are the point).
final _imports = RegExp(
    "^\\s*(?:import|export)\\s+'(?:dart:ui|dart:io|package:flutter/)");

final _values = RegExp(r'(\b\w+)?\s*\.values\b');
final _enumName = RegExp(r'^_?[A-Z]');
const _collectionTypes = 'Map|Set|HashMap|HashSet|LinkedHashMap|LinkedHashSet|'
    'SplayTreeMap|SplayTreeSet';
final _typedDeclaration = RegExp(
    '\\b(?:$_collectionTypes)\\s*<[^;=(){}]*>\\??\\s+(?:get\\s+)?(\\w+)');
final _initialised = RegExp('\\b(\\w+)\\s*=\\s*(?:const\\s+)?'
    '(?:(?:<[^;(){}]*>\\s*)?\\{|(?:$_collectionTypes)\\b)');
const _iterating = 'map|where|whereType|expand|fold|reduce|first|last|single|'
    'firstWhere|lastWhere|singleWhere|toList|join|iterator|elementAt|skip|'
    'take|skipWhile|takeWhile|followedBy|cast';

List<String> _codeLines(String source) {
  final text = source.replaceAll('\r\n', '\n');
  final noBlocks = text.replaceAllMapped(RegExp(r'/\*[\s\S]*?\*/'),
      (m) => '\n' * '\n'.allMatches(m[0]!).length);
  final strings = RegExp(r"'(?:[^'\\\n]|\\.)*'" '|' r'"(?:[^"\\\n]|\\.)*"');
  final lineComment = RegExp(r'//.*$');
  return [
    for (final line in noBlocks.split('\n'))
      line.replaceAll(strings, "''").replaceFirst(lineComment, ''),
  ];
}

List<String> _offences(String path, String source) {
  final out = <String>[];
  final text = source.replaceAll('\r\n', '\n');
  if (!text.startsWith(_header)) out.add('$path: missing the licence header');
  final raw = text.split('\n');
  for (var i = 0; i < raw.length; i++) {
    if (_imports.hasMatch(raw[i])) out.add('$path:${i + 1}: platform import');
  }
  final lines = _codeLines(source);
  final collections = <String>{
    for (final line in lines) ...[
      for (final m in _typedDeclaration.allMatches(line)) m[1]!,
      for (final m in _initialised.allMatches(line)) m[1]!,
    ],
  };
  final iterations = [
    for (final name in collections.toList()..sort())
      (
        name,
        RegExp('\\bin\\s+(?:this\\.)?$name\\s*\\)'
            '|\\.\\.\\.\\??(?:this\\.)?$name\\b'
            '|\\b$name\\s*\\??\\.\\s*(?:$_iterating)\\b'),
      ),
  ];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final at = '$path:${i + 1}';
    for (final (pattern, why) in _rules) {
      if (pattern.hasMatch(line)) out.add('$at: $why');
    }
    for (final m in _values.allMatches(line)) {
      final owner = m[1];
      if (owner != null && _enumName.hasMatch(owner)) continue;
      out.add('$at: iterates a map\'s values');
    }
    for (final (name, pattern) in iterations) {
      if (pattern.hasMatch(line)) out.add('$at: iterates the map or set "$name"');
    }
  }
  return out;
}
