import 'package:acro_space_simulator/domain/colony/city_network.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a building adjacent to the hub via a road is connected', () {
    final net = CityNetwork(hub: 'depot');
    net.addRoad('depot', 'house-1');
    expect(net.isConnected('house-1'), isTrue);
  });

  test('a building with no road to the hub is disconnected', () {
    final net = CityNetwork(hub: 'depot');
    net.addRoad('shop-1', 'shop-2'); // a road, but not reaching the hub
    expect(net.isConnected('shop-1'), isFalse);
  });

  test('connectivity propagates along a chain of roads', () {
    final net = CityNetwork(hub: 'depot');
    net.addRoad('depot', 'a');
    net.addRoad('a', 'b');
    net.addRoad('b', 'c');
    expect(net.isConnected('c'), isTrue);
  });

  test('removing a road can sever downstream buildings', () {
    final net = CityNetwork(hub: 'depot');
    net.addRoad('depot', 'a');
    net.addRoad('a', 'b');
    expect(net.isConnected('b'), isTrue);
    net.removeRoad('depot', 'a');
    expect(net.isConnected('b'), isFalse);
  });

  test('the hub itself is always connected', () {
    final net = CityNetwork(hub: 'depot');
    expect(net.isConnected('depot'), isTrue);
  });

  test('connectedSet returns every reachable node', () {
    final net = CityNetwork(hub: 'depot');
    net.addRoad('depot', 'a');
    net.addRoad('a', 'b');
    net.addRoad('x', 'y'); // isolated
    final connected = net.connectedSet();
    expect(connected, containsAll(['depot', 'a', 'b']));
    expect(connected, isNot(contains('x')));
  });
}
