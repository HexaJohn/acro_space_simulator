// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Every plant template's own chain (items and recipes under its
/// `<plantType>:` prefix), registered in one place
/// (docs/plans/factory-floors.md §3 "Templates").
///
/// A template registers its chain when it builds a blueprint, but a floor
/// does not always start from a template: one loaded from a save
/// (`FactoryFloor.fromJson`) or rebuilt from blueprint JSON on the measure
/// worker (`FactoryFloor.fromBlueprint` in another isolate, whose statics
/// start empty) only ever calls `ensureFactoryCatalog`. So that call
/// registers every chain through here, and a template's machines always
/// find their recipes. Each track adds one line.
library;

import 'electronics_template.dart';
import 'gunfactory_template.dart';
import 'missilefactory_template.dart';
import 'rationsfactory_template.dart';
import 'refinery_template.dart';
import 'rocketfactory_template.dart';

/// Registers every template chain. Idempotent (each chain is).
void registerTemplateChains() {
  registerRefineryChain();
  registerElectronicsChain();
  registerRocketPartsChain();
  registerArmsChain();
  registerMissileChain();
  registerRationsChain();
}
