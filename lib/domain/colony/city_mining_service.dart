// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import '../mining/resource_deposit.dart';
import 'colony.dart';

/// Large-scale resource extraction by a city's mining buildings. The city is
/// the heavy-industry mining method: many mine buildings together pull from a
/// body's [ResourceDeposit] far faster than a single vessel rig. Domain service.
///
/// Total rate = (sum of building mining rates) * deposit concentration. The
/// extracted resource lands in the colony stockpile (capacity-respecting); the
/// deposit depletes.
class CityMiningService {
  const CityMiningService();

  void advance(Colony colony, ResourceDeposit deposit, {required double dt}) {
    if (deposit.isDepleted) return;

    var rate = 0.0;
    for (final b in colony.buildings) {
      rate += b.spec.miningRate;
    }
    if (rate <= 0) return;

    final requested = rate * deposit.concentration * dt;
    final extracted = deposit.extract(requested);
    if (extracted <= 0) return;

    final sink = colony.stockpile[deposit.resource];
    if (sink == null) return;
    sink.fill(extracted); // overflow is simply lost (no storage)
  }
}
