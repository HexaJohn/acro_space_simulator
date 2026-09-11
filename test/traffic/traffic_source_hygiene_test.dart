// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The agent simulation's determinism rules, read off its SOURCE TEXT
/// (docs/plans/agent-traffic.md, D27 and §17.4).
///
/// Two colonies with one seed and one input must make one history: that is
/// what the twin-run, partition and frame-hold tests pin, and what a save
/// resumed on another machine relies on. Each rule here names a way to break
/// it that compiles, passes every behavioural test on the machine that wrote
/// it, and diverges somewhere else:
///
/// - `Random` (dart:math) is the platform's generator, and unseeded it reads
///   the clock. Draws come from `TrafficRng`.
/// - `hashCode`, `Object.hash` and `identityHashCode` are free to differ
///   between runs, so a key or a digest built on them is a different key
///   tomorrow. Hashes come from `fnv1a32`.
/// - `DateTime` and `Stopwatch` put the wall clock into the result. The one
///   exception is traffic_metrics.dart, which only REPORTS timings.
/// - A `Map` or a `Set` iterates in an order the simulation did not choose.
///   Maps are for lookup; iteration runs over integer ids. agents_codec.dart
///   may iterate, because it sorts first. An enum's own `values` is an
///   ordered list, and is allowed.
///
/// The scan is textual and line by line, over code with its comments and
/// string literals blanked, so the rules can be discussed in a doc comment
/// without tripping them. The trade is the one every text scan makes: a
/// collection is recognised by how it is declared in the same file.
void main() {
  test('the traffic simulation keeps the determinism rules', () {
    final dir = Directory(_trafficDir);
    expect(dir.existsSync(), isTrue,
        reason: '$_trafficDir was not found — run the suite from the repo '
            'root, or this guard proves nothing');
    final files = [
      for (final e in dir.listSync(recursive: true))
        if (e is File && e.path.endsWith('.dart')) e,
    ]..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty, reason: 'nothing was scanned');

    final offenders = <String>[
      for (final f in files)
        ..._offences(f.path.replaceAll(r'\', '/'), f.readAsStringSync()),
    ];
    expect(offenders, isEmpty,
        reason: 'the traffic simulation must give one history per seed on '
            'every run:\n${offenders.join('\n')}');
  });

  test('the scan flags what it means to, and only that', () {
    List<String> scan(String code, [String file = 'x.dart']) =>
        _offences('$_trafficDir/$file', '$_header\n$code\n');

    for (final bad in const [
      'final r = math.Random(7);',
      'final r = Random();',
      'final h = key.hashCode;',
      'final h = Object.hash(a, b);',
      'final h = identityHashCode(a);',
      'final t = DateTime.now();',
      'final w = Stopwatch()..start();',
      'for (final k in byId.keys) {}',
      'for (final e in byId.entries) {}',
      'byId.forEach((k, v) {});',
      'final all = byId.values.toList();',
      'final n = snapshot().values.length;',
      'final seen = <int>{};\nfor (final s in seen) {}',
      'final Set<int> seen = {};\nfinal xs = [...seen];',
      'final seen = <int>{};\nfinal f = seen.first;',
      'final seen = HashSet<int>();\nfinal l = seen.toList();',
      'final Map<String, List<int>> byRoad = {};\nfinal m = byRoad.map((k, v) => v);',
    ]) {
      expect(scan(bad), isNotEmpty, reason: 'should be flagged: $bad');
    }

    for (final ok in const [
      'for (final k in AgentKind.values) {}',
      'final n = RoadClass.values.length;',
      'final p = _Phase.values[i];',
      '// math.Random, DateTime and byId.keys, in a comment',
      '/// Stopwatch and Object.hash, in a doc comment',
      '/* a block comment\n   with DateTime.now() in it */ final x = 1;',
      "final s = 'DateTime.now() in a string';",
      'final seen = <int>{};\nfinal has = seen.contains(3) && seen.length > 1;',
      'final rng = TrafficRng(7);',
      'final Set<TripKind>? kinds = null;\nfinal k = kinds?.contains(TripKind.goods);',
      'final id = byId[key];',
    ]) {
      expect(scan(ok), isEmpty, reason: 'should pass: $ok');
    }

    // Each exemption covers its own file and its own rule only.
    expect(scan('final w = Stopwatch();', 'traffic_metrics.dart'), isEmpty);
    expect(scan('final t = DateTime.now();', 'traffic_metrics.dart'),
        isNotEmpty);
    expect(scan('for (final k in byId.keys) {}', 'agents_codec.dart'),
        isEmpty);
    expect(scan('final r = Random();', 'agents_codec.dart'), isNotEmpty);

    // A file without the license header is caught as well.
    expect(_offences('$_trafficDir/x.dart', 'void f() {}\n'), isNotEmpty);
  });
}

/// Where the agent simulation lives.
const _trafficDir = 'lib/domain/colony/city/traffic';

/// The only file that may time anything, because it only reports.
const _metricsFile = 'traffic_metrics.dart';

/// The only file that may iterate a map, because it sorts what it writes.
const _codecFile = 'agents_codec.dart';

/// The repo's license header, which every source opens with.
const _header = '// Copyright (c) 2026 John Peroutka\n'
    '//\n'
    '// This work is licensed under the PolyForm Noncommercial License '
    '1.0.0.\n'
    '// To view a copy of this license, visit '
    'https://polyformproject.org/licenses/noncommercial/1.0.0/';

/// One banned pattern, what it breaks, and the one file allowed it.
typedef _Rule = ({RegExp pattern, String why, String? exempt});

final List<_Rule> _rules = [
  (
    pattern: RegExp(r'\bRandom\b'),
    why: 'dart:math Random — draw from TrafficRng',
    exempt: null,
  ),
  (
    pattern: RegExp(r'\.hashCode\b|\bidentityHashCode\b|\bObject\.hash'),
    why: 'a platform hash — hash with fnv1a32',
    exempt: null,
  ),
  (
    pattern: RegExp(r'\bDateTime\b'),
    why: 'the wall clock — agent time is AgentClock',
    exempt: null,
  ),
  (
    pattern: RegExp(r'\bStopwatch\b'),
    why: 'the wall clock — only traffic_metrics.dart may time, to report',
    exempt: _metricsFile,
  ),
  (
    pattern: RegExp(r'\.(?:entries|keys)\b|\.forEach\('),
    why: 'iterates a map — iterate integer ids',
    exempt: _codecFile,
  ),
];

/// `.values`, with the name it is read from (absent after a call or index).
final _values = RegExp(r'(\b\w+)?\s*\.values\b');

/// A name an enum could have, whose `values` is its ordered member list.
final _enumName = RegExp(r'^_?[A-Z]');

const _collectionTypes = 'Map|Set|HashMap|HashSet|LinkedHashMap|LinkedHashSet|'
    'SplayTreeMap|SplayTreeSet';

/// A name declared with a map or set type: `Set<int> seen`,
/// `Map<String, int> get byId`.
final _typedDeclaration = RegExp(
    '\\b(?:$_collectionTypes)\\s*<[^;=(){}]*>\\??\\s+(?:get\\s+)?(\\w+)');

/// A name initialised from a map or set literal or constructor:
/// `seen = <int>{}`, `byId = {}`, `seen = HashSet<int>()`.
final _initialised = RegExp('\\b(\\w+)\\s*=\\s*(?:const\\s+)?'
    '(?:(?:<[^;(){}]*>\\s*)?\\{|(?:$_collectionTypes)\\b)');

/// What iterating a collection looks like, after its name.
const _iterating = 'map|where|whereType|expand|fold|reduce|first|last|single|'
    'firstWhere|lastWhere|singleWhere|toList|join|iterator|elementAt|skip|'
    'take|skipWhile|takeWhile|followedBy|cast';

/// [source] line by line: block comments, string literals and line comments
/// blanked, line numbers kept.
List<String> _codeLines(String source) {
  final text = source.replaceAll('\r\n', '\n');
  final noBlocks = text.replaceAllMapped(RegExp(r'/\*[\s\S]*?\*/'),
      (m) => '\n' * '\n'.allMatches(m[0]!).length);
  final strings =
      RegExp(r"'(?:[^'\\\n]|\\.)*'" '|' r'"(?:[^"\\\n]|\\.)*"');
  final lineComment = RegExp(r'//.*$');
  return [
    for (final line in noBlocks.split('\n'))
      line.replaceAll(strings, "''").replaceFirst(lineComment, ''),
  ];
}

/// Every rule [source] (the file at repo path [path]) breaks, one line each.
List<String> _offences(String path, String source) {
  final out = <String>[];
  if (!source.replaceAll('\r\n', '\n').startsWith(_header)) {
    out.add('$path: missing the 4-line license header');
  }
  final file = path.split('/').last;
  final lines = _codeLines(source);

  // The maps and sets this file declares, by name.
  final collections = <String>{
    for (final line in lines) ...[
      for (final m in _typedDeclaration.allMatches(line)) m[1]!,
      for (final m in _initialised.allMatches(line)) m[1]!,
    ],
  };
  final iterations = [
    for (final name in collections)
      (
        name: name,
        pattern: RegExp('\\bin\\s+(?:this\\.)?$name\\s*\\)'
            '|\\.\\.\\.\\??(?:this\\.)?$name\\b'
            '|\\b$name\\s*\\??\\.\\s*(?:$_iterating)\\b'),
      ),
  ];

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final at = '$path:${i + 1}';
    for (final rule in _rules) {
      if (rule.exempt == file) continue;
      if (rule.pattern.hasMatch(line)) out.add('$at: ${rule.why}');
    }
    if (file == _codecFile) continue;
    for (final m in _values.allMatches(line)) {
      final owner = m[1];
      if (owner != null && _enumName.hasMatch(owner)) continue;
      out.add('$at: iterates a map\'s values — iterate integer ids');
    }
    for (final it in iterations) {
      if (it.pattern.hasMatch(line)) {
        out.add('$at: iterates the map or set "${it.name}" — iterate '
            'integer ids');
      }
    }
  }
  return out;
}
