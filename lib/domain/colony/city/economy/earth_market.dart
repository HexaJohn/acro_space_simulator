// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Earth's SEED prices: what each commodity cost on the world market, at
/// the bottom of Earth's gravity well, on the day the world economy starts
/// (docs/plans/factory-floors.md §3 "Prices are local and derived";
/// docs/plans/dynamic-markets.md §3 "Earth is a market like any other").
///
/// Earth is the one market every colony can always buy from, so its price
/// plus the cost of lifting the good out of Earth's well and landing it is
/// the IMPORT CEILING on every off-world price (`local_prices.dart`). Each
/// number is a real-world bulk or industrial price scaled by the
/// commodity's unit mass (`commodity_mass.dart`).
///
/// **Only a seed.** Since dynamic markets, Earth's LIVE prices are a
/// `Market` (`markets.dart`) seeded from this table once
/// (`seedEarthMarket`) and then moved every day by the world's supply and
/// demand. Nothing may read this table as a live price. What still reads it
/// reads it as a fixed WEIGHT, never as what a good sells for: the
/// joint-product cost split in `local_prices.dart`, the floor reward cap's
/// value measure (`city_factory_port.dart`, `factory_floors.dart`), the
/// methalox fallback a bare transport model prices propellant at, and a
/// bare solve handed no live Earth market (a test).
///
/// Credits ≈ US dollars of the 2020s; `kCreditsToFunds` converts them to the
/// treasury's §.
library;

import '../commodity.dart';
import '../factory/factory_item.dart';
import 'commodity_mass.dart';

/// Earth price per kilogram of each commodity, credits. Multiplied by
/// [kgPerUnit] in [earthPrice], so the per-kg figure stays the readable,
/// checkable one.
const Map<String, double> kEarthPricePerKg = {
  // Run-of-mine ore at the pit, ~$40/t: roughly what it costs to blast,
  // load and haul. NOT 62% Fe concentrate fines (~$110/t, the first
  // calibration): the colony's ore is crude, low-grade rock — a Steel Mill
  // turns 2 t of it into 0.19 t of steel and tube, a yield under a tenth,
  // where a tonne of fines makes ~0.6 t of steel. At the fines price every
  // Earth steel mill lost ~30% of its revenue on ore alone and closed within
  // a month (wave 3 integration, economy_plant_health_test.dart).
  Commodity.ore: 0.04,
  // Municipal water, ~$2/m³ in a developed city.
  Commodity.water: 0.002,
  // Packaged staple food at retail-wholesale, ~$3/kg.
  Commodity.food: 3,
  // Bulk industrial liquid oxygen, ~$0.10-0.30/kg; medical/breathing grade
  // on the high side.
  Commodity.oxygen: 0.2,
  // Generic pharmaceuticals and consumables, ~$100/kg as shipped.
  Commodity.medicine: 100,
  // Waste has no market price: the colony pays to be rid of it.
  Commodity.garbage: 0,
  Commodity.sewage: 0,
  // Liquefied methane, ~$0.30/kg (LNG at ~$6/MMBtu plus liquefaction).
  Commodity.fuel: 0.3,
  // Liquid oxygen as a bulk oxidizer, ~$0.10/kg from an air separation
  // plant next to the launch site.
  Commodity.oxidizer: 0.1,
  // Hot-rolled steel plate, ~$800/t.
  Commodity.steel: 0.8,
  // Assembled electronics, ~$300/kg (a laptop is ~$1,000 for 2-3 kg;
  // server boards and chips run higher).
  Commodity.electronics: 300,
  // Compute is a local capacity with no world market; it is never imported.
  Commodity.compute: 0,
  // Welded/seamless structural tube, ~$1,500/t.
  Commodity.tubes: 1.5,
  // Rocket engine and avionics parts, ~$1,000/kg (a methalox engine runs
  // ~$1M for ~1.6 t at volume; avionics far more per kg).
  Commodity.rocketParts: 1000,
  // Service rifles, ~$1,000 for ~4 kg.
  Commodity.guns: 250,
  // Rifle ammunition, ~$0.50 a round for 12 g ≈ $42/kg.
  Commodity.ammo: 42,
  // Military rations, ~$20/kg: a US MRE runs ~$13 a meal at ~0.65 kg.
  // The first calibration's $8 for a whole ~1 kg meal-day was below what
  // the Rations Plant's 18 packers cost at the derived Earth wage (~$7/s
  // against $6.40/s of rations), so every private rations plant closed
  // (wave 3 integration, economy_plant_health_test.dart).
  Commodity.rations: 20,
  // Tactical missiles, ~$1.5M for ~1 t.
  Commodity.missiles: 1500,
  // ---- Factory intermediates (factory_item.dart) ----
  // Merchant pig iron, ~$450/t.
  'pigIron': 0.45,
  // Blast-furnace slag, sold as aggregate or cement feed, ~$20/t.
  'slag': 0.02,
  // Steel billet, ~$600/t (semi-finished, below rolled plate).
  'steelBillet': 0.6,
};

/// Earth price per kg for a commodity no entry covers: the median of the
/// manufactured goods above (~steel/tubes), so an unknown good is neither
/// free nor prohibitively dear.
const double kEarthUnknownPricePerKg = 1.0;

/// Earth price of ONE unit of [commodity], credits. A crate id
/// (`crate:steel`) prices as the commodity units it holds.
double earthPrice(String commodity) {
  final item = FactoryItems.byId(commodity);
  if (item != null && item.commodity != commodity) {
    return earthPrice(item.commodity) * item.commodityUnits;
  }
  final perKg = kEarthPricePerKg[commodity] ?? kEarthUnknownPricePerKg;
  return perKg * kgPerUnit(commodity);
}

/// Mass ratio of oxidizer to fuel in a methalox load (O/F ≈ 3.6 for a
/// full-flow staged combustion engine).
const double kMethaloxOxidizerToFuel = 3.6;

/// Earth's price per kg of mixed methalox propellant, credits: the fuel and
/// oxidizer prices above blended at [kMethaloxOxidizerToFuel].
double earthPropellantPerKg() {
  final fuel = kEarthPricePerKg[Commodity.fuel]!;
  final ox = kEarthPricePerKg[Commodity.oxidizer]!;
  return (fuel + ox * kMethaloxOxidizerToFuel) / (1 + kMethaloxOxidizerToFuel);
}
