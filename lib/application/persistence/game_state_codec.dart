import '../../domain/autonomy/flight_plan.dart';
import '../../domain/dynamics/state_vector.dart';
import '../../domain/lifesupport/crew.dart';
import '../../domain/mining/mining_operation.dart';
import '../../domain/mining/mining_rig.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/simulation/epoch.dart';
import '../../domain/simulation/simulation_clock.dart';
import '../../domain/thermal/thermal_state.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/vessel/part.dart';
import '../../domain/vessel/resource_container.dart';
import '../../domain/vessel/stage.dart';
import '../../domain/vessel/vessel.dart';
import '../ports/repositories.dart';
import '../ports/world_repositories.dart';

/// Serializes the mutable game state to/from plain JSON-able maps for save/load.
///
/// Persists the DYNAMIC state — vessel kinematics + resources + staging, colony
/// population + stockpile, deposit reserves, and the clock. The static universe
/// (bodies, gravity) is reference data rebuilt from the system definition, not
/// saved. Pure mapping; the actual file/byte IO is an infrastructure concern.
///
/// Schema is explicit and versioned so saves survive code changes.
class GameStateCodec {
  static const int schemaVersion = 1;
  const GameStateCodec();

  // ---------------- encode ----------------

  Map<String, dynamic> encode({
    required VesselRepository vessels,
    required ColonyRepository colonies,
    required DepositRepository deposits,
    required SimulationClock clock,
  }) {
    return {
      'version': schemaVersion,
      'clock': {
        'tick': clock.tick,
        'epoch': clock.epoch.seconds,
        'warp': clock.warpFactor,
        'fixedStep': clock.fixedStep,
      },
      'vessels': [for (final v in vessels.all()) _vessel(v)],
      'colonies': [for (final c in colonies.all()) _colony(c)],
      'deposits': [for (final d in deposits.all()) _deposit(d)],
    };
  }

  Map<String, dynamic> _vessel(Vessel v) => {
        'id': v.id.value,
        'name': v.name,
        'owner': v.ownerId,
        'body': v.dominantBody.value,
        'landed': v.landed,
        'throttle': v.throttle,
        'state': _state(v.state),
        'stages': [
          for (final s in v.stages)
            {
              'index': s.index,
              'parts': [for (final p in s.parts) _part(p)],
            }
        ],
        'thermal': [for (final t in v.thermal) _thermal(t)],
        if (v.flightPlan != null) 'flightPlan': _flightPlan(v.flightPlan!),
        if (v.crew != null) 'crew': _crew(v.crew!),
        if (v.mining != null) 'mining': _mining(v.mining!),
      };

  Map<String, dynamic> _crew(CrewModule c) => {
        'count': c.count,
        'food': c.foodPerCrewPerSecond,
        'oxygen': c.oxygenPerCrewPerSecond,
        'water': c.waterPerCrewPerSecond,
      };

  Map<String, dynamic> _mining(MiningOperation m) => {
        'depositId': m.depositId,
        'target': m.targetType.name,
        'rig': {
          'id': m.rig.id,
          'baseRate': m.rig.baseRate,
          'powerDraw': m.rig.powerDraw,
          'active': m.rig.active,
        },
      };

  Map<String, dynamic> _thermal(PartThermalState t) => {
        'part': t.part.value,
        'temperature': t.temperature,
        'heatCapacity': t.heatCapacity,
        'maxTemperature': t.maxTemperature,
        'emissivity': t.emissivity,
        'surfaceArea': t.surfaceArea,
      };

  Map<String, dynamic> _flightPlan(FlightPlan plan) => {
        'currentLeg': plan.currentLegIndex,
        'legs': [
          for (final leg in plan.legs)
            {
              'targetBody': leg.targetBody.value,
              'targetAltitude': leg.targetAltitude,
              'dockWith': leg.dockWith?.value,
              'nodes': [
                for (final n in leg.nodes)
                  {
                    'executeAt': n.executeAt.seconds,
                    'dv': [n.deltaV.x, n.deltaV.y, n.deltaV.z],
                  }
              ],
            }
        ],
      };

  Map<String, dynamic> _state(StateVector s) => {
        'p': [s.position.x, s.position.y, s.position.z],
        'v': [s.velocity.x, s.velocity.y, s.velocity.z],
        'q': [s.attitude.w, s.attitude.x, s.attitude.y, s.attitude.z],
        'w': [s.angularVelocity.x, s.angularVelocity.y, s.angularVelocity.z],
      };

