// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How a building is SHAPED, before any triangles exist.
///
/// Massing is derived from what the building has to do — how many people it
/// houses or employs, how much plant it contains — and from how much land it
/// was given. That is the whole point of generating buildings rather than
/// placing models: a hospital on a narrow street lot becomes a tower, the same
/// hospital on an open plot becomes a low block with wings, and neither needs
/// an artist. Keeping the sizing separate from the mesh also means it can be
/// tested as arithmetic, and the renderer can bucket similar massings into one
/// shared mesh for instancing.
library;

import 'dart:math' as math;

import '../colony/city/city_building_spec.dart';
import '../colony/city/parcel.dart';
import 'architecture_style.dart';

/// A rectangular volume in building-local metres, Z-up, origin at the centre of
/// the building's footprint on the ground.
/// How a volume is built.
///
/// The plain box is the building. The rest are what an installation is made
/// of and a box is not: a refinery is tanks and columns, a power station is
/// cooling towers and a stack, a mill is sheds under pitched roofs, a wind
/// farm is towers with rotors on top. Each is still a MassBox — one footprint,
/// one height — so the plat, the parking rule and the LOD tiers need not know
/// there is anything but boxes.
enum MassShape {
  box,

  /// An octagonal prism on the volume's footprint: a tank, a silo, a column.
  cylinder,

  /// A prism whose top is [MassBox.topScale] of its base: a cooling tower, a
  /// stack, a mast, a stockpile, a conifer.
  frustum,

  /// A box under a pitched roof, ridge along the longer side: a shed, a
  /// hangar, a barn, a greenhouse.
  gable,

  /// A three-blade rotor in the vertical plane, hub at the volume's centre,
  /// blades [MassBox.height] long and [MassBox.width] wide at the root: the
  /// top of a wind turbine.
  rotor,

  /// A heliostat: a mirror plate on a pedestal, turned by [MassBox.yaw] to
  /// face its tower and tipped so its normal sits [MassBox.tilt] above the
  /// horizon. [MassBox.width] is the plate across, [MassBox.height] the
  /// whole thing tall, [MassBox.depth] the pedestal's thickness.
  mirror,

  /// A photovoltaic table: the same plate on two posts, faced and tilted
  /// the same way, drawn on the atlas's photovoltaic band.
  panel,

  /// A natural-draught cooling tower's shell: a hyperboloid on the
  /// footprint, waisted at three-quarters height and flaring to
  /// [MassBox.topScale] of the base, open at the top and drawn inside as
  /// well. Stands from [MassBox.z]; the legs under it are their own volumes.
  hyperboloid,

  /// A dome on the footprint, [MassBox.height] tall: a containment's cap.
  dome,

  /// A vehicle, [MassBox.width] long along [MassBox.yaw], [MassBox.depth]
  /// wide, [MassBox.height] tall: a cab and a body on wheels. Taller than
  /// a car and it is a truck, cab forward and a bed behind.
  vehicle,
}

class MassBox {
  /// Centre of the box in plan; z is the box's BASE height above ground.
  final double x, y, z;
  final double width, depth, height;

  /// Floors this volume contains (0 for plant, canopies, plinths).
  final int floors;

  /// Whether this volume gets glazing. Plant rooms and plinths do not.
  final bool glazed;

  const MassBox({
    required this.x,
    required this.y,
    required this.z,
    required this.width,
    required this.depth,
    required this.height,
    this.floors = 0,
    this.glazed = true,
    this.shape = MassShape.box,
    this.topScale = 1.0,
    this.yaw = 0,
    this.tilt = 0,
    this.material,
  });

  /// The facade-atlas band this volume is drawn on, or null for the
  /// massing's own. What lets a works be concrete, white sheet and bare
  /// steel at once instead of one cladding throughout.
  final int? material;

  /// See [MassShape].
  final MassShape shape;

  /// For a [MassShape.frustum]: the top's size as a fraction of the base.
  final double topScale;

  /// For a [MassShape.mirror]: the bearing the plate faces, radians from +x
  /// toward +y, and how far above the horizon its normal points.
  final double yaw, tilt;

  double get top => z + height;
  double get floorArea => width * depth * math.max(1, floors);
}

/// A surface car park attached to a building.
class ParkingLot {
  /// Centre in building-local plan metres.
  final double x, y;
  final double width, depth;
  final int spaces;

  /// Light column positions in building-local metres, on the lot.
  final List<(double x, double y)> lampPosts;

  const ParkingLot({
    required this.x,
    required this.y,
    required this.width,
    required this.depth,
    required this.spaces,
    this.lampPosts = const [],
  });

  double get area => width * depth;
}

/// The complete shape brief for one building.
class BuildingMassing {
  final List<MassBox> volumes;
  final ParkingLot? parking;

  /// Storey height used throughout, metres.
  final double storeyM;

  /// Total enclosed floor area, m².
  final double floorArea;

  /// Where the entrance sits, in local plan metres — on the frontage side.
  final (double x, double y) entrance;

  /// Height of the GROUND storey, which is usually not the height of the
  /// others: retail wants 4.5 m where the offices above it want 3.5. Carried
  /// beside [storeyM] rather than replacing it because everything above the
  /// ground floor really is a uniform stack, and one extra number is cheaper
  /// than a per-floor table nothing else would read.
  final double groundStoreyM;

  /// The idiom this was massed in. The geometry pass reads the same one, so a
  /// building cannot end up sited as a street wall and detailed as an office
  /// park.
  final ArchitectureStyle style;

  /// This building holds a corner: its lot touches a second street.
  final bool corner;

  /// Which band of the facade atlas this building's walls are cut from.
  ///
  /// Decided HERE, with the rest of the brief, so it is one number that
  /// travels with the massing rather than something the geometry pass rolls
  /// for itself — which would make the same building a different colour every
  /// time it was regenerated.
  final int material;

  const BuildingMassing({
    required this.volumes,
    required this.storeyM,
    required this.floorArea,
    required this.entrance,
    this.parking,
    double? groundStoreyM,
    this.style = ArchitectureStyle.utilitarian,
    this.material = FacadeMaterial.precast,
    this.corner = false,
  }) : groundStoreyM = groundStoreyM ?? storeyM;

  /// Base height of floor [index] within a volume standing on the ground.
  double floorBase(int index) =>
      index <= 0 ? 0 : groundStoreyM + (index - 1) * storeyM;

  /// Height of the bottom [floors] storeys of a ground-standing volume.
  double stackHeight(int floors) =>
      floors <= 0 ? 0 : groundStoreyM + (floors - 1) * storeyM;

  double get height =>
      volumes.fold(0.0, (h, v) => math.max(h, v.top));

  int get floors =>
      volumes.fold(0, (f, v) => math.max(f, ((v.top) / storeyM).floor()));

  ({double width, double depth}) get footprint {
    var w = 0.0, d = 0.0;
    for (final v in volumes) {
      w = math.max(w, v.x.abs() * 2 + v.width);
      d = math.max(d, v.y.abs() * 2 + v.depth);
    }
    return (width: w, depth: d);
  }
}

/// Derives massing from function and available land.
class BuildingMassingRules {
  const BuildingMassingRules({
    this.style = ArchitectureStyle.utilitarian,
    this.storeyM = 3.6,
    this.industrialStoreyM = 7.5,
    this.areaPerResident = 42,
    this.areaPerWorker = 22,
    this.setbackM = 3,
    this.maxFloors = 60,
    this.parkingSpaceM2 = 26,
  });

  /// The urban idiom: where the building stands on its lot, how tall its
  /// ground floor is, when it steps back. See [ArchitectureStyle] — the
  /// siting numbers in there do more for how a street looks than anything in
  /// this class.
  final ArchitectureStyle style;

  BuildingMassingRules withStyle(ArchitectureStyle s) => BuildingMassingRules(
        style: s,
        storeyM: storeyM,
        industrialStoreyM: industrialStoreyM,
        areaPerResident: areaPerResident,
        areaPerWorker: areaPerWorker,
        setbackM: setbackM,
        maxFloors: maxFloors,
        parkingSpaceM2: parkingSpaceM2,
      );

  /// Habitable storey height. Industrial sheds get a taller one — a factory
  /// floor with a 3.6 m ceiling reads as an office block with the wrong texture.
  final double storeyM;
  final double industrialStoreyM;

  final double areaPerResident;
  final double areaPerWorker;

  /// Gap between the property line and the building face.
  final double setbackM;

  final int maxFloors;

  /// Bay plus its share of aisle and circulation.
  final double parkingSpaceM2;

  /// Floor area this building's function demands, m².
  double requiredArea(CityBuildingSpec spec) {
    var a = spec.housing * areaPerResident + spec.jobs * areaPerWorker;
    // Plant with no staff still needs a building around it. Size those from
    // their power rating, which is the only scale signal such a spec carries.
    if (a < 40) {
      a = 60 + spec.powerOutput * 0.9 + spec.powerDraw * 0.4;
    }
    // Storage is all volume, no occupancy.
    a += spec.storageBonus * 0.35;
    return math.max(a, 45);
  }

  bool _isIndustrial(CityBuildingSpec spec) => const {
        'ind',
        'res-x',
        'power',
        'waste',
        'storage',
        'aero',
      }.contains(spec.group);

  /// Cars this building attracts. Workers dominate; shops and civic buildings
  /// add visitor demand, which is what makes a mall's lot dwarf its shell.
  int parkingSpaces(CityBuildingSpec spec) {
    // A megatower parks inside its own podium: eighteen thousand workers on
    // a surface lot would need more block than the building has.
    if (spec.type == 'mega') return 0;
    final staff = spec.jobs * 0.55;
    final visitors = (spec.services['leisure'] ?? 0) * 0.04 +
        (spec.services['health'] ?? 0) * 0.03 +
        (spec.services['education'] ?? 0) * 0.02;
    final residents = spec.housing * 0.35;
    return (staff + visitors + residents).round();
  }

  /// Shape [spec] to fit [parcel].
  BuildingMassing massFor(CityBuildingSpec spec, Parcel parcel, {int seed = 0}) =>
      _clipToParcel(_massIn(spec, parcel, seed: seed), parcel);

  /// Drop every volume that would stand over the lot line.
  ///
  /// The massings work in a rectangle — a street building in the rectangle
  /// inscribed in its lot, an installation in its plot's bounding box — and
  /// a lot is not always a rectangle: a tapered quad off a bending street,
  /// an L a neighbour's assemblage left, a corner splayed at a junction.
  /// A field of tables or a ring of heliostats fills the box and is cut to
  /// the polygon here; a street building already fits, and loses nothing.
  BuildingMassing _clipToParcel(BuildingMassing m, Parcel parcel) {
    if (parcel.polygon.length < 3) return m;
    final f = parcel.frontage;
    final along = f == null ? const Vec2(1, 0) : (f.$2 - f.$1).normalized;
    final away = along.perp;
    final c = parcel.centroid;
    Vec2 at(double x, double y) => Vec2(
        c.e + along.e * x + away.e * y, c.n + along.n * x + away.n * y);
    const tol = 0.4;
    bool inside(MassBox v) {
      final corners = <(double, double)>[];
      if (v.shape == MassShape.mirror || v.shape == MassShape.panel) {
        // A plate: its two ends along the way it is turned.
        final ax = -math.sin(v.yaw), ay = math.cos(v.yaw);
        final hw = math.max(0.0, v.width / 2 - tol);
        corners.add((v.x + ax * hw, v.y + ay * hw));
        corners.add((v.x - ax * hw, v.y - ay * hw));
      } else {
        final hw = math.max(0.0, v.width / 2 - tol);
        final hd = math.max(0.0, v.depth / 2 - tol);
        corners.add((v.x - hw, v.y - hd));
        corners.add((v.x + hw, v.y - hd));
        corners.add((v.x + hw, v.y + hd));
        corners.add((v.x - hw, v.y + hd));
      }
      for (final (x, y) in corners) {
        if (!parcel.contains(at(x, y))) return false;
      }
      return true;
    }

    final kept = m.volumes.where(inside).toList();
    if (kept.length == m.volumes.length) return m;
    return BuildingMassing(
      volumes: kept,
      storeyM: m.storeyM,
      floorArea: m.floorArea,
      entrance: m.entrance,
      parking: m.parking,
      groundStoreyM: m.groundStoreyM,
      style: m.style,
      material: m.material,
      corner: m.corner,
    );
  }

