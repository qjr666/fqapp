import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/lan_discovery_service.dart';
import 'package:fqapp/services/lan_sync_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

LanDiscoveryService buildService({
  required List<({List<int> bytes, String address, int port})> sent,
  String id = 'device-a',
  List<String>? broadcastAddresses,
}) => LanDiscoveryService(
  preferences: LanSyncPreferences.instance,
  httpPortOverride: 8080,
  deviceIdOverride: id,
  deviceNameOverride: 'mine',
  platformOverride: 'android',
  broadcastAddressesOverride: broadcastAddresses ?? const ['192.168.1.255'],
  sendOverride: (bytes, address, port) {
    sent.add((bytes: bytes, address: address.address, port: port));
  },
);

DiscoveryMessage? lastSent(
  List<({List<int> bytes, String address, int port})> sent,
) => DiscoveryMessage.decode(sent.last.bytes);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LanSyncPreferences.instance.resetForTest();
  });

  test('probe and reply datagrams round-trip', () {
    for (final kind in [DiscoveryMessage.probe, DiscoveryMessage.reply]) {
      final message = DiscoveryMessage(
        kind: kind,
        id: 'device-b',
        name: 'peer phone',
        platform: 'ios',
        port: 8080,
      );
      final decoded = DiscoveryMessage.decode(message.encode());
      expect(decoded, isNotNull);
      expect(decoded!.kind, kind);
      expect(decoded.id, 'device-b');
      expect(decoded.name, 'peer phone');
      expect(decoded.platform, 'ios');
      expect(decoded.port, 8080);
    }
  });

  test('malformed or foreign datagrams are ignored', () {
    final valid = DiscoveryMessage(
      kind: DiscoveryMessage.probe,
      id: 'device-b',
      name: 'peer',
      platform: 'ios',
      port: 8080,
    ).toJson();
    final cases = <Map<String, dynamic>>[
      {...valid, 'format': 'something-else'},
      {...valid, 'version': 2},
      {...valid, 'kind': 'announce'},
      {...valid, 'device': null},
      {...valid, 'port': 0},
      {...valid, 'port': '8080'},
    ];
    for (final value in cases) {
      expect(
        DiscoveryMessage.decode(utf8.encode(jsonEncode(value))),
        isNull,
        reason: 'should ignore $value',
      );
    }
    expect(DiscoveryMessage.decode(const [0xff, 0xfe, 0xfd]), isNull);
    expect(
      DiscoveryMessage.decode(Uint8List(DiscoveryMessage.maxBytes + 1)),
      isNull,
    );
  });

  test('a probe from a peer is answered with a unicast reply', () async {
    final sent = <({List<int> bytes, String address, int port})>[];
    final service = buildService(sent: sent);
    addTearDown(service.dispose);

    service.handleMessage(
      DiscoveryMessage(
        kind: DiscoveryMessage.probe,
        id: 'device-b',
        name: 'peer',
        platform: 'ios',
        port: 9090,
      ),
      InternetAddress('192.168.1.9'),
    );

    expect(sent, hasLength(1));
    expect(sent.single.address, '192.168.1.9');
    expect(sent.single.port, LanDiscoveryService.defaultPort);
    final reply = lastSent(sent);
    expect(reply!.kind, DiscoveryMessage.reply);
    expect(reply.id, 'device-a');
    expect(reply.name, 'mine');
    expect(reply.platform, 'android');
    expect(reply.port, 8080);
    expect(service.current, isEmpty);
  });

  test('replies are collected, de-duplicated and exclude this device',
      () async {
    final sent = <({List<int> bytes, String address, int port})>[];
    final service = buildService(sent: sent);
    addTearDown(service.dispose);
    final seen = <List<DiscoveredDevice>>[];
    final sub = service.devices.listen(seen.add);
    addTearDown(sub.cancel);

    const peer = DiscoveryMessage(
      kind: DiscoveryMessage.reply,
      id: 'device-b',
      name: 'peer',
      platform: 'ios',
      port: 9090,
    );
    service.handleMessage(peer, InternetAddress('192.168.1.9'));
    service.handleMessage(peer, InternetAddress('192.168.1.9'));
    service.handleMessage(
      const DiscoveryMessage(
        kind: DiscoveryMessage.reply,
        id: 'device-a',
        name: 'mine',
        platform: 'android',
        port: 8080,
      ),
      InternetAddress('192.168.1.9'),
    );

    await Future<void>.delayed(Duration.zero);
    expect(service.current, hasLength(1));
    expect(seen.last.single.id, 'device-b');
    expect(seen.last.single.baseUrl, 'http://192.168.1.9:9090');
    expect(sent, isEmpty); // replies never trigger a reply

    // A later reply from the same id refreshes its address.
    service.handleMessage(peer, InternetAddress('192.168.1.20'));
    expect(service.current.single.address, '192.168.1.20');

    service.reset();
    expect(service.current, isEmpty);
  });

  test('probing sends a probe datagram to every broadcast address', () async {
    final sent = <({List<int> bytes, String address, int port})>[];
    final service = buildService(
      sent: sent,
      broadcastAddresses: const ['255.255.255.255', '192.168.1.255'],
    );
    addTearDown(service.dispose);

    await service.probe();
    expect(sent.map((entry) => entry.address), [
      '255.255.255.255',
      '192.168.1.255',
    ]);
    for (final entry in sent) {
      final message = DiscoveryMessage.decode(entry.bytes);
      expect(message!.kind, DiscoveryMessage.probe);
      expect(message.id, 'device-a');
      expect(entry.port, LanDiscoveryService.defaultPort);
    }
  });

  test('iOS 上只发定向广播：全局广播在 iPhone 上发不出去', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final sent = <({List<int> bytes, String address, int port})>[];
    final service = LanDiscoveryService(
      preferences: LanSyncPreferences.instance,
      httpPortOverride: 8080,
      deviceIdOverride: 'device-a',
      deviceNameOverride: 'mine',
      platformOverride: 'ios',
      sendOverride: (bytes, address, port) {
        sent.add((bytes: bytes, address: address.address, port: port));
      },
    );
    addTearDown(service.dispose);

    await service.probe();
    expect(sent, isNotEmpty);
    expect(sent.map((entry) => entry.address), isNot(contains('255.255.255.255')));
  });
}