  Map<String, dynamic> _part(Part p) => {
        'id': p.id.value,
        'name': p.name,
        'dryMass': p.dryMass,
        'pos': [p.positionInVessel.x, p.positionInVessel.y, p.positionInVessel.z],
        'inertia': [p.inertiaContribution.x, p.inertiaContribution.y, p.inertiaContribution.z],
        'maxTemp': p.maxTemperature,
        'cd': p.dragCoefficient,
        'area': p.crossSectionArea,
        'resources': [
          for (final r in p.resources)
            {
              'type': r.type.name,
              'capacity': r.capacity,
              'amount': r.amount,
              'unitMass': r.unitMass,
            }
        ],
      };

  Map<String, dynamic> _colony(dynamic c) => {
        'id': c.id,
        'population': c.population,
        'stockpile': {
          for (final entry in (c.stockpile as Map).entries)
            (entry.key as ResourceType).name: {
              'capacity': entry.value.capacity,
              'amount': entry.value.amount,
              'unitMass': entry.value.unitMass,
            }
        },
      };

  Map<String, dynamic> _deposit(dynamic d) => {
        'id': d.id,
        'reserves': d.reserves,
      };

  // ---------------- decode ----------------

  void decode(
    Map<String, dynamic> json, {
    required VesselRepository vessels,
    required ColonyRepository colonies,
    required DepositRepository deposits,
    required SimulationClock clock,
  }) {
    final clockJson = json['clock'] as Map<String, dynamic>;
    clock.tick = clockJson['tick'] as int;
    clock.epoch = Epoch((clockJson['epoch'] as num).toDouble());
    clock.warpFactor = (clockJson['warp'] as num).toDouble();

    for (final vj in (json['vessels'] as List)) {
      vessels.save(_decodeVessel(vj as Map<String, dynamic>));
    }

    // Colonies/deposits are mutated in place on existing instances (they keep
    // their static building/spec definitions), matched by id.
    final colonyById = {for (final c in colonies.all()) c.id: c};
    for (final cj in (json['colonies'] as List)) {
      final m = cj as Map<String, dynamic>;
      final c = colonyById[m['id']];
      if (c == null) continue;
      c.population = m['population'] as int;
      final sp = m['stockpile'] as Map<String, dynamic>;
      for (final entry in (c.stockpile as Map).entries) {
        final saved = sp[(entry.key as ResourceType).name];
        if (saved != null) {
          entry.value.amount = (saved['amount'] as num).toDouble();
        }
      }
      colonies.save(c);
    }

    final depositById = {for (final d in deposits.all()) d.id: d};
    for (final dj in (json['deposits'] as List)) {
      final m = dj as Map<String, dynamic>;
      final d = depositById[m['id']];
      if (d == null) continue;
      final res = m['reserves'];
      d.reserves = res == null ? null : (res as num).toDouble();
    }
  }

  Vessel _decodeVessel(Map<String, dynamic> m) {
    final stages = <Stage>[
      for (final sj in (m['stages'] as List))
        Stage(
          index: (sj as Map<String, dynamic>)['index'] as int,
          parts: [for (final pj in (sj['parts'] as List)) _decodePart(pj as Map<String, dynamic>)],
        ),
    ];
    final thermal = <PartThermalState>[
      for (final tj in (m['thermal'] as List? ?? const []))
        _decodeThermal(tj as Map<String, dynamic>),
    ];
    final v = Vessel(
      id: VesselId(m['id'] as String),
      name: m['name'] as String,
      ownerId: m['owner'] as String,
      state: _decodeState(m['state'] as Map<String, dynamic>),
      dominantBody: BodyId(m['body'] as String),
      stages: stages,
      landed: m['landed'] as bool,
      thermal: thermal,
    );
    v.setThrottle((m['throttle'] as num).toDouble());
    final planJson = m['flightPlan'];
    if (planJson != null) {
      v.flightPlan = _decodeFlightPlan(v.id, planJson as Map<String, dynamic>);
    }
    final crewJson = m['crew'];
    if (crewJson != null) {
      final cj = crewJson as Map<String, dynamic>;
      v.crew = CrewModule(
        count: cj['count'] as int,
        foodPerCrewPerSecond: (cj['food'] as num).toDouble(),
        oxygenPerCrewPerSecond: (cj['oxygen'] as num).toDouble(),
        waterPerCrewPerSecond: (cj['water'] as num).toDouble(),
      );
    }
    final miningJson = m['mining'];
    if (miningJson != null) {
      final mj = miningJson as Map<String, dynamic>;
      final rj = mj['rig'] as Map<String, dynamic>;
      v.mining = MiningOperation(
        rig: MiningRig(
          id: rj['id'] as String,
          baseRate: (rj['baseRate'] as num).toDouble(),
          powerDraw: (rj['powerDraw'] as num).toDouble(),
          active: rj['active'] as bool,
        ),
        depositId: mj['depositId'] as String,
        targetType: ResourceType.values.byName(mj['target'] as String),
      );
    }
    return v;
  }