  BuildingMassing _massIn(CityBuildingSpec spec, Parcel parcel, {int seed = 0}) {
    // A street building is one thing and must fit: the rectangle inscribed
    // in its lot. An installation is many things over its plot's bounding
    // box, and [_clipToParcel] cuts the ones over the line.
    final extent =
        spec.claimsOwnSite ? parcel.buildableExtent : parcel.inscribedExtent;
    final corner = parcel.isCorner;
    final rnd = math.Random(seed ^ spec.label.hashCode);
    final industrial = _isIndustrial(spec);
    final storey = industrial ? industrialStoreyM : style.upperStoreyM;
    final ground = industrial ? industrialStoreyM : style.groundStoreyM;

    // Land available once the setbacks are taken off, in the parcel's own
    // frontage-aligned axes: width runs ALONG the street, depth away from it,
    // and local y = -depth/2 IS the curb line.
    //
    // The setbacks come from the style, and they are asymmetric on purpose: a
    // street-wall building stands hard on the front line and keeps its yard at
    // the back, where the alley and the parking go. Taking the same margin off
    // both ends is what centred every building in its lot and left a downtown
    // block looking like a business park.
    //
    // Zero side setback does NOT mean building over the property line: the
    // parcel handed in here has already been inset by the density rule in the
    // world snapshot. Zero means "fill what I was given", which is what makes
    // neighbours meet.
    //
    // Capped to the spec's real site size — a solar farm dropped on a
    // ten-kilometre manual lot is still a solar farm, not a ten-kilometre one.
    // The cap applies ONLY to specs that declare a site: ordinary street
    // buildings have no fixed extent and must keep taking their shape from the
    // parcel, or every lot in the city would produce the same building.
    final site = spec.siteMetres();
    final capped = spec.siteWidthM > 0 && !_tilesItsPlot.contains(spec.type);
    final capW = capped ? site.width : double.infinity;
    final capD = capped ? site.depth : double.infinity;
    final frontEdge = -extent.depth / 2 + style.frontSetbackM;
    final rearEdge = extent.depth / 2 - style.rearSetbackM;
    final availW =
        math.min(math.max(6.0, extent.width - style.sideSetbackM * 2), capW);
    final availD = math.min(math.max(6.0, rearEdge - frontEdge), capD);

    // The railway's two ends have massings of their own: a station is a hall
    // on a platform, a yard is hardstanding under a crane. Neither is the
    // shed the industrial path would make of them.
    if (spec.type == 'station') return _station(spec, availW, availD, storey);
    if (spec.type == 'freightyard') {
      return _freightYard(spec, availW, availD, storey);
    }
    // A solar thermal plant sizes its towers to the plot it is given, not
    // to a nominal site: a bigger plot is more fields, not a bigger one.
    if (spec.type == 'solarthermal') {
      return _solarThermal(spec, availW, availD, storey);
    }
    // And the installations: each built of the things its real counterpart
    // is built of, so a refinery reads as a refinery from a kilometre up and
    // not as the same grey slab as the data centre next to it.
    final own = _installation(spec, availW, availD, storey);
    if (own != null) return own;
    switch (spec.siteKind) {
      case SiteKind.field:
        return spec.type.startsWith('farm')
            ? _farm(spec, availW, availD, storey)
            : _field(spec, availW, availD);
      case SiteKind.pit:
        return _pit(spec, availW, availD, storey);
      case SiteKind.pad:
        return _apron(spec, availW, availD, storey);
      case SiteKind.building:
        break;
    }

    final needed = requiredArea(spec);
    final spaces = parkingSpaces(spec);
    final parkArea = spaces * parkingSpaceM2;

    // Parking takes a strip off one END of the buildable depth whenever there
    // is room for it; a building that would then have nowhere to stand keeps
    // its plot and loses the lot instead.
    //
    // WHICH end is a style decision and it is not cosmetic. A lot out front
    // pushes the building back off the street and opens a gap in the block —
    // it is the single change that turns a downtown into a strip. Behind the
    // building, off the alley, the same cars are invisible from the pavement.
    var parkDepth = 0.0;
    if (parkArea > 0) {
      parkDepth = (parkArea / availW).clamp(0.0, availD * 0.55);
    }
    final buildD = math.max(6.0, availD - parkDepth);
    final buildW = availW;

    // Footprint: industrial fills its plot, everything else keeps a slimmer
    // block so a dense street does not become one continuous wall.
    // Coverage stays a property of the MASSING, not of density.
    //
    // How much of its plot a building takes by density is decided once, where
    // the lot is measured (`lotCoverageFor` / `lotSetbackFor` in the world
    // snapshot), and the parcel handed to this generator is already inset by
    // it. Applying a density rule here too multiplied the two together and
    // pushed geometry outside its own lot — caught by the architecture tests,
    // which is exactly what they are for.
    // A street wall fills its frontage edge to edge — that IS the street wall.
    // Everything else keeps a slimmer block.
    final coverW = style.sideSetbackM <= 0.01
        ? 1.0
        : (industrial ? 0.92 : 0.7 + rnd.nextDouble() * 0.12);
    final coverD = style.isStreetWall
        ? 0.88 + rnd.nextDouble() * 0.12
        : (industrial ? 0.92 : 0.7 + rnd.nextDouble() * 0.12);
    final footW = buildW * coverW;
    final footD = buildD * coverD;
    final footArea = footW * footD;

    // Floors are bounded by DENSITY, not just by the global cap. Deriving them
    // from required area over footprint alone made a low-density home sixteen
    // storeys tall on a small plot — arithmetically reasonable, and nothing
    // like the detached house the zoning asked for. Intensity is the density
    // signal a spec carries; the ceilings are what each tier looks like.
    final intensity = spec.housing + spec.jobs;
    final tierCap = intensity >= 90
        ? maxFloors
        : (intensity >= 30 ? 8 : 3);

    // What the TENANT needs, which is a minimum and not a design.
    final byDemand =
        (needed / footArea).ceil().clamp(1, math.min(maxFloors, tierCap)).toInt();

    // What the LAND wants. See [ArchitectureStyle.zoneFloors]: a downtown lot
    // is built tall because of where it is, not because of who leases it, and
    // the demand figure alone put a two-storey box on every plot in the middle
    // of the city. The zone target overrides the intensity ceiling as well —
    // that ceiling exists to stop a small tenant becoming a tower by accident,
    // which is the opposite of a deliberate one.
    final byZone = industrial ? 0 : style.targetFloors(spec, seed ^ spec.type.hashCode);
    var floors = industrial
        ? 1
        : math.max(byDemand, byZone).clamp(1, maxFloors).toInt();

    // A corner earns a storey. In every one of the reference streets the tall
    // element of a block is on its corner — it is the part you can see from
    // two directions, so it is the part worth building up — and a block whose
    // corners are the same height as its middle reads as a single extruded
    // shape rather than as a row of buildings.
    if (!industrial && corner && floors < maxFloors) floors += 1;

    // CORNICE DATUM. Real neighbours line their cornices up, because they were
    // built to the same storey heights against the same street. Left free,
    // floor counts come out of a division and every building lands a metre or
    // two off its neighbour, which gives a row of buildings a ragged top edge
    // that nothing in the photographs has.
    //
    // Quantising the COUNT rather than the height is what makes them actually
    // coincide: two buildings with the same storey height and the same number
    // of floors have their cornice at the same height by construction, and
    // the arithmetic cannot drift.
    if (!industrial && style.corniceDatumFloors > 1 && floors > 2) {
      final q = style.corniceDatumFloors;
      // Lower bound guarded against a kit configured with fewer maximum
      // floors than its own cornice datum — `clamp` throws outright when its
      // limits cross, which is a crash rather than a bad-looking building.
      final snapped =
          ((floors / q).round() * q).clamp(math.min(q, maxFloors), maxFloors);
      floors = snapped.toInt();
    }
    // A shed that cannot hold its function on one floor grows a mezzanine
    // rather than a tower.
    if (industrial && needed > footArea * 1.4) floors = 2;

    // MEGATOWER: the one building allowed past the ordinary ceiling. Both
    // regular caps exist to stop ACCIDENTAL towers — [maxFloors] (60) is the
    // hard lid, and the kit's zone targets are why every downtown tower tops
    // out around the same height — but a megatower is nothing but deliberate,
    // so its height is its own seeded rule: 90 to 150 storeys over a full
    // block. The profile mix below shapes it like anything else tall.
    if (spec.type == 'mega') {
      final h = (seed ^ 0x35C0DE) * 2654435761 & 0x7FFFFFFF;
      floors = 90 + h % 61;
    }

    final volumes = <MassBox>[];
    // Where the building sits within its buildable strip, and where the cars
    // go. Front-parking pushes the building back; rear-parking pulls it
    // forward onto the street line.
    final buildCentreY = style.parkingBehind
        ? frontEdge + buildD / 2
        : frontEdge + parkDepth + buildD / 2;
    final parkCentreY = style.parkingBehind
        ? frontEdge + buildD + parkDepth / 2
        : frontEdge + parkDepth / 2;
    // Total height of a stack of [n] floors, with the ground storey taller.
    double stack(int n) => n <= 0 ? 0 : ground + (n - 1) * storey;

    if (floors <= style.stepbackAboveFloors) {
      volumes.add(MassBox(
        x: 0,
        y: buildCentreY,
        z: 0,
        width: footW,
        depth: footD,
        height: stack(floors),
        floors: floors,
      ));
    } else {
      // Three tall profiles, drawn per building. One profile for every tower
      // — the podium-and-setback — made a downtown read as a tray of the
      // same wedding cake at different heights, and the 0.52-0.68 tower
      // fraction on a street-lot footprint made every one of them a pencil.
      // Real skylines mix straight-extruded slabs, podium towers, and the
      // stepped ziggurats the 1916 zoning envelope produced — and their
      // upper shafts hold more of their base than the old fraction allowed.
      final profile = rnd.nextDouble();
      final podiumFloors = math.min(style.podiumFloors, floors - 1);
      final towerFloors = floors - podiumFloors;

      if (profile < 0.34) {
        // Straight extrusion: the whole footprint straight to the parapet.
        // The profile of most real mid-rise and plenty of towers.
        volumes.add(MassBox(
          x: 0,
          y: buildCentreY,
          z: 0,
          width: footW,
          depth: footD,
          height: stack(floors),
          floors: floors,
        ));
        volumes.add(MassBox(
          x: 0,
          y: buildCentreY,
          z: stack(floors),
          width: footW * 0.4,
          depth: footD * 0.4,
          height: 3.2,
          glazed: false,
        ));
      } else if (profile < 0.72) {
        // Podium and tower: the base holds the street, the shaft steps back.
        final towerW = footW * (0.62 + rnd.nextDouble() * 0.22);
        final towerD = footD * (0.62 + rnd.nextDouble() * 0.22);
        volumes.add(MassBox(
          x: 0,
          y: buildCentreY,
          z: 0,
          width: footW,
          depth: footD,
          height: stack(podiumFloors),
          floors: podiumFloors,
        ));
        volumes.add(MassBox(
          // Offset the tower toward the back of the podium, so the street
          // gets a set-back frontage rather than a slab off the pavement.
          x: (rnd.nextDouble() - 0.5) * (footW - towerW) * 0.4,
          y: buildCentreY + (footD - towerD) * 0.18,
          z: stack(podiumFloors),
          width: towerW,
          depth: towerD,
          height: towerFloors * storey,
          floors: towerFloors,
        ));
        volumes.add(MassBox(
          x: 0,
          y: buildCentreY + (footD - towerD) * 0.18,
          z: stack(floors),
          width: towerW * 0.45,
          depth: towerD * 0.45,
          height: 3.2,
          glazed: false,
        ));
      } else {
        // Ziggurat: two setbacks on the way up, each tier holding most of
        // the one below. The wedding-cake profile the zoning envelope built.
        final t1Floors = math.max(1, ((floors - podiumFloors) * 0.55).round());
        final t2Floors = math.max(1, floors - podiumFloors - t1Floors);
        final w1 = footW * (0.78 + rnd.nextDouble() * 0.1);
        final d1 = footD * (0.78 + rnd.nextDouble() * 0.1);
        final w2 = w1 * (0.68 + rnd.nextDouble() * 0.12);
        final d2 = d1 * (0.68 + rnd.nextDouble() * 0.12);
        final back1 = buildCentreY + (footD - d1) * 0.25;
        volumes.add(MassBox(
          x: 0,
          y: buildCentreY,
          z: 0,
          width: footW,
          depth: footD,
          height: stack(podiumFloors),
          floors: podiumFloors,
        ));
        volumes.add(MassBox(
          x: 0,
          y: back1,
          z: stack(podiumFloors),
          width: w1,
          depth: d1,
          height: t1Floors * storey,
          floors: t1Floors,
        ));
        volumes.add(MassBox(
          x: 0,
          y: back1 + (d1 - d2) * 0.25,
          z: stack(podiumFloors) + t1Floors * storey,
          width: w2,
          depth: d2,
          height: t2Floors * storey,
          floors: t2Floors,
        ));
        volumes.add(MassBox(
          x: 0,
          y: back1 + (d1 - d2) * 0.25,
          z: stack(podiumFloors) + (t1Floors + t2Floors) * storey,
          width: w2 * 0.45,
          depth: d2 * 0.45,
          height: 3.0,
          glazed: false,
        ));
      }
    }

    // Industrial sites get their plant on the roof too, plus a loading canopy.
    if (industrial && spec.powerOutput > 0) {
      final v = volumes.first;
      volumes.add(MassBox(
        x: v.x,
        y: v.y,
        z: v.top,
        width: v.width * 0.35,
        depth: v.depth * 0.35,
        height: 4 + spec.powerOutput * 0.01,
        glazed: false,
      ));
    }

    final area = volumes.fold(0.0, (s, v) => s + (v.floors > 0 ? v.floorArea : 0));

    return BuildingMassing(
      volumes: volumes,
      storeyM: storey,
      groundStoreyM: ground,
      style: style,
      // Industry gets precast or profiled metal whatever the kit says. A
      // fabrication shed faced in cream terracotta is not a stylistic choice,
      // it is a bug you can see from orbit.
      corner: corner,
      material: industrial
          ? (rnd.nextBool()
              ? FacadeMaterial.precast
              : FacadeMaterial.metalPanel)
          : style.materialFor(seed ^ spec.type.hashCode),
      floorArea: area,
      entrance: (0, buildCentreY - footD / 2),
      parking: parkDepth <= 0.5
          ? null
          : ParkingLot(
              x: 0,
              y: parkCentreY,
              width: availW,
              depth: parkDepth,
              spaces: spaces,
              lampPosts: _lampGrid(availW, parkDepth,
                  y0: parkCentreY - parkDepth / 2),
            ),
    );
  }

