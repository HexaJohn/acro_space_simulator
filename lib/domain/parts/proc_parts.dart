// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../shared/vector3.dart';
import '../vessel/resource_container.dart';
import 'attach_node.dart';
import 'part_def.dart';
import 'proc_shape.dart';

/// The procedural construction family: sphere and pill fuel tanks, lattice
/// girders, and hull/armor plating. Every part here carries a [ProcShape] and
/// no `modelAsset` — the generated mesh is the art, on every platform.
///
/// Frame and units match the rest of the roster: METRES, part-local, Z-up,
/// nose on +Z, origin at the geometric centre [PartDef.size] is measured
/// about. Mating classes stay inside the pinned catalog set — stack seats are
/// the stock 1.25 m class, surface seats the stock 0.30 m class — so every
/// part here bolts to the whole existing roster and
/// `attach_node_data_test`'s class pin holds without a new entry.
///
/// ## Tank arithmetic
///
/// Capacity and dry mass are DERIVED, not invented: the FL-T400 sets the
/// standard the stock roster flies with (400 units and 250 kg dry in a
/// 2.33 m^3 cylinder — about 171.6 units and 107 kg per cubic metre), and each
/// tank below is its own true volume through those densities, split 45/55
/// between liquid fuel and oxidizer exactly as the FL-T400 splits. A sphere
/// therefore holds more than it looks like it should and a pill less — which
/// is the actual trade those shapes buy in a real vehicle.
class ProcParts {
  ProcParts._();

  /// Roster order: tanks by size, then girders, then plates — the order the
  /// catalog pane shows within a category.
  static List<PartDef> get all => [
        _sphereTank(
          id: 'sphere-tank-s',
          name: 'SPH-125 Sphere Tank',
          diameter: 1.25,
          dryMass: 110,
          liquidFuel: 79,
          oxidizer: 97,
        ),
        _sphereTank(
          id: 'sphere-tank-m',
          name: 'SPH-250 Sphere Tank',
          diameter: 2.5,
          dryMass: 875,
          liquidFuel: 632,
          oxidizer: 772,
        ),
        _sphereTank(
          id: 'sphere-tank-l',
          name: 'SPH-500 Sphere Tank',
          diameter: 5.0,
          dryMass: 7000,
          liquidFuel: 5054,
          oxidizer: 6176,
        ),
        _pillTank(
          id: 'pill-tank-s',
          name: 'PLL-250 Pill Tank',
          diameter: 1.25,
          length: 2.5,
          dryMass: 275,
          liquidFuel: 198,
          oxidizer: 241,
        ),
        _pillTank(
          id: 'pill-tank-m',
          name: 'PLL-375 Pill Tank',
          diameter: 1.25,
          length: 3.75,
          dryMass: 440,
          liquidFuel: 316,
          oxidizer: 386,
        ),
        _pillTank(
          id: 'pill-tank-l',
          name: 'PLL-500 Heavy Pill Tank',
          diameter: 2.5,
          length: 5.0,
          dryMass: 2200,
          liquidFuel: 1580,
          oxidizer: 1930,
        ),
        _truss(
          id: 'truss-s',
          name: 'GDR-1 Girder Segment',
          width: 0.625,
          length: 1.25,
          dryMass: 60,
        ),
        _truss(
          id: 'truss-m',
          name: 'GDR-2 Girder Segment',
          width: 0.625,
          length: 2.5,
          dryMass: 120,
        ),
        _truss(
          id: 'truss-l',
          name: 'GDR-4 Girder Segment',
          width: 0.625,
          length: 5.0,
          dryMass: 240,
        ),
        _truss(
          id: 'truss-heavy',
          name: 'GDR-H Heavy Spine Truss',
          width: 2.5,
          length: 5.0,
          dryMass: 1500,
          extraRings: true,
        ),
        _plate(
          id: 'plate-1m',
          name: 'PLT-1 Hull Plate',
          width: 1.0,
          height: 1.0,
          thickness: 0.05,
          dryMass: 15,
          crossSection: 0.3,
        ),
        _plate(
          id: 'plate-2m',
          name: 'PLT-2 Hull Plate',
          width: 2.0,
          height: 2.0,
          thickness: 0.05,
          dryMass: 60,
          crossSection: 1.0,
        ),
        _plate(
          id: 'armor-plate-2m',
          name: 'ARM-2 Armor Plate',
          width: 2.0,
          height: 2.0,
          thickness: 0.25,
          dryMass: 800,
          crossSection: 1.0,
          armor: true,
        ),
      ];