  PartThermalState _decodeThermal(Map<String, dynamic> m) => PartThermalState(
        part: PartId(m['part'] as String),
        temperature: (m['temperature'] as num).toDouble(),
        heatCapacity: (m['heatCapacity'] as num).toDouble(),
        maxTemperature: (m['maxTemperature'] as num).toDouble(),
        emissivity: (m['emissivity'] as num).toDouble(),
        surfaceArea: (m['surfaceArea'] as num).toDouble(),
      );

  FlightPlan _decodeFlightPlan(VesselId vessel, Map<String, dynamic> m) {
    final legs = <FlightLeg>[
      for (final lj in (m['legs'] as List))
        FlightLeg(
          targetBody: BodyId((lj as Map<String, dynamic>)['targetBody'] as String),
          targetAltitude: (lj['targetAltitude'] as num).toDouble(),
          dockWith: lj['dockWith'] == null ? null : VesselId(lj['dockWith'] as String),
          nodes: [
            for (final nj in (lj['nodes'] as List))
              ManeuverNode(
                executeAt: Epoch(((nj as Map<String, dynamic>)['executeAt'] as num).toDouble()),
                deltaV: () {
                  final dv = (nj['dv'] as List).cast<num>();
                  return Vector3(dv[0].toDouble(), dv[1].toDouble(), dv[2].toDouble());
                }(),
              ),
          ],
        ),
    ];
    return FlightPlan(
      vessel: vessel,
      legs: legs,
      currentLegIndex: (m['currentLeg'] as num).toInt(),
    );
  }

  StateVector _decodeState(Map<String, dynamic> m) {
    final p = (m['p'] as List).cast<num>();
    final v = (m['v'] as List).cast<num>();
    final q = (m['q'] as List).cast<num>();
    final w = (m['w'] as List).cast<num>();
    return StateVector(
      position: Vector3(p[0].toDouble(), p[1].toDouble(), p[2].toDouble()),
      velocity: Vector3(v[0].toDouble(), v[1].toDouble(), v[2].toDouble()),
      attitude: Quaternion(
          q[0].toDouble(), q[1].toDouble(), q[2].toDouble(), q[3].toDouble()),
      angularVelocity:
          Vector3(w[0].toDouble(), w[1].toDouble(), w[2].toDouble()),
    );
  }

  Part _decodePart(Map<String, dynamic> m) {
    final pos = (m['pos'] as List).cast<num>();
    final inertia = (m['inertia'] as List).cast<num>();
    return Part(
      id: PartId(m['id'] as String),
      name: m['name'] as String,
      dryMass: (m['dryMass'] as num).toDouble(),
      positionInVessel:
          Vector3(pos[0].toDouble(), pos[1].toDouble(), pos[2].toDouble()),
      inertiaContribution: Vector3(
          inertia[0].toDouble(), inertia[1].toDouble(), inertia[2].toDouble()),
      maxTemperature: (m['maxTemp'] as num).toDouble(),
      dragCoefficient: (m['cd'] as num).toDouble(),
      crossSectionArea: (m['area'] as num).toDouble(),
      resources: [
        for (final rj in (m['resources'] as List))
          _decodeResource(rj as Map<String, dynamic>)
      ],
    );
  }

  ResourceContainer _decodeResource(Map<String, dynamic> m) => ResourceContainer(
        type: ResourceType.values.byName(m['type'] as String),
        capacity: (m['capacity'] as num).toDouble(),
        amount: (m['amount'] as num).toDouble(),
        unitMass: (m['unitMass'] as num).toDouble(),
      );
}
