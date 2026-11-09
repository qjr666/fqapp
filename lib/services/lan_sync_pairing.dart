import 'dart:convert';

import 'package:http/http.dart' as http;

import 'backend_service.dart';
import 'lan_sync_preferences.dart';
import 'secure_key_provider.dart';
import 'sync_agent.dart' show SyncException;

/// A short-lived code the host shows to the device that wants to sync with it.
class PairCode {
  const PairCode({
    required this.code,
    required this.expiresAt,
    required this.ttlSeconds,
  });

  final String code;
  final int expiresAt;
  final int ttlSeconds;
}

/// A device the host has issued a secret to. The secret itself is never
/// returned by the host list.
class PairedDevice {
  const PairedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.pairedAt,
  });

  final String id;
  final String name;
  final String platform;
  final int pairedAt;

  static PairedDevice fromJson(Map<String, dynamic> json) => PairedDevice(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    platform: json['platform'] as String? ?? '',
    pairedAt: (json['pairedAt'] as num?)?.toInt() ?? 0,
  );
}

/// The peer this device paired with, kept in secure storage rather than
/// SharedPreferences (design §M2). A single JSON value keeps the address and
/// the secret together, so a stale address can never be used with a new key.
class PairedPeer {
  const PairedPeer({
    required this.address,
    required this.secret,
    required this.deviceId,
  });

  final String address;
  final String secret;
  final String deviceId;

  Map<String, dynamic> toJson() => {
    'address': address,
    'secret': secret,
    'deviceId': deviceId,
  };

  static PairedPeer? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final address = value['address'] as String? ?? '';
      final secret = value['secret'] as String? ?? '';
      if (address.isEmpty || secret.isEmpty) return null;
      return PairedPeer(
        address: address,
        secret: secret,
        deviceId: value['deviceId'] as String? ?? '',
      );
    } catch (_) {
      // A corrupt entry is treated as unpaired, never as a hard failure.
      return null;
    }
  }
}