  /// A photovoltaic farm: tilted tables of modules in rows at the pitch
  /// inter-row shading sets, in blocks cut by gravel lanes, an inverter and
  /// its transformer on a pad in each block's lane, a fence round the lot,
  /// and along the access side the yard — control room, substation, and
  /// the battery containers a farm of any size has now. The far corners
  /// are bitten off, because a real field follows its land, not its fence.
  ///
  /// Rows rather than one slab because that is what makes the scale legible
  /// from the air — a kilometre of undifferentiated grey reads as a car park,
  /// while a kilometre of repeating rows reads as a solar farm.
  BuildingMassing _field(CityBuildingSpec spec, double w, double d) {
    const rowPitch = 8.0; // row spacing, set by inter-row shading
    const tableH = 4.6; // the table's reach up its slope, posts included
    const tilt = 1.13; // the normal 65 degrees up: a 25 degree panel
    final big = spec.type == 'solar-big';
    final k = math.min(1.0, math.min(w, d) / 780);
    final yardD = math.min(d * 0.3, big ? 150.0 : 70.0);
    final margin = math.min(12.0, w * 0.05);
    final x0 = -w / 2 + margin, x1 = w / 2 - margin;
    final y0 = -d / 2 + yardD, y1 = d / 2 - margin;
    final volumes = <MassBox>[];

    if (x1 - x0 > 20 && y1 - y0 > 12) {
      final nx = math.max(1, ((x1 - x0) / 240).round());
      final ny = math.max(1, ((y1 - y0) / 200).round());
      final blockW = (x1 - x0) / nx, blockD = (y1 - y0) / ny;
      final seg = ((x1 - x0) / 40).clamp(12.0, 60.0);
      final bite = math.min(w, d) * 0.16;
      for (var by = 0; by < ny; by++) {
        final yb0 = y0 + by * blockD + 4, yb1 = y0 + (by + 1) * blockD - 4;
        for (var bx = 0; bx < nx; bx++) {
          final xb0 = x0 + bx * blockW + 4, xb1 = x0 + (bx + 1) * blockW - 4;
          for (var y = yb0 + rowPitch / 2; y + 2 <= yb1; y += rowPitch) {
            for (var x = xb0 + seg / 2; x + seg / 2 <= xb1; x += seg + 1.6) {
              if ((x1 - x) + (y1 - y) < bite) continue;
              if ((x - x0) + (y1 - y) < bite * 0.6) continue;
              volumes.add(MassBox(
                x: x,
                y: y,
                z: 0,
                width: seg,
                depth: 0.5,
                height: tableH,
                glazed: false,
                shape: MassShape.panel,
                yaw: -math.pi / 2,
                tilt: tilt,
              ));
            }
          }
          // The block's inverter and transformer, on a pad in its lane.
          if (blockW > 40 && blockD > 30) {
            final px = xb0 + 12, py = yb0 - 4;
            volumes.add(_slab(px, py, 12, 6, h: 0.3));
            volumes.add(_block(px - 2.5, py, 5, 2.4, 2.6));
            volumes.add(_block(px + 3.5, py, 2.2, 2.2, 2.2));
          }
        }
      }
    }

    // The yard: control room by the gate, the substation, the batteries.
    final gate = -d / 2;
    volumes.add(MassBox(
      x: x0 + 9 * k,
      y: gate + 10 * k,
      z: 0,
      width: 18 * k,
      depth: 12 * k,
      height: 5 * math.max(0.4, k),
      floors: 1,
    ));
    volumes.add(_slab(x0 + 50 * k, gate + 24 * k, 44 * k, 30 * k));
    for (var i = 0; i < 3; i++) {
      volumes.add(_block(x0 + 50 * k, gate + 13 * k + i * 9 * k, 30 * k,
          math.max(0.3, 1.2 * k), 5.5 * k));
    }
    for (var i = 0; i < 2; i++) {
      volumes.add(_block(x0 + 42 * k + i * 9 * k, gate + 34 * k, 4 * k, 3 * k,
          3.5 * k));
    }
    final rows = big ? 4 : 1, perRow = big ? 10 : 6;
    if (big) {
      volumes.add(_slab(x0 + 90 * k + 4.5 * 15 * k, gate + 20 * k + 1.5 * 12 * k,
          160 * k, 50 * k));
    }
    for (var r = 0; r < rows; r++) {
      for (var i = 0; i < perRow; i++) {
        volumes.add(_block(x0 + 90 * k + i * 15 * k, gate + 20 * k + r * 12 * k,
            12 * k, 2.4 * k, 2.9 * k));
      }
    }
    // The fence.
    for (final (x, y, fw, fd) in [
      (0.0, -d / 2 + 2, w - 4, 0.12),
      (0.0, d / 2 - 2, w - 4, 0.12),
      (-w / 2 + 2, 0.0, 0.12, d - 4),
      (w / 2 - 2, 0.0, 0.12, d - 4),
    ]) {
      volumes.add(MassBox(
          x: x, y: y, z: 0, width: fw, depth: fd, height: 2.2, glazed: false));
    }
    return BuildingMassing(
      volumes: volumes,
      storeyM: storeyM,
      floorArea: 18 * 12 * k * k,
      entrance: (x0 + 9 * k, -d / 2),
      style: style,
      parking: _lotFor(spec, math.min(w, 40), frontY: -d / 2, volumes: volumes),
    );
  }

  /// Installations that TILE a bigger plot rather than stretch over it —
  /// more towers, not a bigger field — and so are let past the site cap.
  static const Set<String> _tilesItsPlot = {'solarthermal'};

  /// A solar thermal plant, the Crescent Dunes kind: heliostats in
  /// concentric rings about a central receiver tower, staggered ring to
  /// ring and spaced wider toward the rim, six radial roads through them,
  /// the power block on a round pad at the tower's foot inside a cleared
  /// ring, and the evaporation ponds and the control building outside the
  /// circle at the access corner.
  ///
  /// One tower per ~1150 m of plot each way: a heliostat much past 600 m
  /// from its receiver is wasted, so a bigger plot gets more towers rather
  /// than a bigger field. Every mirror faces its own tower, and tips so its
  /// normal bisects the sun and the receiver — the near rings lie back,
  /// the far ones stand up, which is the gradient the real fields show.
  BuildingMassing _solarThermal(
      CityBuildingSpec spec, double w, double d, double storey) {
    const cellM = 1150.0;
    const sunElev = 0.85; // radians: a high sun, the design point
    final cols = math.max(1, (w / cellM).floor());
    final rows = math.max(1, (d / cellM).floor());
    final cellW = w / cols, cellD = d / rows;
    // The field is the circle the cell holds, less a verge and the reach
    // of the outermost plates. The power block scales with the field, so
    // a demonstration plant on a small plot is a small plant, not a full
    // one overhanging its fence.
    final fieldR = math.max(10.0, math.min(cellW, cellD) / 2 * 0.94 - 6);
    final k = (fieldR / 560).clamp(0.1, 1.0);
    final towerH = math.min(
        210.0, math.max(fieldR * 0.32, math.min(80.0, fieldR * 0.8)));
    final clearR = (fieldR * 0.16).clamp(8.0, 120.0);
    final volumes = <MassBox>[];
    for (var c = 0; c < cols; c++) {
      for (var r = 0; r < rows; r++) {
        final cx = -w / 2 + cellW * (c + 0.5);
        final cy = -d / 2 + cellD * (r + 0.5);
        // The tower, its receiver, and the pad at its foot.
        volumes.add(_stack(cx, cy, 14 * k, towerH, top: 0.72));
        volumes.add(_tank(cx, cy, 11 * k, 22 * k, z: towerH));
        volumes.add(_tank(cx, cy, math.max(4.0, clearR * 2 - 8), 0.3));
        // The power block: turbine hall, hot and cold salt tanks, the
        // air-cooled condenser.
        volumes.add(_shed(cx + 34 * k, cy, 52 * k, 26 * k, 16 * k));
        volumes.add(_tank(cx - 30 * k, cy + 20 * k, 22 * k, 14 * k));
        volumes.add(_tank(cx - 30 * k, cy - 20 * k, 22 * k, 14 * k));
        volumes.add(_block(cx, cy - 44 * k, 44 * k, 18 * k, 12 * k));
        // The mirrors.
        var ring = 0;
        var rad = clearR + 8;
        while (rad <= fieldR) {
          final t = rad / fieldR;
          final along = 12.0 + 6.0 * t;
          final n = math.max(8, (2 * math.pi * rad / along).floor());
          final offset = ring.isOdd ? 0.5 : 0.0;
          final towerElev = math.atan2(towerH * 0.9, rad);
          final tilt = (sunElev + towerElev) / 2;
          for (var i = 0; i < n; i++) {
            final a = (i + offset) / n * 2 * math.pi;
            // Six radial roads, seven metres each side of the line.
            final spoke = a % (math.pi / 3);
            if (math.min(spoke, math.pi / 3 - spoke) * rad < 7) continue;
            volumes.add(MassBox(
              x: cx + math.cos(a) * rad,
              y: cy + math.sin(a) * rad,
              z: 0,
              width: 10.4,
              depth: 0.5,
              height: 8.2,
              glazed: false,
              shape: MassShape.mirror,
              yaw: a + math.pi,
              tilt: tilt,
            ));
          }
          rad += 11.0 + 6.5 * t;
          ring++;
        }
      }
    }
    // Outside the circles, at the access corner: three evaporation ponds
    // and the control building.
    final pondW = math.min(90.0, w * 0.08), pondD = math.min(60.0, d * 0.08);
    for (var i = 0; i < 3; i++) {
      volumes.add(_slab(-w / 2 + w * 0.03 + pondW / 2 + i * (pondW + w * 0.01),
          -d / 2 + d * 0.04 + pondD / 2, pondW, pondD,
          h: 0.4));
    }
    final officeW = math.min(30.0, w * 0.2), officeD = math.min(14.0, d * 0.12);
    volumes.add(_office(-w / 2 + w * 0.04 + officeW / 2,
        -d / 2 + d * 0.15 + officeD / 2, officeW, officeD, 2, storey));
    return BuildingMassing(
      volumes: volumes,
      storeyM: storey,
      floorArea: officeW * officeD * 2,
      entrance: (-w / 2 + w * 0.04, -d / 2),
      style: style,
      parking: _lotFor(spec, math.min(w, 120), frontY: -d / 2, volumes: volumes),
    );
  }

  /// A farm: crop rows over the whole field, a farmhouse and a barn at the
  /// access corner.
  ///
  /// The generic field is a solar array — racks at rack height — and a farm
  /// drawn with it read as a power station. Crops are low and wide and run
  /// in closer rows, and the two buildings by the gate are what say
  /// "somebody lives here" from a kilometre up.
  BuildingMassing _farm(
      CityBuildingSpec spec, double w, double d, double storey) {
    const rowPitch = 6.0;
    const rowDepth = 4.4;
    const cropHeight = 0.9;
    // The yard at the access corner stays clear of the rows.
    final yardD = math.min(34.0, d * 0.4);
    final rows = math.max(1, ((d - yardD) / rowPitch).floor());
    final volumes = <MassBox>[
      for (var i = 0; i < rows; i++)
        if (-d / 2 + yardD + rowPitch * (i + 0.5) + rowDepth / 2 <= d / 2)
          MassBox(
            x: 0,
            y: -d / 2 + yardD + rowPitch * (i + 0.5),
            z: 0,
            width: w * 0.94,
            depth: math.min(rowDepth, d * 0.2),
            height: cropHeight,
            glazed: false,
          ),
      // Farmhouse: two storeys, windows. Sized off the site so a squeezed
      // plot gets a squeezed farmstead rather than one over its line.
      MassBox(
        x: -w / 2 + math.min(14, w * 0.18),
        y: -d / 2 + math.min(12, d * 0.2),
        z: 0,
        width: math.min(13, w * 0.24),
        depth: math.min(9, d * 0.2),
        height: storey * 2,
        floors: 2,
      ),
      // Barn: one tall open volume, no windows.
      MassBox(
        x: -w / 2 + math.min(38, w * 0.6),
        y: -d / 2 + math.min(14, d * 0.24),
        z: 0,
        width: math.min(22, w * 0.3),
        depth: math.min(12, d * 0.24),
        height: 7.5,
        glazed: false,
      ),
    ];
    return BuildingMassing(
      volumes: volumes,
      storeyM: storey,
      floorArea: 13 * 9 * 2,
      entrance: (-w / 2 + 14, -d / 2),
      style: style,
    );
  }

