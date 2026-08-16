// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Repo-wide checks on the SOURCE TEXT, which no other suite covers: every
/// other test reads what the code means, and this one reads what is actually in
/// the file.
///
/// The byte check exists because a raw NUL byte once sat inside a string literal
/// in `lib/domain/craft/craft_design.dart` — the analyzer accepted it, the tests
/// passed, and the file still behaved correctly. What broke was every tool that
/// classifies files by content: ripgrep dropped the file from `AttachKind.stack`
/// results entirely, and `git diff` reported it as `-  -`, i.e. binary. A source
/// file that searches and diffs as binary is one nobody can review, and nothing
/// in a normal test run would ever say so.
///
/// The layering check exists for the same reason in a different medium. The
/// DDD/CLEAN layout is a rule about which file may name which file, and the
/// analyzer has no opinion about it: `lib/domain` importing `package:flutter`
/// compiles, links, and passes every behavioural test in the repo, and the cost
/// only lands later — a domain that cannot be exercised headless, an adapter
/// that drags the renderer into a unit test, a layer that can no longer be
/// swapped. Reading does not catch it either: one outward import — an
/// `lib/adapters` presenter reaching into `lib/infrastructure/flutter_scene/`,
/// say — is a single line among a screenful of legitimate ones. Import
/// directives are a property of the TEXT, so this is where the rule can be
/// stated mechanically.
void main() {
  /// Every Dart source under [dir], a repo-relative `/`-separated path.
  List<File> dartSourcesIn(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    return [
      for (final e in d.listSync(recursive: true))
        if (e is File && e.path.endsWith('.dart')) e,
    ];
  }

  /// Every Dart source in the repo, excluding build output and dependencies.
  List<File> dartSources() => [
        for (final dir in const ['lib', 'test', 'tool']) ...dartSourcesIn(dir),
      ];

  /// [f]'s path with the platform separator normalised to `/`, so a reason
  /// string reads the same on every host and a prefix test can be written once.
  String repoPath(File f) => f.path.replaceAll(r'\', '/');

  test('no Dart source carries a control byte', () {
    // Tab, LF and CR are the only control characters a source file has any use
    // for. Anything else below 0x20 is a paste accident or a corrupted edit,
    // and every one of them is invisible in an editor.
    const allowed = {0x09, 0x0A, 0x0D};
    final offenders = <String>[];

    final sources = dartSources();
    expect(sources, isNotEmpty, reason: 'the scan must have found the sources');

    for (final f in sources) {
      final bytes = f.readAsBytesSync();
      for (var i = 0; i < bytes.length; i++) {
        final b = bytes[i];
        if (b >= 0x20 || allowed.contains(b)) continue;
        offenders.add('${f.path} offset $i: '
            'byte 0x${b.toRadixString(16).padLeft(2, '0')}');
        break; // one report per file is enough to send someone to it
      }
    }

    expect(offenders, isEmpty,
        reason: 'a control byte makes the file unsearchable and makes git '
            'treat it as binary:\n${offenders.join('\n')}');
  });

  test('no Dart source opens with a byte-order mark', () {
    // A UTF-8 BOM is legal UTF-8 and invisible in every editor, so a file that
    // picks one up (a Windows tool writing UTF-8-with-signature is the usual
    // way) looks identical to one that has not. It is not a control byte, so
    // the check above does not see it, and Dart tolerates it — but it is three
    // bytes in front of the first character, which is enough to defeat any
    // scan anchored to the start of the file. The license-header check is one
    // such scan, and it reports the file as having NO header at all.
    final offenders = <String>[];
    for (final f in dartSources()) {
      final head = f.openSync().readSync(3);
      if (head.length == 3 &&
          head[0] == 0xEF &&
          head[1] == 0xBB &&
          head[2] == 0xBF) {
        offenders.add(repoPath(f));
      }
    }
    expect(offenders, isEmpty,
        reason: 'the file starts with three invisible bytes, so anything '
            'reading from offset 0 sees the wrong first character:\n'
            '${offenders.join('\n')}');
  });

  test('every Dart source carries the license header', () {
    // The repo ships under PolyForm Noncommercial; the header is the only
    // place that says so inside the source, and it is copied by hand into
    // every new file. Checking it here is what stops the one file nobody
    // remembered from being the one someone copies next.
    const header = '// Copyright (c) 2026 John Peroutka\n'
        '//\n'
        '// This work is licensed under the PolyForm Noncommercial License '
        '1.0.0.\n'
        '// To view a copy of this license, visit '
        'https://polyformproject.org/licenses/noncommercial/1.0.0/';
    final offenders = <String>[];
    for (final f in dartSources()) {
      // Normalised so a CRLF checkout is not reported as a missing header:
      // the rule is about the TEXT, and line endings are the platform's.
      final text = f.readAsStringSync().replaceAll('\r\n', '\n');
      // Machine-written sources are exempt: `flatc` rewrites this file whole
      // from `wire/sim.fbs` on every schema change, so a header pasted into it
      // survives exactly until the next regeneration. The exemption is keyed
      // off the generator's own banner rather than a filename list, so it
      // covers whatever else is generated later and nothing that is not.
      if (text.startsWith('// automatically generated by')) continue;
      if (!text.startsWith(header)) offenders.add(repoPath(f));
    }
    expect(offenders, isEmpty,
        reason: 'these files are missing the 4-line license header, or their '
            'first bytes are not what they look like:\n'
            '${offenders.join('\n')}');
  });

  // ---------------- Layering ----------------

  /// One `import`/`export` directive and the URI it names.
  ///
  /// Line-oriented on purpose. Every directive in this repo is written on one
  /// line, and a scan a reader can verify at a glance is worth more here than
  /// one that survives a URI split across lines. The trade is that a directive
  /// quoted inside a comment or a string would read as real; the failure names
  /// the file and the URI, so the next reader can see for themselves in one
  /// jump.
  final directive =
      RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);

  /// The URIs [f] imports or exports, in file order.
  List<String> importedUris(File f) => [
        for (final m in directive.allMatches(f.readAsStringSync())) m.group(1)!,
      ];

  /// The package name in a `package:<name>/...` URI, or null for `dart:` and
  /// relative URIs.
  ///
  /// Matched as a NAME rather than as a string prefix: `package:flutter` as a
  /// prefix would also condemn a hypothetical `package:flutterfire`, and a rule
  /// that bans more than it says is a rule the next reader has to re-derive.
  String? packageNameOf(String uri) {
    if (!uri.startsWith('package:')) return null;
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    return slash < 0 ? rest : rest.substring(0, slash);
  }

  /// What each layer under `lib/` is forbidden to name.
  ///
  /// [packages] are package names; [layers] are `lib/` layer directories,
  /// matched as a whole path SEGMENT so one entry catches both spellings of the
  /// same dependency — `package:acro_space_simulator/infrastructure/...` and a
  /// relative `../../infrastructure/...` — while never firing on a file that
  /// merely has the word somewhere in its name.
  ///
  /// The bans point INWARD-ONLY, which is the whole content of the layering
  /// rule: a layer may name anything nearer the domain than itself and nothing
  /// further out. `lib/adapters` may therefore import `lib/application` and
  /// `lib/domain` freely, and that is why only `infrastructure` is listed for
  /// it.
  const layering = <({
    String dir,
    Set<String> packages,
    Set<String> layers,
    String why,
  })>[
    (
      dir: 'lib/domain',
      packages: {'flutter', 'flutter_scene', 'flutter_test'},
      layers: {'adapters', 'application', 'infrastructure'},
      why: 'the domain is the innermost layer — pure Dart, no framework, no '
          'outward dependency — which is what lets the simulation be run '
          'headless, be tested without a widget pump, and outlive the renderer '
          'in front of it',
    ),
    (
      dir: 'lib/adapters',
      packages: {'flutter', 'flutter_scene', 'flutter_test'},
      layers: {'infrastructure'},
      why: 'an adapter is pure math over domain types (dart:ui is fine, '
          'material.dart and flutter_scene are not): infrastructure calls '
          'adapters, never the reverse, or the presenters cannot be tested '
          'without a scene',
    ),
  ];

  for (final rule in layering) {
    test('${rule.dir} imports nothing further out than itself', () {
      final sources = dartSourcesIn(rule.dir);
      expect(sources, isNotEmpty,
          reason: '${rule.dir} was not scanned at all, so this guard proved '
              'nothing — run the suite from the repo root');

      final offenders = <String>[];
      for (final f in sources) {
        for (final uri in importedUris(f)) {
          final package = packageNameOf(uri);
          if (package != null && rule.packages.contains(package)) {
            offenders.add('${repoPath(f)} imports "$uri"');
            continue;
          }
          for (final segment in uri.split('/')) {
            if (!rule.layers.contains(segment)) continue;
            offenders.add('${repoPath(f)} imports "$uri"');
            break;
          }
        }
      }

      expect(offenders, isEmpty,
          reason: '${rule.dir} may not depend on '
              '${{...rule.packages, ...rule.layers}.join(', ')}: '
              '${rule.why}.\n${offenders.join('\n')}');
    });
  }
}