  /// The family's ids, for an editor filter — mirrors `LemParts.ids`.
  static final Set<String> ids = all.map((p) => p.id).toSet();

  /// Stock structural stack class; must match `PartCatalog._stockStackClass`,
  /// which `proc_parts_catalog_test` pins.
  static const double _stackClass = 1.25;

  /// Stock radial class; must match `PartCatalog._stockSurfaceClass`.
  static const double _surfaceClass = 0.30;

  /// FL-T400 propellant split: 180 LF to 220 OX.
  static const double _lfShare = 180 / 400;

  static PartDef _sphereTank({
    required String id,
    required String name,
    required double diameter,
    required double dryMass,
    required double liquidFuel,
    required double oxidizer,
  }) {
    final r = diameter / 2;
    return PartDef(
      id: id,
      name: name,
      category: PartCategory.fuelTank,
      dryMass: dryMass,
      size: Vector3(diameter, diameter, diameter),
      crossSectionArea: math.pi * r * r,
      procShape: ProcSphere(diameterM: diameter),
      resources: _propellant(liquidFuel, oxidizer),
      attachNodes: [
        // Poles carry the stack; the equator ring carries radial hardware —
        // and, through a plate's `back` node, the skin that turns a tank farm
        // into a hull.
        AttachNode(
          name: 'top',
          position: Vector3(0, 0, r),
          direction: Vector3.unitZ,
          size: _stackClass,
        ),
        AttachNode(
          name: 'bottom',
          position: Vector3(0, 0, -r),
          direction: const Vector3(0, 0, -1),
          size: _stackClass,
        ),
        ..._ring(prefix: 'srf', radius: r, height: 0, size: _surfaceClass),
      ],
    );
  }

  static PartDef _pillTank({
    required String id,
    required String name,
    required double diameter,
    required double length,
    required double dryMass,
    required double liquidFuel,
    required double oxidizer,
  }) {
    final r = diameter / 2;
    return PartDef(
      id: id,
      name: name,
      category: PartCategory.fuelTank,
      dryMass: dryMass,
      size: Vector3(diameter, diameter, length),
      crossSectionArea: math.pi * r * r,
      procShape: ProcPill(diameterM: diameter, lengthM: length),
      resources: _propellant(liquidFuel, oxidizer),
      attachNodes: [
        AttachNode(
          name: 'top',
          position: Vector3(0, 0, length / 2),
          direction: Vector3.unitZ,
          size: _stackClass,
        ),
        AttachNode(
          name: 'bottom',
          position: Vector3(0, 0, -length / 2),
          direction: const Vector3(0, 0, -1),
          size: _stackClass,
        ),
        // Mid-height, on the cylinder section, so a mounted part never rides
        // up onto the cap curvature.
        ..._ring(prefix: 'srf', radius: r, height: 0, size: _surfaceClass),
      ],
    );
  }