  /// A railway station: a two-storey hall astride a platform that runs the
  /// length of the site, under a glazed canopy.
  ///
  /// Symmetric about the site's midline on purpose — a claimed plot carries
  /// no frontage, so the massing cannot know which side the line runs on,
  /// and a platform that serves both sides serves whichever it is.
  BuildingMassing _station(
      CityBuildingSpec spec, double w, double d, double storey) {
    final hallW = math.min(64.0, w * 0.4);
    final hallD = math.min(26.0, d * 0.4);
    final volumes = <MassBox>[
      // The platform: a low slab the full width of the site.
      MassBox(
        x: 0,
        y: 0,
        z: 0,
        width: w,
        depth: math.min(22.0, d * 0.35),
        height: 1.0,
        glazed: false,
      ),
      // The hall, standing on the platform.
      MassBox(
        x: 0,
        y: 0,
        z: 1.0,
        width: hallW,
        depth: hallD,
        height: storey * 2,
        floors: 2,
      ),
      // The clock tower.
      MassBox(
        x: hallW / 2 - math.min(5.0, hallW * 0.3),
        y: 0,
        z: 1.0,
        width: math.min(7.0, hallW * 0.3),
        depth: math.min(7.0, hallD * 0.4),
        height: storey * 2 + 12,
        floors: 5,
      ),
      // Canopies either side of the hall, glazed, thin, on the platform's
      // own line.
      for (final sx in const [-1.0, 1.0])
        MassBox(
          x: sx * (hallW / 2 + (w - hallW) / 4),
          y: 0,
          z: 5.2,
          width: math.max(0.5, (w - hallW) / 2 - math.min(4.0, w * 0.05)),
          depth: math.min(16.0, d * 0.28),
          height: 0.5,
          glazed: true,
        ),
    ];
    return BuildingMassing(
      volumes: volumes,
      storeyM: storey,
      floorArea: hallW * hallD * 2,
      entrance: (0, -d / 2),
      style: style,
      parking: _lotFor(spec, math.min(w, 120), frontY: -d / 2, volumes: volumes),
    );
  }

  /// A freight yard: hardstanding, a transit shed along one side, stacked
  /// containers, and a gantry crane over the loading line.
  BuildingMassing _freightYard(
      CityBuildingSpec spec, double w, double d, double storey) {
    // Every dimension a fraction of the site with a real-world cap, so a
    // squeezed plot gets a squeezed yard that still fits it.
    final shedW = w * 0.55;
    final shedD = math.min(28.0, d * 0.3);
    const shedH = 9.0;
    final stackY = d / 4;
    final craneY = d / 2 - math.min(22.0, d * 0.2);
    final volumes = <MassBox>[
      MassBox(
        x: 0,
        y: 0,
        z: 0,
        width: w,
        depth: d,
        height: 0.25,
        glazed: false,
      ),
      // The transit shed, along the far side from the line.
      MassBox(
        x: -w / 2 + shedW / 2 + math.min(10.0, w * 0.05),
        y: -d / 2 + shedD / 2 + math.min(8.0, d * 0.08),
        z: 0,
        width: shedW,
        depth: shedD,
        height: shedH,
        floors: 1,
        glazed: false,
      ),
      // The office at the gate.
      MassBox(
        x: w / 2 - math.min(22.0, w * 0.15),
        y: -d / 2 + math.min(14.0, d * 0.2),
        z: 0,
        width: math.min(18.0, w * 0.2),
        depth: math.min(12.0, d * 0.2),
        height: storey * 2,
        floors: 2,
      ),
      // Container stacks: a row of blocks, two high, with gaps a
      // straddle-carrier fits down.
      for (var i = 0; i < 8; i++)
        MassBox(
          x: -w / 2 +
              math.min(30.0, w * 0.1) +
              (i + 0.5) * (w - math.min(60.0, w * 0.2)) / 8,
          y: stackY,
          z: 0,
          width: math.min(12.2, w * 0.06),
          depth: math.min(5.0, d * 0.04),
          height: 5.2,
          glazed: false,
        ),
      // Gantry crane: two legs and a beam spanning the loading line.
      for (final sx in const [-1.0, 1.0])
        MassBox(
          x: sx * math.min(14.0, w * 0.1),
          y: craneY,
          z: 0,
          width: math.min(1.6, w * 0.02),
          depth: math.min(1.6, d * 0.02),
          height: 14,
          glazed: false,
        ),
      MassBox(
        x: 0,
        y: craneY,
        z: 14,
        width: math.min(32.0, w * 0.22),
        depth: math.min(2.2, d * 0.03),
        height: 1.8,
        glazed: false,
      ),
    ];
    return BuildingMassing(
      volumes: volumes,
      storeyM: storey,
      floorArea: shedW * shedD + 18 * 12 * 2,
      entrance: (w / 2 - 22, -d / 2),
      style: style,
      parking: _lotFor(spec, math.min(w, 120), frontY: -d / 2, volumes: volumes),
    );
  }

  // ---- Installations -------------------------------------------------------
  //
  // Every massing below is laid out at the spec's NOMINAL site and scaled
  // down uniformly when the lot handed in is smaller, so it stays inside the
  // plot on any lot the degenerate-lot sweep throws at it. Positions are
  // relative to the site centre; y runs away from the access side.

  MassBox _tank(double x, double y, double dia, double h,
          {double z = 0, int? material}) =>
      MassBox(
          x: x,
          y: y,
          z: z,
          width: dia,
          depth: dia,
          height: h,
          glazed: false,
          shape: MassShape.cylinder,
          material: material);

  MassBox _stack(double x, double y, double dia, double h,
          {double top = 0.7, double z = 0, int? material}) =>
      MassBox(
          x: x,
          y: y,
          z: z,
          width: dia,
          depth: dia,
          height: h,
          glazed: false,
          shape: MassShape.frustum,
          topScale: top,
          material: material);

  MassBox _shed(double x, double y, double w, double d, double h,
          {bool glazed = false, int floors = 0, int? material}) =>
      MassBox(
          x: x,
          y: y,
          z: 0,
          width: w,
          depth: d,
          height: h,
          floors: floors,
          glazed: glazed,
          shape: MassShape.gable,
          material: material);

  MassBox _block(double x, double y, double w, double d, double h,
          {bool glazed = false, int floors = 0, double z = 0, int? material}) =>
      MassBox(
          x: x,
          y: y,
          z: z,
          width: w,
          depth: d,
          height: h,
          floors: floors,
          glazed: glazed,
          material: material);

  /// A vehicle standing at (x, y), [l] long along [yaw], [w] wide, [h] tall.
  MassBox _vehicle(double x, double y, double l, double w, double h,
          {double yaw = 0, int? material}) =>
      MassBox(
          x: x,
          y: y,
          z: 0,
          width: l,
          depth: w,
          height: h,
          glazed: false,
          shape: MassShape.vehicle,
          yaw: yaw,
          material: material);

  /// A red-and-white banded stack: [segments] drums alternating, a cone on
  /// top — the aviation marking every tall stack carries.
  List<MassBox> _bandedStack(double x, double y, double dia, double h,
      {int segments = 4}) {
    final seg = h / (segments + 0.4);
    return [
      for (var k = 0; k < segments; k++)
        _tank(x, y, dia, seg,
            z: k * seg,
            material: k.isEven
                ? FacadeMaterial.whiteMetal
                : FacadeMaterial.safetyRed),
      _stack(x, y, dia, seg * 0.4,
          top: 0.8, z: segments * seg, material: FacadeMaterial.steel),
    ];
  }

  /// An excavator: tracks, a cab, and its boom out over a bucket.
  List<MassBox> _excavator(double x, double y) => [
        _block(x, y, 5, 3.2, 1.4, material: FacadeMaterial.darkBrick),
        _block(x, y, 3.4, 3.0, 2.4, z: 1.4, material: FacadeMaterial.safetyYellow),
        _block(x + 4.5, y, 6, 0.9, 0.9, z: 3.0, material: FacadeMaterial.safetyYellow),
        _block(x + 8, y, 1.4, 1.4, 1.2, z: 0.6, material: FacadeMaterial.darkBrick),
      ];

  /// A switchyard gantry: a steel beam on posts every twenty metres, [l]
  /// long along x, [h] up — a lattice frame from any distance it is seen
  /// at, and not the wall a solid block of the same size is.
  List<MassBox> _gantry(double x, double y, double l, double h) => [
        _block(x, y, l, 1.2, 1.2, z: h - 1.2, material: FacadeMaterial.steel),
        for (var p = 0; p <= (l / 20).floor(); p++)
          _block(x - l / 2 + p * (l / math.max(1, (l / 20).floor())), y, 0.8,
              0.8, h - 1.2,
              material: FacadeMaterial.steel),
      ];

  /// A tank's trim: a thin ring of [material] at [z].
  MassBox _ring(double x, double y, double dia, double z, int material) =>
      _tank(x, y, dia + 0.3, 0.8, z: z, material: material);

  /// A building's trim: a coloured band along its top edge.
  MassBox _trim(double x, double y, double w, double d, double h, int material) =>
      _block(x, y, w + 0.4, d + 0.4, 0.9, z: h - 0.9, material: material);

  /// A sign: a coloured plate on a wall's face, [w] wide, [z] up.
  MassBox _sign(double x, double y, double w, double z, int material) =>
      _block(x, y, w, 0.3, 1.6, z: z, material: material);

  MassBox _office(double x, double y, double w, double d, int floors,
          double storey) =>
      MassBox(
          x: x,
          y: y,
          z: 0,
          width: w,
          depth: d,
          height: floors * storey,
          floors: floors);

  MassBox _slab(double x, double y, double w, double d, {double h = 0.25}) =>
      MassBox(x: x, y: y, z: 0, width: w, depth: d, height: h, glazed: false);

  /// Scale a nominal layout to the lot: every coordinate and size times [k],
  /// so a smaller lot gets a smaller plant rather than one hanging over its
  /// line.
  List<MassBox> _fit(List<MassBox> nominal, double k) => [
        for (final v in nominal)
          MassBox(
            x: v.x * k,
            y: v.y * k,
            z: v.z * k,
            width: math.max(0.2, v.width * k),
            depth: math.max(0.2, v.depth * k),
            height: math.max(0.2, v.height * k),
            floors: v.floors,
            glazed: v.glazed,
            shape: v.shape,
            topScale: v.topScale,
            yaw: v.yaw,
            tilt: v.tilt,
            material: v.material,
          )
      ];

