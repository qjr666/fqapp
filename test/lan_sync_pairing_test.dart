import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/lan_sync_pairing.dart';
import 'package:fqapp/services/lan_sync_preferences.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/services/sync_agent.dart' show SyncException;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

LanSyncPairing buildPairing(http.Client client, SecureKeyStorage storage) =>
    LanSyncPairing(
      client: client,
      storage: storage,
      preferences: LanSyncPreferences.instance,
      localBaseUrlOverride: 'http://127.0.0.1:12345',
      localCapabilityOverride: 'local-token',
      deviceIdOverride: 'device-a',
      deviceNameOverride: 'mine',
      platformOverride: 'android',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LanSyncPreferences.instance.resetForTest();
  });

  test('the host issues a code with its own capability', () async {
    String? seenAuth;
    String? seenPath;
    final client = MockClient((request) async {
      seenAuth = request.headers['authorization'];
      seenPath = request.url.path;
      return http.Response(
        jsonEncode({
          'success': true,
          'code': '042317',
          'expiresAt': 1234,
          'ttlSeconds': 60,
        }),
        200,
      );
    });
    final pairing = buildPairing(client, InMemorySecureKeyStorage());
    addTearDown(pairing.close);

    final code = await pairing.issueCode();
    expect(code.code, '042317');
    expect(code.expiresAt, 1234);
    expect(code.ttlSeconds, 60);
    expect(seenAuth, 'Bearer local-token');
    expect(seenPath, '/api/v1/sync/pair/code');
  });

  test('a peer exchanges a code for a secret held in secure storage', () async {
    Map<String, String>? headers;
    Map<String, dynamic>? body;
    String? seenPath;
    final client = MockClient((request) async {
      headers = request.headers;
      seenPath = request.url.path;
      body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      return http.Response(
        jsonEncode({
          'success': true,
          'secret': 'ab' * 32,
          'device': {
            'id': 'device-a',
            'name': 'mine',
            'platform': 'android',
            'pairedAt': 42,
          },
        }),
        200,
      );
    });
    final storage = InMemorySecureKeyStorage();
    final pairing = buildPairing(client, storage);
    addTearDown(pairing.close);

    final peer = await pairing.pairWithPeer(
      peerBaseUrl: 'http://192.168.1.9:8080/',
      code: ' 042317 ',
    );
    expect(peer.secret, 'ab' * 32);
    expect(peer.address, 'http://192.168.1.9:8080');
    expect(peer.deviceId, 'device-a');
    expect(seenPath, '/api/v1/sync/pair');
    // The code in the body is the credential; no capability is sent yet.
    expect(headers!['authorization'], isNull);
    expect(body!['code'], '042317');
    expect(body!['device']['id'], 'device-a');
    expect(body!['device']['name'], 'mine');
    expect(body!['device']['platform'], 'android');

    expect(await storage.read(LanSyncPairing.secretKey), isNotNull);
    final loaded = await pairing.loadPaired();
    expect(loaded!.secret, 'ab' * 32);
    expect(loaded.address, 'http://192.168.1.9:8080');

    await pairing.clearPaired();
    expect(await pairing.loadPaired(), isNull);
  });

  test('pairing failures are translated into readable messages', () async {
    for (final entry in <(int, String)>[
      (400, '配对码不正确'),
      (401, '配对码不正确'),
      (410, '配对码已过期'),
      (429, '尝试次数过多'),
      (404, '对方版本不支持配对'),
    ]) {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'success': false, 'error': 'invalid pairing code'}),
          entry.$1,
        ),
      );
      final pairing = buildPairing(client, InMemorySecureKeyStorage());
      addTearDown(pairing.close);
      await expectLater(
        pairing.pairWithPeer(
          peerBaseUrl: 'http://192.168.1.9:8080',
          code: '123456',
        ),
        throwsA(
          isA<SyncException>().having(
            (error) => error.message,
            'message',
            contains(entry.$2),
          ),
        ),
      );
    }
  });

  test('the host list and revocation use the local capability', () async {
    final paths = <String>[];
    final auths = <String?>[];
    String? revokeBody;
    final client = MockClient((request) async {
      paths.add('${request.method} ${request.url.path}');
      auths.add(request.headers['authorization']);
      if (request.url.path.endsWith('/hosts')) {
        return http.Response(
          jsonEncode({
            'success': true,
            'devices': [
              {
                'id': 'device-b',
                'name': 'peer',
                'platform': 'ios',
                'pairedAt': 7,
              },
            ],
          }),
          200,
        );
      }
      revokeBody = request.body;
      return http.Response('{"success":true}', 200);
    });
    final pairing = buildPairing(client, InMemorySecureKeyStorage());
    addTearDown(pairing.close);

    final hosts = await pairing.hosts();
    expect(hosts, hasLength(1));
    expect(hosts.single.id, 'device-b');
    expect(hosts.single.name, 'peer');
    expect(hosts.single.platform, 'ios');
    expect(hosts.single.pairedAt, 7);

    await pairing.revoke('device-b');
    expect(paths, [
      'GET /api/v1/sync/hosts',
      'POST /api/v1/sync/hosts/revoke',
    ]);
    expect(auths, ['Bearer local-token', 'Bearer local-token']);
    expect(jsonDecode(revokeBody!)['deviceId'], 'device-b');
  });

  test('a corrupt stored entry is treated as unpaired', () async {
    final storage = InMemorySecureKeyStorage();
    await storage.write(LanSyncPairing.secretKey, 'not json');
    final pairing = buildPairing(
      MockClient((_) async => http.Response('{}', 200)),
      storage,
    );
    addTearDown(pairing.close);
    expect(await pairing.loadPaired(), isNull);
    expect(PairedPeer.decode('{"address":"","secret":"x"}'), isNull);
  });

  test('missing inputs and malformed addresses are refused locally', () async {
    final pairing = buildPairing(
      MockClient((_) async => http.Response('{}', 200)),
      InMemorySecureKeyStorage(),
    );
    addTearDown(pairing.close);
    await expectLater(
      pairing.pairWithPeer(peerBaseUrl: '', code: '123456'),
      throwsA(isA<SyncException>()),
    );
    await expectLater(
      pairing.pairWithPeer(peerBaseUrl: 'not-a-url', code: '123456'),
      throwsA(isA<SyncException>()),
    );
  });
}
