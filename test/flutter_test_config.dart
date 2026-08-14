// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:async';

import 'helpers/register_baked_dems.dart';

/// Global test bootstrap (auto-discovered by flutter_test for every test file
/// under test/).
///
/// Registers the baked DEM pyramids ONCE per process: any catalogue body with
/// `demBodyId` (moon, earth) throws by design when its terrain field is built
/// unregistered, and with Earth in that set the throw would otherwise reach
/// every test that spawns a craft near Earth — most of the application-tick
/// suite. Individual files may still call [registerBakedDemsForTest]
/// themselves (it is idempotent); keeping those calls documents the
/// dependency where it is load-bearing.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  registerBakedDemsForTest();
  await testMain();
}
