import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/sync_envelope.dart';
import 'package:fqapp/services/lan_sync_preferences.dart';
import 'package:fqapp/services/sync_agent.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

LibraryBackup emptyBackup() => LibraryBackup.decode(
  Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': 'fqapp.library-backup',
        'version': 1,
        'createdAt': 1000,
        'shelf': [],
        'history': [],
        'watched': [],
        'excludedLocalRecords': 0,
      }),
    ),
  ),
);

SyncEnvelope peerEnvelope() => SyncEnvelope(
  device: const SyncDevice(id: 'device-b', name: 'peer', platform: 'ios'),
  sentAt: 2000,
  backup: emptyBackup(),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LanSyncPreferences.instance.resetForTest();
  });

  test('one sync publishes, pulls, merges, pushes and drains the inbox', () async {
    final seen = <String>[];
    final applied = <LibraryBackup>[];
    final client = MockClient((request) async {
      seen.add(
        '${request.method} ${request.url.host} ${request.url.path} '
        '${request.headers['authorization']}',
      );
      switch (request.url.path) {
        case '/api/v1/sync/local':
          return http.Response('{"success":true,"etag":"e1"}', 200);
        case '/api/v1/sync/snapshot':
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'success': true,
                'envelope': peerEnvelope().toJson(),
                'etag': 'e2',
              }),
              200,
            );
          }
          return http.Response('', 204);
        case '/api/v1/sync/inbox':
          return http.Response(
            jsonEncode({'success': true, 'envelope': null}),
            200,
          );
      }
      return http.Response('{}', 404);
    });

    final agent = SyncAgent(
      client: client,
      capture: () async => emptyBackup(),
      applyMerged: (merged) async => applied.add(merged),
      preferences: LanSyncPreferences.instance,
      localBaseUrl: 'http://127.0.0.1:12345',
      localCapability: 'local-token',
      deviceId: 'device-a',
      deviceName: 'mine',
      platform: 'android',
    );
    addTearDown(agent.close);

    final result = await agent.syncOnce(
      peerBaseUrl: 'http://192.168.1.9:12345',
      peerCapability: 'peer-token',
    );

    expect(result.pushed, isTrue);
    expect(result.pulled, isTrue);
    expect(result.merges, 1);
    expect(applied, hasLength(1));
    expect(seen, hasLength(4));
    expect(seen[0], contains('127.0.0.1 /api/v1/sync/local Bearer local-token'));
    expect(seen[1], contains('192.168.1.9 /api/v1/sync/snapshot Bearer peer-token'));
    expect(seen[2], contains('192.168.1.9 /api/v1/sync/snapshot Bearer peer-token'));
    expect(seen[3], contains('127.0.0.1 /api/v1/sync/inbox Bearer local-token'));
    expect(LanSyncPreferences.instance.lastSyncAt, greaterThan(0));
  });

  test('a missing peer address is refused before any request', () async {
    final client = MockClient((_) async => http.Response('{}', 200));
    final agent = SyncAgent(
      client: client,
      capture: () async => emptyBackup(),
      applyMerged: (_) async {},
      preferences: LanSyncPreferences.instance,
      localBaseUrl: 'http://127.0.0.1:12345',
      localCapability: 'local-token',
    );
    addTearDown(agent.close);

    await expectLater(
      agent.syncOnce(peerBaseUrl: '', peerCapability: ''),
      throwsA(
        isA<SyncException>().having(
          (error) => error.message,
          'message',
          contains('请先填写'),
        ),
      ),
    );
  });

  test('a 401 from the peer reads as a pairing problem', () async {
    final client = MockClient((_) async => http.Response('{}', 401));
    final agent = SyncAgent(
      client: client,
      capture: () async => emptyBackup(),
      applyMerged: (_) async {},
      preferences: LanSyncPreferences.instance,
      localBaseUrl: 'http://127.0.0.1:12345',
      localCapability: 'local-token',
      deviceId: 'device-a',
      deviceName: 'mine',
      platform: 'android',
    );
    addTearDown(agent.close);

    await expectLater(
      agent.syncOnce(
        peerBaseUrl: 'http://192.168.1.9:12345',
        peerCapability: 'wrong',
      ),
      throwsA(
        isA<SyncException>().having(
          (error) => error.message,
          'message',
          contains('会话密钥'),
        ),
      ),
    );
  });

  test('an inbox snapshot left by a peer is merged on the next sync', () async {
    final applied = <LibraryBackup>[];
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/sync/inbox') {
        return http.Response(
          jsonEncode({
            'success': true,
            'envelope': peerEnvelope().toJson(),
          }),
          200,
        );
      }
      if (request.url.path == '/api/v1/sync/snapshot' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'success': true, 'envelope': null, 'etag': ''}),
          200,
        );
      }
      return http.Response('{"success":true,"etag":"e"}', 200);
    });
    final agent = SyncAgent(
      client: client,
      capture: () async => emptyBackup(),
      applyMerged: (merged) async => applied.add(merged),
      preferences: LanSyncPreferences.instance,
      localBaseUrl: 'http://127.0.0.1:12345',
      localCapability: 'local-token',
      deviceId: 'device-a',
      deviceName: 'mine',
      platform: 'android',
    );
    addTearDown(agent.close);

    final result = await agent.syncOnce(
      peerBaseUrl: 'http://192.168.1.9:12345',
      peerCapability: 'peer-token',
    );
    expect(result.pulled, isTrue);
    expect(applied, hasLength(1));
  });
}