/// Drives the pairing handshake (design §M2 / §5.2) and owns the peer secret.
///
/// The host calls [issueCode] and shows six digits; the other device calls
/// [pairWithPeer] with them. From then on the ordinary sync endpoints accept
/// the issued secret as a bearer token. Manual capability entry from P3 stays
/// available as the fallback required by design §10.
class LanSyncPairing {
  LanSyncPairing({
    http.Client? client,
    SecureKeyStorage? storage,
    LanSyncPreferences? preferences,
    this.localBaseUrlOverride,
    this.localCapabilityOverride,
    this.deviceIdOverride,
    this.deviceNameOverride,
    this.platformOverride,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _storage = storage ?? const FlutterSecureKeyStorage(),
       _prefs = preferences ?? LanSyncPreferences.instance;

  static final LanSyncPairing instance = LanSyncPairing();

  static const secretKey = 'fqapp_lan_sync_peer_v1';
  static const requestTimeout = Duration(seconds: 20);

  /// Platform channels are absent in widget tests; a wedged Keystore must not
  /// block the sync page — the same policy as `SecureKeyProvider`.
  static const storageTimeout = Duration(seconds: 3);

  final http.Client _client;
  final bool _ownsClient;
  final SecureKeyStorage _storage;
  final LanSyncPreferences _prefs;

  final String? localBaseUrlOverride;
  final String? localCapabilityOverride;
  final String? deviceIdOverride;
  final String? deviceNameOverride;
  final String? platformOverride;

  String get localBaseUrl =>
      localBaseUrlOverride ?? BackendService.instance.baseUrl;

  String get localCapability =>
      localCapabilityOverride ?? BackendService.instance.transport.capability;

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<PairedPeer?> loadPaired() async {
    try {
      final raw = await _storage.read(secretKey).timeout(storageTimeout);
      return PairedPeer.decode(raw);
    } catch (_) {
      // Secure storage unavailable: fall back to manual entry.
      return null;
    }
  }

  Future<void> clearPaired() async {
    try {
      await _storage.delete(secretKey).timeout(storageTimeout);
    } catch (_) {
      // Nothing else to do; the in-memory value is not cached here.
    }
  }

  Future<void> _savePaired(PairedPeer peer) async {
    await _storage
        .write(secretKey, jsonEncode(peer.toJson()))
        .timeout(storageTimeout);
  }

  /// Host side: mint a 60-second code. Requires this device's capability.
  Future<PairCode> issueCode() async {
    final body = await _json(
      () => _client.post(
        _uri(localBaseUrl, 'pair/code'),
        headers: _headers(localCapability),
      ),
    );
    return PairCode(
      code: body['code'] as String? ?? '',
      expiresAt: (body['expiresAt'] as num?)?.toInt() ?? 0,
      ttlSeconds: (body['ttlSeconds'] as num?)?.toInt() ?? 60,
    );
  }

  /// Client side: exchange the host's code for a long-lived secret, persist
  /// it in secure storage, and return the paired peer. This call deliberately
  /// carries no capability: the code in the body is the credential.
  Future<PairedPeer> pairWithPeer({
    required String peerBaseUrl,
    required String code,
  }) async {
    final address = peerBaseUrl.trim();
    final digits = code.trim();
    if (address.isEmpty || digits.isEmpty) {
      throw const SyncException('请填写对端地址与 6 位配对码');
    }
    await _prefs.load();
    final device = <String, String>{
      'id': deviceIdOverride ?? _prefs.deviceId,
      'name': deviceNameOverride ?? _prefs.deviceName,
      'platform': platformOverride ?? LanSyncPreferences.platformName,
    };
    final body = await _json(
      () => _client.post(
        _uri(address, 'pair'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'code': digits, 'device': device}),
      ),
      unauthorizedMessage: '配对码不正确或已过期，请让对方重新生成',
    );
    final secret = body['secret'] as String? ?? '';
    if (secret.isEmpty) {
      throw const SyncException('对端没有返回会话密钥');
    }
    final peer = PairedPeer(
      address: address,
      secret: secret,
      deviceId: (body['device'] as Map?)?['id'] as String? ?? device['id']!,
    );
    await _savePaired(peer);
    return peer;
  }

  /// Host side: devices allowed to read this device's sync endpoints.
  Future<List<PairedDevice>> hosts() async {
    final body = await _json(
      () => _client.get(
        _uri(localBaseUrl, 'hosts'),
        headers: _headers(localCapability),
      ),
    );
    final list = body['devices'];
    if (list is! List) return const <PairedDevice>[];
    return list
        .whereType<Map>()
        .map((item) => PairedDevice.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> revoke(String deviceId) async {
    await _json(
      () => _client.post(
        _uri(localBaseUrl, 'hosts/revoke'),
        headers: _headers(localCapability),
        body: jsonEncode({'deviceId': deviceId}),
      ),
    );
  }

  static Uri _uri(String base, String tail) {
    final clean = base.trim().replaceAll(RegExp(r'/+$'), '');
    final parsed = Uri.tryParse(clean);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      throw const SyncException('地址格式有误，请填写 http://手机IP:端口');
    }
    return parsed.replace(path: '/api/v1/sync/$tail');
  }

  Map<String, String> _headers(String capability) => {
    'authorization': 'Bearer $capability',
    'content-type': 'application/json',
  };

  Future<Map<String, dynamic>> _json(
    Future<http.Response> Function() send, {
    String unauthorizedMessage = '会话密钥不正确，或对方未开启局域网共享',
  }) async {
    final http.Response response;
    try {
      response = await send().timeout(requestTimeout);
    } catch (error) {
      throw SyncException('无法连接对端，请检查地址、同一 Wi-Fi 与前台状态：$error');
    }
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (response.bodyBytes.isEmpty) return <String, dynamic>{};
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        // A 204 or an empty success body is fine.
      }
      return <String, dynamic>{};
    }
    if (status == 401) throw SyncException(unauthorizedMessage);
    if (status == 404) {
      throw const SyncException('对方版本不支持配对，请先升级');
    }
    if (status == 410) {
      throw const SyncException('配对码已过期，请让对方重新生成');
    }
    if (status == 429) {
      throw const SyncException('尝试次数过多，请让对方重新生成配对码');
    }
    if (status == 400) {
      throw const SyncException('配对码不正确，或对方还没有生成配对码');
    }
    throw SyncException('对端返回 HTTP $status');
  }
}