  static PartDef _truss({
    required String id,
    required String name,
    required double width,
    required double length,
    required double dryMass,
    bool extraRings = false,
  }) =>
      PartDef(
        id: id,
        name: name,
        category: PartCategory.structural,
        dryMass: dryMass,
        size: Vector3(width, width, length),
        // A lattice is mostly holes, but what it presents is dirty flow.
        dragCoefficient: 0.5,
        crossSectionArea: width * width * 0.4,
        procShape: ProcTruss(widthM: width, lengthM: length),
        attachNodes: [
          AttachNode(
            name: 'top',
            position: Vector3(0, 0, length / 2),
            direction: Vector3.unitZ,
            size: _stackClass,
          ),
          AttachNode(
            name: 'bottom',
            position: Vector3(0, 0, -length / 2),
            direction: const Vector3(0, 0, -1),
            size: _stackClass,
          ),
          // The girder is the part everything else bolts TO: plates for skin,
          // tanks for drop stages, engines on pylons. The heavy spine gets
          // fore and aft rings as well, so a frigate's hull sections do not
          // all crowd its midpoint.
          ..._ring(
              prefix: 'srf', radius: width / 2, height: 0, size: _surfaceClass),
          if (extraRings) ...[
            ..._ring(
              prefix: 'srf-f',
              radius: width / 2,
              height: length / 4,
              size: _surfaceClass,
            ),
            ..._ring(
              prefix: 'srf-a',
              radius: width / 2,
              height: -length / 4,
              size: _surfaceClass,
            ),
          ],
        ],
      );

  static PartDef _plate({
    required String id,
    required String name,
    required double width,
    required double height,
    required double thickness,
    required double dryMass,
    required double crossSection,
    bool armor = false,
  }) =>
      PartDef(
        id: id,
        name: name,
        category: PartCategory.structural,
        dryMass: dryMass,
        size: Vector3(width, height, thickness),
        dragCoefficient: 0.15,
        crossSectionArea: crossSection,
        maxTemperature: armor ? 2800 : 2000,
        procShape: ProcPlate(
          widthM: width,
          heightM: height,
          thicknessM: thickness,
          armor: armor,
        ),
        attachNodes: [
          // `back` seats the plate flat against any surface node (a tank ring,
          // a girder flank); `face` is the same seat on the outside, so armor
          // layers over skin and greebles bolt onto armor.
          AttachNode(
            name: 'back',
            position: Vector3(0, 0, -thickness / 2),
            direction: const Vector3(0, 0, -1),
            size: _surfaceClass,
            kind: AttachKind.surface,
          ),
          AttachNode(
            name: 'face',
            position: Vector3(0, 0, thickness / 2),
            direction: Vector3.unitZ,
            size: _surfaceClass,
            kind: AttachKind.surface,
          ),
        ],
      );

  static List<ResourceContainer> _propellant(double lf, double ox) {
    // Guard the derived numbers against a hand-edit drifting the split: the
    // roster promises FL-T400 proportions, so a tank that is not within a unit
    // of them is a typo, not a design choice.
    assert(
      ((lf / (lf + ox)) - _lfShare).abs() < 0.005,
      'tank split drifted from the FL-T400 45/55',
    );
    return [
      ResourceContainer(
        type: ResourceType.liquidFuel,
        capacity: lf,
        amount: lf,
        unitMass: 5,
      ),
      ResourceContainer(
        type: ResourceType.oxidizer,
        capacity: ox,
        amount: ox,
        unitMass: 5,
      ),
    ];
  }

  static List<AttachNode> _ring({
    required String prefix,
    required double radius,
    required double height,
    required double size,
  }) =>
      [
        for (var i = 0; i < 4; i++)
          _radial(
            name: '$prefix-${i + 1}',
            azimuth: i * math.pi / 2,
            radius: radius,
            height: height,
            size: size,
          ),
      ];

  /// One surface node at [azimuth] radians from +X toward +Y, [radius] metres
  /// out and [height] metres along part-local Z, facing outward.
  static AttachNode _radial({
    required String name,
    required double azimuth,
    required double radius,
    required double height,
    required double size,
  }) {
    final c = math.cos(azimuth), s = math.sin(azimuth);
    return AttachNode(
      name: name,
      position: Vector3(radius * c, radius * s, height),
      direction: Vector3(c, s, 0),
      size: size,
      kind: AttachKind.surface,
    );
  }
}
