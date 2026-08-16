// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/craft/craft_design_codec.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_parts.dart';

/// A saved craft must come back as the same craft. Anything the codec drops —
/// a roll, a stage, a joint — shows up later as a vehicle that flies
/// differently from the one the player built.
void main() {
  const codec = CraftDesignCodec();
  final catalog = testCatalog();

  /// A design that exercises every field the codec carries: a mated stack, a
  /// free part off-axis and rotated, radial symmetry, and non-zero stages.
  CraftDesign nonTrivial() {
    final d = CraftDesign(name: 'Kestrel Mk3');
    d.addPart(def: testPod, instanceId: 'pod', stage: 2);
    d.attachPart(
      def: testTank(),
      instanceId: 'tank',
      toInstanceId: 'pod',
      parentNode: 'bottom',
      childNode: 'top',
      stage: 1,
    );
    d.attachPart(
      def: testEngine(),
      instanceId: 'engine',
      toInstanceId: 'tank',
      parentNode: 'bottom',
      childNode: 'top',
      roll: math.pi / 5,
      stage: 1,
    );
    d.attachRadial(
      def: testBlock,
      instanceIdPrefix: 'rcs',
      toInstanceId: 'tank',
      parentNode: 'skin',
      childNode: 'mount',
      count: 3,
      stage: 0,
    );
    // A part dropped in but not yet mated, off-axis and turned.
    d.addPart(
      def: testHull,
      instanceId: 'spare',
      position: const Vector3(3.5, -1.25, 0.75),
      rotation: Quaternion.axisAngle(const Vector3(1, 2, 3), 0.9),
    );
    return d;
  }

  test('a non-trivial design round-trips through JSON unchanged', () {
    final original = nonTrivial();
    final text = jsonEncode(codec.encode(original));
    final restored =
        codec.decode(jsonDecode(text) as Map<String, dynamic>, catalog: catalog);

    // The strongest statement available: re-encoding the restored design
    // produces byte-identical JSON.
    expect(jsonEncode(codec.encode(restored)), text);

    // ...and spelled out, so a failure says WHICH field was lost.
    expect(restored.name, original.name);
    expect(restored.rootId, original.rootId);
    expect(restored.partCount, original.partCount);
    for (var i = 0; i < original.partCount; i++) {
      final a = original.parts[i], b = restored.parts[i];
      expect(b.instanceId, a.instanceId);
      expect(b.def.id, a.def.id, reason: 'catalog binding for ${a.instanceId}');
      expect(b.position, a.position, reason: 'position of ${a.instanceId}');
      expect(b.stage, a.stage, reason: 'stage of ${a.instanceId}');
      expect(b.rotation.w, a.rotation.w, reason: 'qw of ${a.instanceId}');
      expect(b.rotation.x, a.rotation.x, reason: 'qx of ${a.instanceId}');
      expect(b.rotation.y, a.rotation.y, reason: 'qy of ${a.instanceId}');
      expect(b.rotation.z, a.rotation.z, reason: 'qz of ${a.instanceId}');
      expect(b.attachment?.parentInstanceId, a.attachment?.parentInstanceId);
      expect(b.attachment?.parentNode, a.attachment?.parentNode);
      expect(b.attachment?.childNode, a.attachment?.childNode);
    }
  });

  test('the attach tree survives, not just the coordinates', () {
    final restored = codec.decode(
        jsonDecode(jsonEncode(codec.encode(nonTrivial())))
            as Map<String, dynamic>,
        catalog: catalog);
    // Deleting the tank must still take the engine and all three blocks.
    expect(restored.remove('tank').toSet(),
        {'tank', 'engine', 'rcs-0', 'rcs-1', 'rcs-2'});
    expect(restored.partCount, 2, reason: 'pod and the free spare remain');
  });

  test('the file carries a schema version and refuses a newer one', () {
    final json = codec.encode(nonTrivial());
    expect(json['schema'], CraftDesignCodec.schemaVersion);

    json['schema'] = CraftDesignCodec.schemaVersion + 1;
    expect(() => codec.decode(json, catalog: catalog),
        throwsA(isA<FormatException>()));
  });

  test('defaults are omitted and read back as defaults', () {
    final d = CraftDesign(name: 'Plain');
    d.addPart(def: testPod, instanceId: 'pod');
    final part = (codec.encode(d)['parts'] as List).first as Map;
    expect(part.containsKey('q'), isFalse,
        reason: 'an unrotated part should not write a quaternion');
    expect(part.containsKey('stage'), isFalse);
    expect(part.containsKey('att'), isFalse);

    // A hand-written file with only the required keys still loads.
    final sparse = codec.decode({
      'schema': 1,
      'name': 'Sparse',
      'parts': [
        {'id': 'pod', 'def': 'test-pod', 'p': [0, 0, 0]}
      ],
    }, catalog: catalog);
    final loaded = sparse.parts.single;
    expect(loaded.stage, 0);
    expect(loaded.rotation.w, 1);
    expect(loaded.attachment, isNull);
    expect(sparse.rootId, 'pod', reason: 'a file with no root picks one');
  });

  test('an attachment that points forward in the list still loads', () {
    // The editor can re-parent an early part onto a later one, so the codec
    // must not assume parents are written first.
    final d = codec.decode({
      'schema': 1,
      'name': 'Backwards',
      'root': 'hull',
      'parts': [
        {
          'id': 'engine',
          'def': 'test-engine',
          'p': [0, 0, -1.5],
          'att': {'parent': 'hull', 'pn': 'bottom', 'cn': 'top'},
        },
        {'id': 'hull', 'def': 'test-hull', 'p': [0, 0, 0]},
      ],
    }, catalog: catalog);
    expect(d.rootId, 'hull');
    expect(d.childrenOf('hull').single.instanceId, 'engine');
  });

  test('an unknown catalog part is refused, not silently dropped', () {
    expect(
      () => codec.decode({
        'schema': 1,
        'name': 'Ghost',
        'parts': [
          {'id': 'x', 'def': 'no-such-part', 'p': [0, 0, 0]}
        ],
      }, catalog: catalog),
      throwsA(isA<FormatException>()),
    );
  });

  test('a file describing an impossible tree is rejected on load', () {
    expect(
      () => codec.decode({
        'schema': 1,
        'name': 'Loop',
        'parts': [
          {
            'id': 'a',
            'def': 'test-hull',
            'p': [0, 0, 0],
            'att': {'parent': 'b', 'pn': 'bottom', 'cn': 'top'},
          },
          {
            'id': 'b',
            'def': 'test-hull',
            'p': [0, 0, -2],
            'att': {'parent': 'a', 'pn': 'bottom', 'cn': 'top'},
          },
        ],
      }, catalog: catalog),
      throwsA(isA<StateError>()),
    );
  });

  test('a nameless or partless file is rejected', () {
    expect(() => codec.decode({'schema': 1, 'parts': []}, catalog: catalog),
        throwsA(isA<FormatException>()));
    expect(() => codec.decode({'schema': 1, 'name': 'X'}, catalog: catalog),
        throwsA(isA<FormatException>()));
  });
}
