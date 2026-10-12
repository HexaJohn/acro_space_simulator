// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How many kilograms ONE unit of each colony commodity weighs
/// (docs/plans/factory-floors.md §3 "Prices are local and derived").
///
/// Mass is what makes a price local. Shipping a good between worlds costs
/// credits per KILOGRAM (Δv → rocket equation → propellant and vehicle wear
/// per kg, `transport_cost.dart`), so the import ceiling on a good is its
/// source price plus transport/kg × kg/unit. A commodity's kg/unit is
/// therefore what decides whether it is worth making locally: oxygen and
/// water are heavy for what they're worth and are always made off Earth,
/// while a unit of electronics carries thousands of credits in ten kilograms
/// and is imported until a local plant exists.
///
/// The colony's commodity units were never given masses, so each entry here
/// picks a real-world unit that fits the game's flows and says why. Where a
/// factory item already fixed a mass (`FactoryItems.ore` is a 1 t pallet,
/// `steel` a 100 kg bundle) the commodity agrees with it, because a dock
/// converts one into the other one for one.
///
/// `compute` has NO mass: it is a live capacity (a data centre's output, used
/// the same second), never a cargo, and nothing ships it between worlds
/// ([isShippable]). Garbage and sewage weigh something but are waste the
/// colony disposes of, not goods it trades.
library;

import '../commodity.dart';
import '../factory/factory_item.dart';

/// Mass of one commodity unit, kg. Every entry is documented with the unit
/// it stands for.
const Map<String, double> kCommodityKgPerUnit = {
  // One ore unit is one 1 t pallet of crushed ore or regolith — the same
  // unit a factory floor's receiving dock unloads (`FactoryItems.ore`).
  Commodity.ore: 1000,
  // One litre of potable water. A colonist drinks and cooks with ~3.5 kg a
  // day (NASA ISS planning figure, hygiene water recycled).
  Commodity.water: 1,
  // One kilogram of food as shipped, packaging included. NASA plans
  // ~1.8 kg per crew-day.
  Commodity.food: 1,
  // One kilogram of breathing oxygen. A resting adult uses ~0.84 kg a day.
  Commodity.oxygen: 1,
  // One kilogram of pharmaceuticals and medical consumables.
  Commodity.medicine: 1,
  // One municipal-waste unit, ~3 kg: about a colonist's daily solid waste
  // (an Earth city makes ~2 kg/person-day; a colony packs more of it).
  Commodity.garbage: 3,
  // One wastewater unit, ~3 kg: a colonist's daily black + grey water once
  // the hygiene loop has recycled most of it.
  Commodity.sewage: 3,
  // One tonne of methane (liquid), the fuel half of a methalox load. The
  // spaceport burns fuel and oxidizer by the unit, so a tonne keeps its
  // numbers launch-sized.
  Commodity.fuel: 1000,
  // One tonne of liquid oxygen, the oxidizer half.
  Commodity.oxidizer: 1000,
  // One 100 kg bundle of steel plate and bar — `FactoryItems.steel`.
  Commodity.steel: 100,
  // One 10 kg tray of boards, chips and modules: dense value, light cargo.
  Commodity.electronics: 10,
  // A capacity, not a cargo: zero mass, never shipped.
  Commodity.compute: 0,
  // One 80 kg bundle of structural tubing — `FactoryItems.tubes`.
  Commodity.tubes: 80,
  // One 100 kg crate of engine and avionics parts (a valve, a pump
  // housing, a flight computer) — not a whole engine.
  Commodity.rocketParts: 100,
  // One rifle with its fittings, ~4 kg.
  Commodity.guns: 4,
  // One case of 1,000 rifle rounds, ~12 kg (5.56 mm, 12 g a round).
  Commodity.ammo: 12,
  // One packaged military ration, ~1 kg (an MRE weighs 0.5-0.7 kg; a
  // colony ration is a full day's food).
  Commodity.rations: 1,
  // One tactical missile, ~1 t.
  Commodity.missiles: 1000,
};

/// Commodities nothing ships between worlds: capacities and waste.
const Set<String> kUnshippableCommodities = {
  Commodity.compute,
  Commodity.garbage,
  Commodity.sewage,
};

/// The fallback for an id neither table knows (a later track's commodity
/// not yet given a mass): a 100 kg crate, the median cargo unit above. It
/// keeps an unknown good priced rather than free or crashing; add the real
/// entry when the good is introduced.
const double kUnknownKgPerUnit = 100;

/// Mass of one unit of [commodity], kg: the commodity table first, then a
/// factory item of that id (intermediates such as `pigIron`), else
/// [kUnknownKgPerUnit].
double kgPerUnit(String commodity) {
  final c = kCommodityKgPerUnit[commodity];
  if (c != null) return c;
  final item = FactoryItems.byId(commodity);
  if (item != null) return item.kgPerUnit / item.commodityUnits;
  return kUnknownKgPerUnit;
}

/// Whether [commodity] can be carried between worlds at all.
bool isShippable(String commodity) =>
    !kUnshippableCommodities.contains(commodity) && kgPerUnit(commodity) > 0;