  BuildingMassing? _installation(
      CityBuildingSpec spec, double w, double d, double storey) {
    final site = spec.siteMetres();
    final nomW = site.width, nomD = site.depth;
    // How much of the nominal site the lot gives: 1 on a claimed plot, less
    // on anything smaller.
    final k = math.min(1.0, math.min(w / nomW, d / nomD));
    final hw = nomW / 2, hd = nomD / 2;
    List<MassBox>? nominal;
    var floorArea = 0.0;
    var parkW = math.min(nomW, 120.0);

    switch (spec.type) {
      case 'wind':
        // Five turbines, one to a corner and one in the middle: a tower,
        // a nacelle, a rotor. The rotor faces the access side.
        nominal = [
          for (final (tx, ty) in [
            (-hw * 0.6, -hd * 0.6),
            (hw * 0.6, -hd * 0.6),
            (-hw * 0.6, hd * 0.6),
            (hw * 0.6, hd * 0.6),
            (0.0, 0.0),
          ]) ...[
            _stack(tx, ty, 4.6, 80, top: 0.6),
            _block(tx, ty + 1.5, 4, 10, 4, z: 80),
            MassBox(
              x: tx,
              y: ty - 4.5,
              z: 82,
              width: 3.2,
              depth: 0.4,
              height: 38,
              glazed: false,
              shape: MassShape.rotor,
            ),
          ],
          _office(-hw + 16, -hd + 10, 16, 10, 1, storey),
        ];
        floorArea = 160;
        parkW = 40;
      case 'aquifer':
        // A groundwater pumping station: two ground storage tanks under
        // low aluminium domes; the pump house, a long white shed with the
        // blue discharge manifold along its face and a lean-to for the
        // switchgear; a yard of blue pumps on plinths under their header;
        // a big blue transmission main crossing the site on saddles; the
        // chemical building and the standby generator; a pole-line
        // substation; wellheads in the grass; admin with its car park at
        // the gate; pickups; a fence.
        nominal = [
          _slab(-hw * 0.1, -hd * 0.05, 92, 36),
          _slab(hw * 0.45, -hd * 0.1, 30, 16),
          _slab(0, -hd * 0.75, 8, nomD * 0.3, h: 0.5),
          // Storage.
          for (final (tx, ty, dia) in [(-hw * 0.55, hd * 0.45, 60.0), (hw * 0.15, hd * 0.5, 56.0)]) ...[
            _tank(tx, ty, dia, 10, material: FacadeMaterial.whiteMetal),
            MassBox(
              x: tx,
              y: ty,
              z: 10,
              width: dia,
              depth: dia,
              height: dia * 0.11,
              glazed: false,
              shape: MassShape.dome,
              material: FacadeMaterial.whiteMetal,
            ),
            _ring(tx, ty, dia, 4, FacadeMaterial.industrialBlue),
            // The tank's inlet riser and the valve pit beside it.
            _tank(tx + dia / 2 + 2, ty - 6, 1.0, 3, material: FacadeMaterial.industrialBlue),
            _block(tx + dia / 2 + 4, ty - 6, 4, 3, 0.5, material: FacadeMaterial.precast),
          ],
          // The pump house and its lean-to.
          _shed(-hw * 0.1, -hd * 0.05, 70, 18, 11, material: FacadeMaterial.whiteMetal),
          _trim(-hw * 0.1, -hd * 0.05, 70, 18, 7.5, FacadeMaterial.industrialBlue),
          _block(-hw * 0.5, -hd * 0.05, 24, 14, 6, material: FacadeMaterial.metalPanel),
          _sign(-hw * 0.1, -hd * 0.05 - 9.2, 8, 4.5, FacadeMaterial.industrialBlue),
          // The discharge manifold: a header along the face and an elbow
          // up from it at each pump.
          _block(-hw * 0.1, -hd * 0.05 - 12.5, 48, 1.0, 1.0, z: 0.5, material: FacadeMaterial.industrialBlue),
          for (var i = 0; i < 6; i++) ...[
            _tank(-hw * 0.1 - 20 + i * 8, -hd * 0.05 - 12.5, 1.0, 2.4, material: FacadeMaterial.industrialBlue),
            _block(-hw * 0.1 - 20 + i * 8, -hd * 0.05 - 11, 1.0, 3.0, 1.0, z: 1.4, material: FacadeMaterial.industrialBlue),
            _block(-hw * 0.1 - 20 + i * 8, -hd * 0.05 - 12.5, 1.6, 1.6, 0.4, material: FacadeMaterial.precast),
          ],
          // The yard: four pumps on plinths under a header, valves in red.
          _block(hw * 0.45, -hd * 0.1, 26, 1.0, 1.0, z: 1.0, material: FacadeMaterial.industrialBlue),
          for (var i = 0; i < 4; i++) ...[
            _block(hw * 0.45 - 9 + i * 6, -hd * 0.1 + 3, 2.2, 2.2, 0.6, material: FacadeMaterial.precast),
            _tank(hw * 0.45 - 9 + i * 6, -hd * 0.1 + 3, 1.3, 2.8, z: 0.6, material: FacadeMaterial.industrialBlue),
            _tank(hw * 0.45 - 9 + i * 6, -hd * 0.1, 0.8, 1.6, z: 0.6, material: FacadeMaterial.safetyRed),
          ],
          // The transmission main across the site on saddles.
          _block(hw * 0.78, hd * 0.1, 1.6, nomD * 0.55, 1.6, z: 1.0, material: FacadeMaterial.industrialBlue),
          for (var i = 0; i < 5; i++)
            _block(hw * 0.78, -hd * 0.15 + i * nomD * 0.125, 2.4, 1.2, 1.0, material: FacadeMaterial.precast),
          _tank(hw * 0.78, -hd * 0.18, 1.6, 3.2, material: FacadeMaterial.industrialBlue),
          _tank(hw * 0.78, hd * 0.38, 1.6, 3.2, material: FacadeMaterial.industrialBlue),
          // Chemical building, its tank, and the standby generator.
          _block(hw * 0.55, hd * 0.5, 14, 10, 5, material: FacadeMaterial.precast),
          _tank(hw * 0.55 + 10, hd * 0.5, 4, 5, material: FacadeMaterial.whiteMetal),
          _slab(hw * 0.55, hd * 0.15, 10, 6),
          _block(hw * 0.55, hd * 0.15, 6, 2.4, 2.6, material: FacadeMaterial.whiteMetal),
          // The substation on poles.
          _slab(-hw * 0.85, -hd * 0.4, 20, 14),
          for (var i = 0; i < 2; i++)
            _block(-hw * 0.85 - 4 + i * 8, -hd * 0.4, 4, 3, 3.5, material: FacadeMaterial.metalPanel),
          for (var i = 0; i < 3; i++) ...[
            _stack(-hw * 0.85 - 8 + i * 8, -hd * 0.4 - 8, 0.4, 12, top: 0.8, material: FacadeMaterial.darkBrick),
            _block(-hw * 0.85 - 8 + i * 8, -hd * 0.4 - 8, 2.4, 0.2, 0.2, z: 11, material: FacadeMaterial.darkBrick),
          ],
          // Wellheads in the grass.
          for (final (wx, wy) in [(-hw * 0.85, hd * 0.2), (-hw * 0.9, hd * 0.65), (hw * 0.35, -hd * 0.2), (-hw * 0.2, hd * 0.85)]) ...[
            _block(wx, wy, 3, 3, 0.4, material: FacadeMaterial.precast),
            _tank(wx, wy, 0.5, 1.4, material: FacadeMaterial.industrialBlue),
          ],
          // Admin at the gate, and the vehicles about.
          _office(hw * 0.35, -hd * 0.6, 40, 22, 1, storey),
          _trim(hw * 0.35, -hd * 0.6, 40, 22, storey, FacadeMaterial.industrialBlue),
          _sign(hw * 0.35, -hd * 0.6 - 11.2, 8, 2.2, FacadeMaterial.industrialBlue),
          _vehicle(-hw * 0.1 + 30, -hd * 0.05 - 16, 5.6, 2.1, 1.9, yaw: 0.3, material: FacadeMaterial.whiteMetal),
          _vehicle(-hw * 0.1 + 38, -hd * 0.05 - 16, 5.6, 2.1, 1.9, yaw: 0.3, material: FacadeMaterial.whiteMetal),
          _vehicle(hw * 0.35 - 26, -hd * 0.6, 5.5, 2.0, 2.4, yaw: math.pi / 2, material: FacadeMaterial.whiteMetal),
          for (final (mx, my) in [(-hw * 0.3, -hd * 0.4), (hw * 0.1, -hd * 0.35)])
            _stack(mx, my, 0.5, 14, top: 0.7, material: FacadeMaterial.steel),
          for (final (x, y, fw, fd) in [
            (0.0, -hd + 3, nomW - 6, 0.12),
            (0.0, hd - 3, nomW - 6, 0.12),
            (-hw + 3, 0.0, 0.12, nomD - 6),
            (hw - 3, 0.0, 0.12, nomD - 6),
          ])
            MassBox(
                x: x,
                y: y,
                z: 0,
                width: fw,
                depth: fd,
                height: 2.2,
                glazed: false,
                material: FacadeMaterial.steel),
        ];
        floorArea = 40 * 22;
        parkW = 80;
      case 'gas':
        // A combined-cycle plant: two gas-turbine trains — a white
        // enclosure, a silver boiler block, a steel stack — feeding one
        // white steam-turbine hall with blue trim; two banks of fan-cell
        // cooling towers in concrete; the switchyard along the back fence
        // in steel; white water tanks on the front; admin, warehouse and
        // the car park at the gate; and the pickups, the tanker, the
        // forklift and the containers a working site has about it.
        nominal = [
          _slab(hw * 0.05, hd * 0.05, nomW * 0.82, nomD * 0.7),
          for (var i = 0; i < 2; i++) ...[
            _block(-hw * 0.32, -hd * 0.22 + i * 60, 30, 12, 12,
                material: FacadeMaterial.whiteMetal),
            _trim(-hw * 0.32, -hd * 0.22 + i * 60, 30, 12, 12,
                FacadeMaterial.industrialBlue),
            _block(-hw * 0.12, -hd * 0.22 + i * 60, 34, 14, 26,
                material: FacadeMaterial.steel),
            _stack(hw * 0.02, -hd * 0.22 + i * 60, 6, 66,
                top: 0.9, material: FacadeMaterial.steel),
            _block(-hw * 0.2, -hd * 0.22 + i * 60 + 11, 70, 3, 6,
                z: 7, material: FacadeMaterial.steel),
            for (var q = 0; q < 4; q++)
              _block(-hw * 0.2 - 30 + q * 20, -hd * 0.22 + i * 60 + 11, 1, 1, 7,
                  material: FacadeMaterial.steel),
          ],
          _shed(hw * 0.3, -hd * 0.05, 46, 32, 22,
              material: FacadeMaterial.whiteMetal),
          _trim(hw * 0.3, -hd * 0.05, 46, 32, 16, FacadeMaterial.industrialBlue),
          _sign(hw * 0.3, -hd * 0.05 - 16.2, 10, 9, FacadeMaterial.industrialBlue),
          for (var b = 0; b < 2; b++) ...[
            _block(hw * 0.55, hd * 0.28 + b * 44, 62, 30, 14,
                material: FacadeMaterial.precast),
            for (var i = 0; i < 4; i++)
              for (var j = 0; j < 2; j++)
                _tank(hw * 0.55 - 23 + i * 15.3, hd * 0.28 + b * 44 - 7.5 + j * 15,
                    11, 2.2,
                    z: 14, material: FacadeMaterial.steel),
          ],
          _slab(-hw * 0.2, hd * 0.72, nomW * 0.5, nomD * 0.22),
          for (var i = 0; i < 4; i++)
            ..._gantry(-hw * 0.2, hd * 0.62 + i * nomD * 0.06, nomW * 0.42, 9),
          for (var i = 0; i < 3; i++)
            _block(-hw * 0.4 + i * 40, hd * 0.9, 7, 4, 5,
                material: FacadeMaterial.metalPanel),
          _tank(-hw * 0.62, -hd * 0.55, 32, 12, material: FacadeMaterial.whiteMetal),
          _ring(-hw * 0.62, -hd * 0.55, 32, 6, FacadeMaterial.industrialBlue),
          _tank(hw * 0.7, -hd * 0.55, 30, 12, material: FacadeMaterial.whiteMetal),
          _ring(hw * 0.7, -hd * 0.55, 30, 6, FacadeMaterial.industrialBlue),
          for (var i = 0; i < 3; i++)
            _tank(-hw * 0.45 + i * 12, -hd * 0.62, 7, 9,
                material: FacadeMaterial.steel),
          _office(-hw * 0.82, -hd * 0.8, 40, 16, 2, storey),
          _sign(-hw * 0.82, -hd * 0.8 - 8.2, 8, 5, FacadeMaterial.industrialBlue),
          _shed(-hw * 0.82, -hd * 0.45, 44, 20, 8,
              material: FacadeMaterial.whiteMetal),
          _trim(-hw * 0.82, -hd * 0.45, 44, 20, 5.8, FacadeMaterial.industrialBlue),
          // On site: pickups by the office, the tanker at the tanks, a
          // forklift at the warehouse, containers by the fence.
          for (var i = 0; i < 3; i++)
            _vehicle(-hw * 0.82 - 14 + i * 7, -hd * 0.66, 5.6, 2.1, 1.9,
                yaw: math.pi / 2, material: FacadeMaterial.whiteMetal),
          _vehicle(-hw * 0.5, -hd * 0.72, 13, 2.6, 3.6,
              material: FacadeMaterial.whiteMetal),
          _vehicle(-hw * 0.82 + 28, -hd * 0.45, 3, 1.6, 2.3,
              yaw: 0.4, material: FacadeMaterial.safetyYellow),
          _vehicle(hw * 0.3, -hd * 0.3, 5.6, 2.1, 1.9,
              yaw: 1.2, material: FacadeMaterial.safetyRed),
          for (var i = 0; i < 4; i++)
            _block(-hw * 0.82 + 30, -hd * 0.25 + i * 4, 12, 2.4, 2.6,
                material: i.isEven
                    ? FacadeMaterial.whiteMetal
                    : FacadeMaterial.industrialBlue),
        ];
        floorArea = 40 * 16 * 2;
        parkW = 60;
      case 'reactor':
        // A two-unit pressurised-water station, and everything a real one
        // has round its big pieces — which is what gives them their scale:
        // each unit a domed containment with auxiliary and fuel buildings
        // and a windowless turbine hall, its transformer bays behind
        // firewalls, its diesel houses with their stacks, pipe racks on
        // posts out to the pump house at its cooling tower; each tower a
        // waisted shell on a ring of legs over its basin; the vent stack;
        // the switchyard with gantries, transformers and the first pylons;
        // roads joining the pads; at the gate a guardhouse under a canopy,
        // admin, security, training, canteen, fire station, workshops,
        // warehouses and water treatment; a laydown yard of containers
        // under a crane; tanks, a basin, a helipad, a met mast, lighting
        // masts, and a second fence round the protected area.
        nominal = [
          // Roads, then the pads they join.
          _slab(-hw * 0.69, -hd * 0.19, 8, nomD * 0.8, h: 0.5),
          _slab(hw * 0.06, -hd * 0.6, nomW * 0.74, 8, h: 0.5),
          _slab(hw * 0.06, hd * 0.6, nomW * 0.74, 8, h: 0.5),
          _slab(hw * 0.8, 0, 8, nomD * 1.2 * 0.5, h: 0.5),
          _slab(-hw * 0.29, 0, 8, nomD * 0.6, h: 0.5),
          for (var i = 0; i < 2; i++) ...[
            // The unit: its pad, the containment, the buildings about it.
            _slab(-hw * 0.45 + 40, -hd * 0.1 + i * 220, 300, 150, h: 0.25),
            _tank(-hw * 0.45, -hd * 0.1 + i * 220, 44, 50,
                material: FacadeMaterial.precast),
            MassBox(
              x: -hw * 0.45,
              y: -hd * 0.1 + i * 220,
              z: 50,
              width: 44,
              depth: 44,
              height: 22,
              glazed: false,
              shape: MassShape.dome,
              material: FacadeMaterial.precast,
            ),
            _block(-hw * 0.45 + 52, -hd * 0.1 + i * 220, 50, 40, 24,
                material: FacadeMaterial.precast),
            _block(-hw * 0.45 - 40, -hd * 0.1 + i * 220 + 30, 30, 30, 20,
                material: FacadeMaterial.precast),
            _block(-hw * 0.45 + 130, -hd * 0.1 + i * 220, 100, 60, 32,
                material: FacadeMaterial.whiteMetal),
            _trim(-hw * 0.45 + 130, -hd * 0.1 + i * 220, 100, 60, 32,
                FacadeMaterial.industrialBlue),
            _sign(-hw * 0.45 + 130, -hd * 0.1 + i * 220 - 30.2, 14, 20,
                FacadeMaterial.industrialBlue),
            _block(-hw * 0.45 + 130, -hd * 0.1 + i * 220 + 45, 60, 20, 12,
                material: FacadeMaterial.whiteMetal),
            // Transformer bays behind firewalls, on their own pad.
            _slab(-hw * 0.45 + 130, -hd * 0.1 + i * 220 - 48, 80, 14, h: 0.3),
            for (var t = 0; t < 3; t++)
              _block(-hw * 0.45 + 108 + t * 22, -hd * 0.1 + i * 220 - 48, 9, 6, 7,
                  material: FacadeMaterial.metalPanel),
            for (var t = 0; t < 2; t++)
              _block(-hw * 0.45 + 119 + t * 22, -hd * 0.1 + i * 220 - 48, 0.6, 9, 8,
                  material: FacadeMaterial.precast),
            // Diesel houses with their stacks; demin tanks.
            _block(-hw * 0.45 - 10, -hd * 0.1 + i * 220 - 45, 28, 14, 9,
                material: FacadeMaterial.whiteMetal),
            _block(-hw * 0.45 + 30, -hd * 0.1 + i * 220 - 45, 28, 14, 9,
                material: FacadeMaterial.whiteMetal),
            _stack(-hw * 0.45 - 10, -hd * 0.1 + i * 220 - 40, 1.6, 16,
                top: 0.8, material: FacadeMaterial.steel),
            _stack(-hw * 0.45 + 30, -hd * 0.1 + i * 220 - 40, 1.6, 16,
                top: 0.8, material: FacadeMaterial.steel),
            _tank(-hw * 0.45 - 70, -hd * 0.1 + i * 220 - 52, 10, 12,
                material: FacadeMaterial.whiteMetal),
            _tank(-hw * 0.45 - 83, -hd * 0.1 + i * 220 - 52, 10, 12,
                material: FacadeMaterial.whiteMetal),
            _vehicle(-hw * 0.45 + 60, -hd * 0.1 + i * 220 - 60, 5.6, 2.1, 1.9,
                yaw: 0.2, material: FacadeMaterial.whiteMetal),
            // The pipe rack out to the pump house at the tower.
            _block(85, -hd * 0.1 + i * 220, 430, 3, 3,
                z: 7, material: FacadeMaterial.steel),
            for (var q = 0; q < 11; q++)
              _block(-130 + q * 43, -hd * 0.1 + i * 220, 1, 1, 7,
                  material: FacadeMaterial.steel),
            _block(270, -hd * 0.2 + i * 220, 3, 110, 3,
                z: 7, material: FacadeMaterial.steel),
            _block(300, -hd * 0.3 + i * 220, 30, 16, 10,
                material: FacadeMaterial.whiteMetal),
            _tank(300, -hd * 0.3 + i * 220 + 30, 20, 8,
                material: FacadeMaterial.whiteMetal),
            _ring(300, -hd * 0.3 + i * 220 + 30, 20, 4, FacadeMaterial.safetyRed),
            // The tower: basin, legs, shell.
            _tank(hw * 0.55, -hd * 0.3 + i * 220, 130, 1.2,
                material: FacadeMaterial.precast),
            MassBox(
              x: hw * 0.55,
              y: -hd * 0.3 + i * 220,
              z: 14,
              width: 110,
              depth: 110,
              height: 128,
              glazed: false,
              shape: MassShape.hyperboloid,
              topScale: 0.62,
              material: FacadeMaterial.precast,
            ),
            for (var k = 0; k < 20; k++)
              _stack(
                  hw * 0.55 + math.cos(k / 20 * 2 * math.pi) * 51,
                  -hd * 0.3 + i * 220 + math.sin(k / 20 * 2 * math.pi) * 51,
                  1.8,
                  14,
                  top: 0.8,
                  material: FacadeMaterial.precast),
          ],
          ..._bandedStack(-hw * 0.6, -hd * 0.3, 5, 100),
          // The switchyard, and the line leaving it.
          _slab(hw * 0.05, -hd * 0.73, 240, 130),
          for (var i = 0; i < 5; i++) ..._gantry(hw * 0.05, -hd * 0.85 + i * 26, 200, 10),
          for (var i = 0; i < 4; i++)
            _block(hw * 0.05 - 75 + i * 50, -hd * 0.64, 8, 5, 6,
                material: FacadeMaterial.metalPanel),
          for (var i = 0; i < 3; i++)
            _stack(hw * 0.45 + i * 60, -hd * 0.85, 8, 48,
                top: 0.4, material: FacadeMaterial.steel),
          // The gate: guardhouse under a canopy, then the office row.
          _block(-hw * 0.71, -hd * 0.96, 8, 6, 4,
              material: FacadeMaterial.whiteMetal),
          _block(-hw * 0.69, -hd * 0.96, 18, 10, 0.5,
              z: 5, material: FacadeMaterial.industrialBlue),
          for (final (px, py) in const [(-8.0, -4.0), (8.0, -4.0), (-8.0, 4.0), (8.0, 4.0)])
            _block(-hw * 0.69 + px, -hd * 0.96 + py, 0.5, 0.5, 5,
                material: FacadeMaterial.steel),
          _vehicle(-hw * 0.69 + 12, -hd * 0.96, 5.5, 2.0, 2.4,
              yaw: math.pi / 2, material: FacadeMaterial.whiteMetal),
          _office(-hw * 0.78, -hd * 0.78, 60, 22, 3, storey),
          _sign(-hw * 0.78, -hd * 0.78 - 11.2, 12, 8, FacadeMaterial.industrialBlue),
          _office(-hw * 0.78, -hd * 0.67, 30, 15, 2, storey),
          _office(-hw * 0.89, -hd * 0.85, 40, 20, 2, storey),
          _block(-hw * 0.89, -hd * 0.72, 24, 14, 5,
              glazed: true, floors: 1, material: FacadeMaterial.whiteMetal),
          _shed(-hw * 0.89, -hd * 0.6, 30, 18, 7,
              material: FacadeMaterial.whiteMetal),
          _trim(-hw * 0.89, -hd * 0.6, 30, 18, 5, FacadeMaterial.safetyRed),
          _vehicle(-hw * 0.89, -hd * 0.6 - 16, 9, 2.5, 3.4,
              yaw: math.pi / 2, material: FacadeMaterial.safetyRed),
          _block(-hw * 0.89, -hd * 0.45, 40, 20, 8,
              material: FacadeMaterial.whiteMetal),
          _trim(-hw * 0.89, -hd * 0.45, 40, 20, 8, FacadeMaterial.industrialBlue),
          _shed(-hw * 0.78, -hd * 0.5, 50, 24, 9,
              material: FacadeMaterial.whiteMetal),
          _shed(-hw * 0.78, -hd * 0.3, 50, 24, 9,
              material: FacadeMaterial.whiteMetal),
          _trim(-hw * 0.78, -hd * 0.3, 50, 24, 6.5, FacadeMaterial.industrialBlue),
          _vehicle(-hw * 0.78 + 30, -hd * 0.3, 3, 1.6, 2.3,
              yaw: -0.5, material: FacadeMaterial.safetyYellow),
          _block(-hw * 0.89, -hd * 0.3, 30, 20, 8,
              material: FacadeMaterial.precast),
          for (var t = 0; t < 4; t++)
            _tank(-hw * 0.93 + t * 8, -hd * 0.25, 6, 8,
                material: FacadeMaterial.steel),
          _block(-hw * 0.89, -hd * 0.2, 12, 6, 4,
              material: FacadeMaterial.safetyYellow),
          _stack(-hw * 0.93, hd * 0.45, 1.2, 60,
              top: 0.6, material: FacadeMaterial.steel),
          _slab(-hw * 0.89, hd * 0.36, 24, 24, h: 0.3),
          // Fire water, the basin, the laydown yard and its crane.
          for (var i = 0; i < 3; i++) ...[
            _tank(-hw * 0.2 + i * 26, -hd * 0.45, 18, 14,
                material: FacadeMaterial.whiteMetal),
            _ring(-hw * 0.2 + i * 26, -hd * 0.45, 18, 7, FacadeMaterial.safetyRed),
          ],
          _slab(hw * 0.09, hd * 0.76, 80, 40, h: 0.4),
          _slab(hw * 0.43, hd * 0.76, 200, 110, h: 0.3),
          for (var r = 0; r < 4; r++)
            for (var c = 0; c < 6; c++) ...[
              _block(hw * 0.33 + c * 14, hd * 0.69 + r * 24, 12, 2.4, 2.6,
                  material: const [
                    FacadeMaterial.whiteMetal,
                    FacadeMaterial.industrialBlue,
                    FacadeMaterial.safetyRed,
                    FacadeMaterial.whiteMetal,
                  ][(r + c) % 4]),
              if (r < 2 && c.isEven)
                _block(hw * 0.33 + c * 14, hd * 0.69 + r * 24, 12, 2.4, 2.6,
                    z: 2.6, material: FacadeMaterial.whiteMetal),
            ],
          _stack(hw * 0.57, hd * 0.73, 2, 60,
              top: 0.9, material: FacadeMaterial.safetyYellow),
          _block(hw * 0.57 + 25, hd * 0.73, 50, 1.5, 1.5,
              z: 58, material: FacadeMaterial.safetyYellow),
          // The yard's machines and trucks.
          ..._excavator(hw * 0.5, hd * 0.86),
          for (var i = 0; i < 2; i++)
            _vehicle(hw * 0.36 + i * 12, hd * 0.86, 9, 2.6, 3.4,
                yaw: 0.15, material: FacadeMaterial.safetyYellow),
          _vehicle(hw * 0.24, hd * 0.6, 12, 2.5, 3.2,
              yaw: math.pi / 2, material: FacadeMaterial.whiteMetal),
          for (var i = 0; i < 3; i++)
            _vehicle(-hw * 0.72, -hd * 0.19 + i * 40, 5.6, 2.1, 1.9,
                yaw: math.pi / 2, material: FacadeMaterial.whiteMetal),
          // Lighting masts round the pads.
          for (final (mx, my) in const [
            (-0.86, -0.87), (-0.86, 0.55), (-0.14, 0.6), (0.29, 0.6),
            (0.74, 0.6), (0.74, -0.6), (0.29, -0.6), (-0.14, -0.6),
          ])
            _stack(mx * hw, my * hd, 0.8, 30, top: 0.6, material: FacadeMaterial.steel),
          // The protected area's own fence, and the site fence.
          for (final (x, y, fw, fd) in [
            (hw * 0.06, -hd * 0.55, nomW * 0.69, 0.12),
            (hw * 0.06, hd * 0.55, nomW * 0.69, 0.12),
            (-hw * 0.63, 0.0, 0.12, nomD * 0.55),
            (hw * 0.74, 0.0, 0.12, nomD * 0.55),
            (0.0, -hd + 6, nomW - 12, 0.15),
            (0.0, hd - 6, nomW - 12, 0.15),
            (-hw + 6, 0.0, 0.15, nomD - 12),
            (hw - 6, 0.0, 0.15, nomD - 12),
          ])
            MassBox(
                x: x,
                y: y,
                z: 0,
                width: fw,
                depth: fd,
                height: 2.6,
                glazed: false,
                material: FacadeMaterial.steel),
        ];
        floorArea = 60 * 22 * 3 + 30 * 15 * 2 + 40 * 20 * 2;
        parkW = 160;
      case 'fusion':
        nominal = [
          _tank(0, 0, 200, 12),
          _tank(0, 0, 160, 45, z: 12),
          _shed(-hw * 0.55, -hd * 0.35, nomW * 0.25, nomD * 0.16, 30),
          _shed(hw * 0.55, -hd * 0.35, nomW * 0.25, nomD * 0.16, 30),
          for (final (tx, ty) in [
            (-hw * 0.6, hd * 0.55),
            (-hw * 0.3, hd * 0.6),
            (hw * 0.3, hd * 0.6),
            (hw * 0.6, hd * 0.55),
          ])
            _stack(tx, ty, 120, 140, top: 0.55),
          for (var i = 0; i < 6; i++)
            _tank(-hw * 0.7 + i * 30, -hd * 0.72, 18, 30),
          _office(hw * 0.6, -hd * 0.75, 80, 26, 3, storey),
        ];
        floorArea = 80 * 26 * 3;
      case 'refinery':
        nominal = [
          // Tank farm on the far half, four by three.
          for (var i = 0; i < 4; i++)
            for (var j = 0; j < 3; j++)
              _tank(-hw * 0.72 + i * nomW * 0.16, -hd * 0.05 + j * nomD * 0.21,
                  48, 16),
          // The process area: columns, a flare, pipe racks.
          for (var i = 0; i < 6; i++)
            _stack(hw * 0.15 + i * 24, -hd * 0.55, 7, 55, top: 0.9),
          _stack(hw * 0.2, -hd * 0.25, 5, 70, top: 0.9),
          _stack(hw * 0.35, -hd * 0.25, 5, 70, top: 0.9),
          _stack(hw * 0.85, -hd * 0.8, 3, 95, top: 0.6),
          for (var i = 0; i < 3; i++)
            _block(hw * 0.4, -hd * 0.1 + i * nomD * 0.12, nomW * 0.5, 4, 6,
                z: 4),
          _shed(hw * 0.6, hd * 0.55, nomW * 0.28, nomD * 0.2, 12),
          _office(-hw * 0.7, -hd * 0.8, 40, 16, 2, storey),
        ];
        floorArea = 40 * 16 * 2;
      case 'steelmill':
        nominal = [
          for (var i = 0; i < 3; i++)
            _shed(-hw * 0.35, -hd * 0.55 + i * nomD * 0.28, nomW * 0.4,
                nomD * 0.18, 30),
          _stack(hw * 0.45, -hd * 0.5, 24, 75, top: 0.6),
          for (var i = 0; i < 4; i++)
            _tank(hw * 0.6 + i * 14, -hd * 0.5, 11, 45),
          for (var i = 0; i < 3; i++)
            _stack(hw * 0.35 + i * 30, hd * 0.05, 7, 100, top: 0.65),
          // Stockyard: ore and coal in long mounds.
          for (var i = 0; i < 3; i++)
            _stack(hw * 0.55, hd * 0.3 + i * nomD * 0.1, 200, 18, top: 0.15),
          _office(-hw * 0.8, -hd * 0.85, 40, 16, 2, storey),
        ];
        floorArea = 40 * 16 * 2 + nomW * 0.4 * nomD * 0.18 * 3;
      case 'datacenter':
        nominal = [
          for (var i = 0; i < 3; i++)
            _block(-hw * 0.2, -hd * 0.6 + i * nomD * 0.32, nomW * 0.55,
                nomD * 0.26, 14),
          for (var i = 0; i < 8; i++)
            _block(hw * 0.35, -hd * 0.8 + i * nomD * 0.1, 6, 3, 3.2),
          _block(hw * 0.7, -hd * 0.5, 14, 5, 5),
          _block(hw * 0.7, -hd * 0.35, 14, 5, 5),
          _tank(hw * 0.7, hd * 0.2, 8, 6),
          _tank(hw * 0.7, hd * 0.4, 8, 6),
          _office(-hw * 0.6, hd * 0.75, 50, 18, 2, storey),
        ];
        floorArea = nomW * 0.55 * nomD * 0.26 * 3;
      case 'assembly':
        nominal = [
          _block(-hw * 0.15, hd * 0.05, nomW * 0.5, nomD * 0.5, 105),
          _office(hw * 0.55, -hd * 0.6, 60, 24, 3, storey),
          _slab(0, -hd * 0.75, nomW * 0.4, nomD * 0.2),
        ];
        floorArea = 60 * 24 * 3 + nomW * 0.5 * nomD * 0.5;
      case 'base':
        nominal = [
          for (var r = 0; r < 2; r++)
            for (var i = 0; i < 4; i++)
              _block(-hw * 0.75 + i * nomW * 0.12, -hd * 0.6 + r * nomD * 0.12,
                  60, 14, storey * 2,
                  glazed: true, floors: 2),
          for (var i = 0; i < 3; i++)
            _shed(hw * 0.5, -hd * 0.6 + i * nomD * 0.16, 80, 50, 18),
          _slab(hw * 0.35, hd * 0.35, nomW * 0.5, nomD * 0.3),
          _stack(hw * 0.05, hd * 0.6, 8, 30, top: 0.7),
          _block(hw * 0.05, hd * 0.6, 12, 12, 5, z: 30, glazed: true, floors: 1),
          for (var i = 0; i < 4; i++)
            _tank(-hw * 0.7 + i * 22, hd * 0.7, 16, 10),
          _office(-hw * 0.5, hd * 0.1, 50, 20, 3, storey),
        ];
        floorArea = 60 * 14 * 2 * 8 + 50 * 20 * 3;
      case 'airfield':
        nominal = [
          _slab(-hw * 0.3, 0, 60, nomD * 0.94, h: 0.3),
          _slab(hw * 0.1, 0, 25, nomD * 0.9, h: 0.3),
          for (var i = 0; i < 3; i++)
            _shed(hw * 0.55, -hd * 0.3 + i * 70, 70, 50, 16),
          _stack(hw * 0.55, hd * 0.2, 8, 32, top: 0.75),
          _block(hw * 0.55, hd * 0.2, 12, 12, 5, z: 32, glazed: true, floors: 1),
          for (var i = 0; i < 3; i++)
            _tank(hw * 0.55, hd * 0.4 + i * 22, 16, 10),
          _office(hw * 0.55, hd * 0.65, 80, 24, 2, storey),
        ];
        floorArea = 80 * 24 * 2;
        parkW = 80;
      case 'spaceport':
        // A launch complex, the Cape's kind: each pad a raised concrete
        // mound with its flame trench, the launch mount and — on every
        // other pad — a vehicle on it, a steel service tower with its arm,
        // four lattice lightning masts with white tips at the corners, a
        // water tower, the LOX sphere and the propellant cylinders, a
        // blockhouse, a retention pond, a ring road and a crawlerway in
        // from the site's spine. Along the access side the support area:
        // the integration hangar and its apron, the tank farm, admin with
        // the car park, a tracking radome, containers, trucks, a crane,
        // and on the bigger sites an assembly building. Grass between: a
        // spaceport is roads and pads in a lot of nothing, not a plain of
        // concrete.
        final cols = nomW > 2500 ? 3 : (nomW > 1500 ? 2 : 1);
        final rows = nomD > 3500 ? 6 : (nomD > 2000 ? 4 : 1);
        final multi = cols * rows > 1;
        final supportD = multi ? 420.0 : 260.0;
        final cellW = nomW / cols, cellD = (nomD - supportD) / rows;
        final padR = math.min(cellW, cellD) * 0.42;
        final ps = (padR / 380).clamp(0.45, 1.0);
        List<MassBox> pad(double cx, double cy, {required bool manned}) => [
              // Ring road, and the crawlerway in from its front.
              _slab(cx, cy - padR * 0.9, padR * 1.8, 10, h: 0.5),
              _slab(cx, cy + padR * 0.9, padR * 1.8, 10, h: 0.5),
              _slab(cx - padR * 0.9, cy, 10, padR * 1.8, h: 0.5),
              _slab(cx + padR * 0.9, cy, 10, padR * 1.8, h: 0.5),
              _slab(cx, cy - padR * 0.45, 24, padR * 0.9, h: 0.6),
              // The mound: apron, deck, the trench and its exit.
              _block(cx, cy, 110 * ps, 110 * ps, 5 * ps,
                  material: FacadeMaterial.precast),
              _block(cx, cy, 70 * ps, 70 * ps, 4 * ps,
                  z: 5 * ps, material: FacadeMaterial.precast),
              _block(cx, cy, 14 * ps, 76 * ps, 0.6,
                  z: 9 * ps, material: FacadeMaterial.darkBrick),
              _block(cx, cy + 40 * ps, 14 * ps, 12 * ps, 6 * ps,
                  material: FacadeMaterial.darkBrick),
              // The launch mount, and the vehicle on it.
              _block(cx, cy - 6 * ps, 20 * ps, 20 * ps, 12 * ps,
                  z: 9 * ps, material: FacadeMaterial.steel),
              if (manned) ...[
                _tank(cx, cy - 6 * ps, 9 * ps, 70 * ps,
                    z: 21 * ps, material: FacadeMaterial.whiteMetal),
                _ring(cx, cy - 6 * ps, 9 * ps, 61 * ps, FacadeMaterial.safetyRed),
                _stack(cx, cy - 6 * ps, 9 * ps, 14 * ps,
                    top: 0.15, z: 91 * ps, material: FacadeMaterial.whiteMetal),
              ],
              // The service tower beside it, and its arm.
              _block(cx + 22 * ps, cy - 6 * ps, 12 * ps, 12 * ps, 130 * ps,
                  z: 9 * ps, material: FacadeMaterial.steel),
              _block(cx + 10 * ps, cy - 6 * ps, 14 * ps, 3 * ps, 3 * ps,
                  z: 95 * ps, material: FacadeMaterial.steel),
              // Lightning masts at the corners.
              for (final (mx, my) in const [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)]) ...[
                _stack(cx + mx * 75 * ps, cy + my * 75 * ps, 5 * ps, 150 * ps,
                    top: 0.35, material: FacadeMaterial.steel),
                _stack(cx + mx * 75 * ps, cy + my * 75 * ps, 1.4 * ps, 28 * ps,
                    top: 0.5, z: 150 * ps, material: FacadeMaterial.whiteMetal),
              ],
              // Water tower; the LOX sphere and the cylinders; the horizontals.
              _stack(cx - 120 * ps, cy + 90 * ps, 8 * ps, 40 * ps,
                  top: 0.9, material: FacadeMaterial.steel),
              _tank(cx - 120 * ps, cy + 90 * ps, 16 * ps, 12 * ps,
                  z: 40 * ps, material: FacadeMaterial.whiteMetal),
              _tank(cx + 120 * ps, cy + 90 * ps, 22 * ps, 22 * ps,
                  material: FacadeMaterial.whiteMetal),
              MassBox(
                x: cx + 120 * ps,
                y: cy + 90 * ps,
                z: 22 * ps,
                width: 22 * ps,
                depth: 22 * ps,
                height: 11 * ps,
                glazed: false,
                shape: MassShape.dome,
                material: FacadeMaterial.whiteMetal,
              ),
              for (var i = 0; i < 4; i++)
                _tank(cx + 96 * ps + i * 12 * ps, cy + 130 * ps, 9 * ps, 26 * ps,
                    material: FacadeMaterial.whiteMetal),
              for (var i = 0; i < 2; i++)
                _block(cx + 110 * ps + i * 16 * ps, cy + 158 * ps, 26 * ps, 5 * ps,
                    5 * ps,
                    material: FacadeMaterial.whiteMetal),
              // Blockhouse, pond, containers, a pickup, lighting masts.
              _block(cx - 110 * ps, cy - 110 * ps, 30 * ps, 20 * ps, 5 * ps,
                  material: FacadeMaterial.precast),
              _block(cx + 130 * ps, cy - 130 * ps, 50 * ps, 30 * ps, 0.3,
                  material: FacadeMaterial.industrialBlue),
              for (var i = 0; i < 3; i++)
                _block(cx - 60 * ps, cy - 130 * ps + i * 4, 12, 2.4, 2.6,
                    material: i.isEven
                        ? FacadeMaterial.whiteMetal
                        : FacadeMaterial.industrialBlue),
              _vehicle(cx - 90 * ps, cy - 125 * ps, 5.6, 2.1, 1.9,
                  yaw: 1.2, material: FacadeMaterial.whiteMetal),
              for (final (lx, ly) in const [(-0.7, -0.7), (0.7, -0.7), (0.0, 0.75)])
                _stack(cx + lx * padR, cy + ly * padR, 0.6, 22,
                    top: 0.6, material: FacadeMaterial.steel),
            ];
        nominal = [
          // The spine and the cross road through the support area.
          _slab(0, supportD / 2 - 20, 14, nomD - 40, h: 0.5),
          _slab(0, -hd + supportD * 0.55, nomW - 40, 14, h: 0.5),
          // Integration hangar and its apron, sign and trim.
          _shed(-hw * 0.3, -hd + supportD * 0.3, 150 * (multi ? 1.0 : 0.8),
              45 * (multi ? 1.0 : 0.8), 22,
              material: FacadeMaterial.whiteMetal),
          _trim(-hw * 0.3, -hd + supportD * 0.3, 150 * (multi ? 1.0 : 0.8),
              45 * (multi ? 1.0 : 0.8), 16, FacadeMaterial.industrialBlue),
          _sign(-hw * 0.3, -hd + supportD * 0.3 - 22.7 * (multi ? 1.0 : 0.8), 12, 10,
              FacadeMaterial.industrialBlue),
          _slab(-hw * 0.3, -hd + supportD * 0.3 + 60 * (multi ? 1.0 : 0.8),
              200 * (multi ? 1.0 : 0.7), 60),
          if (multi) ...[
            // The assembly building, and the crane at its door.
            _block(hw * 0.25, -hd + supportD * 0.4, 110, 90, 90,
                material: FacadeMaterial.whiteMetal),
            _trim(hw * 0.25, -hd + supportD * 0.4, 110, 90, 90,
                FacadeMaterial.industrialBlue),
            _block(hw * 0.25, -hd + supportD * 0.4 - 45.2, 40, 0.4, 70,
                z: 4, material: FacadeMaterial.industrialBlue),
            _stack(hw * 0.25 + 80, -hd + supportD * 0.4 - 60, 2, 70,
                top: 0.9, material: FacadeMaterial.safetyYellow),
            _block(hw * 0.25 + 105, -hd + supportD * 0.4 - 60, 50, 1.5, 1.5,
                z: 68, material: FacadeMaterial.safetyYellow),
          ],
          // The tank farm: a sphere, eight cylinders, three horizontals.
          _tank(hw * 0.62, -hd + supportD * 0.25, 30, 30,
              material: FacadeMaterial.whiteMetal),
          MassBox(
            x: hw * 0.62,
            y: -hd + supportD * 0.25,
            z: 30,
            width: 30,
            depth: 30,
            height: 15,
            glazed: false,
            shape: MassShape.dome,
            material: FacadeMaterial.whiteMetal,
          ),
          for (var i = 0; i < 4; i++)
            for (var j = 0; j < 2; j++)
              _tank(hw * 0.7 + i * 14, -hd + supportD * 0.25 + j * 16, 12, 32,
                  material: FacadeMaterial.whiteMetal),
          for (var i = 0; i < 3; i++)
            _block(hw * 0.7 + 20, -hd + supportD * 0.55 + i * 9, 34, 6, 6,
                material: FacadeMaterial.whiteMetal),
          // Admin with its car park, the radome, containers, trucks.
          _office(-hw * 0.75, -hd + 40, 60, 22, 2, storey),
          _sign(-hw * 0.75, -hd + 40 - 11.2, 10, 6, FacadeMaterial.industrialBlue),
          _tank(hw * 0.85, -hd + 50, 14, 6, material: FacadeMaterial.precast),
          MassBox(
            x: hw * 0.85,
            y: -hd + 50,
            z: 6,
            width: 14,
            depth: 14,
            height: 7,
            glazed: false,
            shape: MassShape.dome,
            material: FacadeMaterial.whiteMetal,
          ),
          for (var i = 0; i < 6; i++)
            _block(-hw * 0.55 + i * 15, -hd + 30, 12, 2.4, 2.6,
                material: i % 3 == 0
                    ? FacadeMaterial.industrialBlue
                    : FacadeMaterial.whiteMetal),
          _vehicle(-hw * 0.3, -hd + 30, 13, 2.6, 3.6,
              material: FacadeMaterial.whiteMetal),
          for (var i = 0; i < 3; i++)
            _vehicle(-hw * 0.75 + 40 + i * 7, -hd + 60, 5.6, 2.1, 1.9,
                yaw: math.pi / 2, material: FacadeMaterial.whiteMetal),
          // Two ponds, and the pads on their cells.
          _block(-hw * 0.85, -hd + supportD * 0.8, 60, 40, 0.3,
              material: FacadeMaterial.industrialBlue),
          for (var c = 0; c < cols; c++)
            for (var r = 0; r < rows; r++)
              ...pad(-hw + cellW * (c + 0.5), -hd + supportD + cellD * (r + 0.5),
                  manned: (c + r).isEven),
          for (final (x, y, fw, fd) in [
            (0.0, -hd + 6, nomW - 12, 0.15),
            (0.0, hd - 6, nomW - 12, 0.15),
            (-hw + 6, 0.0, 0.15, nomD - 12),
            (hw - 6, 0.0, 0.15, nomD - 12),
          ])
            MassBox(
                x: x,
                y: y,
                z: 0,
                width: fw,
                depth: fd,
                height: 2.6,
                glazed: false,
                material: FacadeMaterial.steel),
        ];
        floorArea = 60 * 22 * 2;
        parkW = 120;
      case 'terraformer':
        nominal = [
          _stack(0, 0, 70, 260, top: 0.35),
          _tank(0, 0, 120, 8, z: 40),
          _shed(-hw * 0.6, -hd * 0.6, nomW * 0.3, nomD * 0.2, 12),
          _shed(hw * 0.6, -hd * 0.6, nomW * 0.3, nomD * 0.2, 12),
        ];
        floorArea = nomW * 0.3 * nomD * 0.2 * 2;
      case 'water':
        nominal = [
          _tank(-nomW * 0.22, nomD * 0.15, nomW * 0.36, 5),
          _tank(nomW * 0.22, nomD * 0.15, nomW * 0.36, 5),
          _tank(nomW * 0.25, -nomD * 0.28, nomW * 0.22, 14),
          _office(-nomW * 0.25, -nomD * 0.3, nomW * 0.36, nomD * 0.28, 1,
              storey),
        ];
        floorArea = nomW * 0.36 * nomD * 0.28;
      case 'sewage':
        nominal = [
          for (var i = 0; i < 3; i++)
            _tank(-nomW * 0.33 + i * nomW * 0.33, nomD * 0.2, nomW * 0.28, 2.5),
          _tank(nomW * 0.28, -nomD * 0.28, nomW * 0.26, 12),
          _shed(-nomW * 0.22, -nomD * 0.28, nomW * 0.4, nomD * 0.3, 7),
        ];
        floorArea = nomW * 0.4 * nomD * 0.3;
      case 'silo2':
        nominal = [
          for (var i = 0; i < 3; i++)
            for (var j = 0; j < 2; j++)
              _tank(-nomW * 0.3 + i * nomW * 0.3, -nomD * 0.2 + j * nomD * 0.4,
                  nomW * 0.24, 28),
          _block(nomW * 0.42, 0, nomW * 0.12, nomD * 0.12, 40),
        ];
        floorArea = 0;
      case 'hydroponics':
        nominal = [
          for (var i = 0; i < 4; i++)
            _shed(-nomW * 0.36 + i * nomW * 0.24, nomD * 0.08, nomW * 0.2,
                nomD * 0.7, 6,
                glazed: true, floors: 1),
          _block(0, -nomD * 0.4, nomW * 0.6, nomD * 0.14, 5),
        ];
        floorArea = nomW * 0.2 * nomD * 0.7 * 4;
      case 'crematorium':
        nominal = [
          _office(-nomW * 0.1, 0, nomW * 0.6, nomD * 0.5, 2, storey),
          _stack(nomW * 0.35, nomD * 0.1, 3, 22, top: 0.7),
        ];
        floorArea = nomW * 0.6 * nomD * 0.5 * 2;
      case 'park':
        nominal = [
          _office(0, nomD * 0.15, math.min(12.0, nomW * 0.4),
              math.min(8.0, nomD * 0.3), 1, storey),
          for (final (tx, ty) in [
            (-0.35, -0.3),
            (0.35, -0.32),
            (-0.3, 0.35),
            (0.32, 0.36),
            (0.0, -0.1),
          ])
            _stack(tx * nomW, ty * nomD, math.min(7.0, nomW * 0.22), 9,
                top: 0.05),
        ];
        floorArea = 12 * 8;
      case 'cemetery':
        nominal = [
          _shed(-nomW * 0.3, -nomD * 0.3, math.min(14.0, nomW * 0.3),
              math.min(9.0, nomD * 0.3), 7,
              glazed: true, floors: 1),
          for (var i = 0; i < 6; i++)
            for (var j = 0; j < 4; j++)
              _block(-nomW * 0.35 + i * nomW * 0.14,
                  -nomD * 0.05 + j * nomD * 0.13, 1.0, 0.3, 1.1),
        ];
        floorArea = 14 * 9;
      case 'transit':
        nominal = [
          _block(0, 0, math.min(20.0, nomW * 0.8), math.min(6.0, nomD * 0.3),
              0.4,
              z: 4),
          for (final sx in const [-1.0, 1.0])
            _stack(sx * math.min(8.0, nomW * 0.32), 0, 0.5, 4, top: 1),
        ];
        floorArea = 0;
        parkW = 0;
      case 'warning':
        nominal = [
          _tank(0, nomD * 0.1, math.min(18.0, nomW * 0.5), 8),
          _stack(0, nomD * 0.1, math.min(18.0, nomW * 0.5), 9, top: 0.3, z: 8),
          _office(-nomW * 0.25, -nomD * 0.3, nomW * 0.4, nomD * 0.25, 1, storey),
        ];
        floorArea = nomW * 0.4 * nomD * 0.25;
      default:
        return null;
    }

