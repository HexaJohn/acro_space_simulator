// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Drives a running `main_city_game_dev` app: prints the colony's live numbers
/// and captures a screenshot, so a city-builder run can be judged from the
/// console instead of by eye.
///
///     dart run tool/drive_city_game.dart <vm-service-uri> [out.png]
///         [waitSeconds] [walk] [key=value ...]
///
/// Every later argument of the form `key=value` is one call to
/// `ext.acro.citygame`, sent in order after the settle and before the status
/// is read; `&` joins the parameters of one call. So
///
///     drive_city_game.dart <uri> shot.png 20 - zone=residential step=600 \
///         traffic=spawn&n=20 traffic=stats
///
/// zones the streets, runs ten minutes of colony time (the call answers once
/// the colony has advanced), forces twenty car trips and prints the agent
/// traffic's numbers. `-` keeps the fourth place empty.
library;

import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: drive_city_game.dart <vm-service-uri> '
        '[out.png] [waitSeconds] [walk] [key=value ...]');
    exit(64);
  }
  // The service URI is always first: its token may end in '=' itself.
  final rest = args.skip(1);
  final positional = [for (final a in rest) if (!_isCall(a)) a];
  final calls = [for (final a in rest) if (_isCall(a)) a];
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  final out = positional.isNotEmpty ? positional[0] : 'city_game_shot.png';
  final wait = positional.length > 1 ? int.parse(positional[1]) : 20;

  final vm = await vmServiceConnectUri(ws);
  final isolateId = (await vm.getVM()).isolates!.first.id!;

  Future<Map<String, dynamic>> call(String method,
      [Map<String, String> params = const {}]) async {
    final r =
        await vm.callServiceExtension(method, isolateId: isolateId, args: params);
    return (r.json ?? const {}).cast<String, dynamic>();
  }

  // The first frames are terrain streaming and shader warm-up; a shot taken
  // then is a picture of a loading screen.
  stdout.writeln('== settling for ${wait}s');
  await Future<void>.delayed(Duration(seconds: wait));

  // `walk` as a fourth argument steps out onto the streets first, so the
  // report shows the walker's camera and whether the mouse was captured.
  if (positional.length > 2 && positional[2] == 'walk') {
    await call('ext.acro.citygame', {'walk': 'on'});
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  // The forwarded calls, in order, each with what it did; the colony's own
  // numbers come with the status below. Then a moment for the renderer to
  // draw what they changed.
  for (final c in calls) {
    final r = await call('ext.acro.citygame', _params(c));
    stdout.writeln('== $c');
    final did = r['did'];
    if (did is Map) {
      for (final e in did.entries) {
        stdout.writeln('   ${e.key}: ${e.value}');
      }
    }
  }
  if (calls.isNotEmpty) await Future<void>.delayed(const Duration(seconds: 2));

  final s = await call('ext.acro.citygame');
  stdout.writeln('== colony');
  for (final e in s.entries) {
    stdout.writeln('   ${e.key}: ${e.value}');
  }

  final shot = await call('ext.acro.screenshot', {'path': out});
  stdout.writeln('== ${shot['saved'] ?? shot}');
  await vm.dispose();
}

/// A `key=value` argument, as opposed to a positional or a `--flag`.
bool _isCall(String arg) => !arg.startsWith('-') && arg.indexOf('=') > 0;

/// `a=1&b=2` as one call's parameters.
Map<String, String> _params(String call) => {
      for (final kv in call.split('&'))
        if (kv.indexOf('=') > 0)
          kv.substring(0, kv.indexOf('=')): kv.substring(kv.indexOf('=') + 1),
    };