    final volumes = _fit(nominal, k);
    return BuildingMassing(
      volumes: volumes,
      storeyM: storey,
      floorArea: floorArea * k * k,
      entrance: (0, -d / 2),
      style: style,
      parking: parkW > 0
          ? _lotFor(spec, math.min(w, parkW * k), frontY: -d / 2, volumes: volumes)
          : null,
    );
  }

  /// An excavation. The hole itself is terrain, cut by a stepped-pit brush; all
  /// that stands here is the plant around its rim.
  BuildingMassing _pit(CityBuildingSpec spec, double w, double d, double storey) {
    final volumes = <MassBox>[
      // Processing shed and ore bins, set back from the crest.
      MassBox(
        x: -w / 2 + math.min(60, w * 0.12),
        y: -d / 2 + math.min(50, d * 0.1),
        z: 0,
        width: math.min(90, w * 0.16),
        depth: math.min(60, d * 0.12),
        height: storey * 2,
        floors: 2,
      ),
      MassBox(
        x: -w / 2 + math.min(140, w * 0.22),
        y: -d / 2 + math.min(46, d * 0.09),
        z: 0,
        width: math.min(28, w * 0.05),
        depth: math.min(28, d * 0.05),
        height: 26,
        glazed: false,
      ),
      // Headframe, conveyor and stockpiles by the rim: what a working pit
      // looks like from above, and what a shed and a chimney alone do not.
      _stack(-w / 2 + math.min(200, w * 0.3), -d / 2 + math.min(50, d * 0.1),
          math.min(10, w * 0.03), math.min(40, w * 0.1),
          top: 0.55),
      _block(-w / 2 + math.min(230, w * 0.34), -d / 2 + math.min(70, d * 0.14),
          math.min(4, w * 0.02), math.min(120, d * 0.2), 4,
          z: 6),
      for (var i = 0; i < 3; i++)
        _stack(-w / 2 + math.min(60 + i * 44, w * (0.1 + i * 0.06)),
            -d / 2 + math.min(120, d * 0.24), math.min(38, w * 0.06),
            math.min(14, w * 0.03),
            top: 0.2),
    ];
    return BuildingMassing(
      volumes: volumes,
      storeyM: storey,
      floorArea: volumes.first.floorArea,
      entrance: (-w / 2, -d / 2),
      style: style,
      parking: _lotFor(spec, math.min(w, 160), frontY: -d / 2, volumes: volumes),
    );
  }

  /// A paved apron: hardstanding with a control tower beside it.
  BuildingMassing _apron(CityBuildingSpec spec, double w, double d, double storey) {
    final volumes = <MassBox>[
      // The apron itself — flat, but real geometry so it takes the pad's
      // material rather than showing bare regolith between the pads.
      MassBox(
        x: 0,
        y: 0,
        z: 0,
        width: w,
        depth: d,
        height: 0.25,
        glazed: false,
      ),
      MassBox(
        x: -w / 2 + 30,
        y: -d / 2 + 30,
        z: 0,
        width: 22,
        depth: 22,
        height: math.max(24.0, storey * 8),
        floors: 8,
      ),
    ];
    return BuildingMassing(
      volumes: volumes,
      storeyM: storey,
      floorArea: 22 * 22 * 8,
      entrance: (-w / 2 + 30, -d / 2),
      style: style,
      parking: _lotFor(spec, math.min(w, 240), frontY: -d / 2, volumes: volumes),
    );
  }

  /// A car park for a site whose building does not front a street.
  /// An installation's car park, INSIDE its plot: in the strip between the
  /// plot's front line [frontY] and the nearest of its [volumes], as deep
  /// as the spaces need and no deeper than that strip allows. Null when
  /// the strip is too shallow for a rank of bays.
  ///
  /// These used to be laid a fixed distance OUTSIDE the front line — the
  /// one place the plot does not own, and where the street it fronts is.
  ParkingLot? _lotFor(
    CityBuildingSpec spec,
    double w, {
    required double frontY,
    required List<MassBox> volumes,
    double clearM = 4,
  }) {
    final spaces = parkingSpaces(spec);
    if (spaces <= 0) return null;
    var reach = double.infinity;
    for (final v in volumes) {
      final front = v.y - v.depth / 2;
      if (front > frontY && front < reach) reach = front;
    }
    final room = (reach.isFinite ? reach : frontY + 60) - clearM - (frontY + clearM);
    if (room < 8) return null;
    final depth = (spaces * parkingSpaceM2 / math.max(20.0, w))
        .clamp(8.0, math.min(140.0, room))
        .toDouble();
    final y0 = frontY + clearM; // the lot's near edge
    return ParkingLot(
      x: 0,
      y: y0 + depth / 2,
      width: w,
      depth: depth,
      spaces: spaces,
      lampPosts: _lampGrid(w, depth, y0: y0),
    );
  }

  /// Lamp columns on a ~22 m grid — close enough that the pools of light on the
  /// tarmac overlap, which is what makes a car park read as lit rather than as
  /// a dark rectangle with dots on it.
  List<(double, double)> _lampGrid(double w, double d, {required double y0}) {
    final out = <(double, double)>[];
    final cols = math.max(1, (w / 22).round());
    final rows = math.max(1, (d / 22).round());
    for (var i = 0; i < cols; i++) {
      for (var j = 0; j < rows; j++) {
        out.add((
          -w / 2 + w * (i + 0.5) / cols,
          y0 + d * (j + 0.5) / rows,
        ));
      }
    }
    return out;
  }
}
