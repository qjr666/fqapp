import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/library_backup.dart';
import '../models/sync_envelope.dart';
import 'backend_service.dart';
import 'lan_sync_preferences.dart';
import 'library_backup_service.dart';
import 'library_store.dart';
import 'shelf_group_store.dart';
import 'shelf_store.dart';
import 'sync_merger.dart';

/// A user-facing sync failure. Network exceptions are translated here so the
/// page never has to show a raw `SocketException`.
class SyncException implements Exception {
  const SyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SyncResult {
  const SyncResult({
    required this.pulled,
    required this.pushed,
    required this.merges,
    required this.at,
  });

  /// Whether a snapshot from the peer was pulled (directly or via the inbox).
  final bool pulled;
  final bool pushed;
  final int merges;
  final DateTime at;
}

/// Drives one bidirectional sync (`docs/lan-sync-design.md` §5.3).
///
/// The core is a dumb transport: Dart alone assembles snapshots with
/// `LibraryBackupService.capture()` and merges them with `SyncMerger`. Every
/// dependency is injectable so the whole sequence can be tested without Hive
/// or a real socket.
class SyncAgent {
  SyncAgent({
    http.Client? client,
    Future<LibraryBackup> Function()? capture,
    Future<void> Function(LibraryBackup merged)? applyMerged,
    LanSyncPreferences? preferences,
    this.localBaseUrlOverride,
    this.localCapabilityOverride,
    this.deviceIdOverride,
    this.deviceNameOverride,
    this.platformOverride,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _capture = capture ?? (() => LibraryBackupService().capture()),
       _applyMerged = applyMerged ?? _defaultApplyMerged,
       _prefs = preferences ?? LanSyncPreferences.instance;

  static const requestTimeout = Duration(seconds: 20);

  final http.Client _client;
  final bool _ownsClient;
  final Future<LibraryBackup> Function() _capture;
  final Future<void> Function(LibraryBackup merged) _applyMerged;
  final LanSyncPreferences _prefs;

  /// Test seams: when null, the running backend's address/capability and the
  /// persisted device identity are used.
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

  /// One bidirectional sync: publish this device's snapshot, pull the peer's,
  /// merge, push the merged result into the peer's inbox, then drain our own
  /// inbox (a peer may have pushed while this app was in the background).
  Future<SyncResult> syncOnce({
    String? peerBaseUrl,
    String? peerCapability,
  }) async {
    final peer = (peerBaseUrl ?? _prefs.peerAddress).trim();
    final token = (peerCapability ?? _prefs.peerCapability).trim();
    if (peer.isEmpty || token.isEmpty) {
      throw const SyncException('请先填写对端地址与会话密钥');
    }
    await _prefs.load();
    final device = SyncDevice(
      id: deviceIdOverride ?? _prefs.deviceId,
      name: deviceNameOverride ?? _prefs.deviceName,
      platform: platformOverride ?? LanSyncPreferences.platformName,
    );
    final sentAt = DateTime.now().millisecondsSinceEpoch;

    final before = await _capture();
    await _post(
      _uri(localBaseUrl, 'local'),
      localCapability,
      _envelope(device, before, sentAt),
    );

    var merges = 0;
    final remote = await _getEnvelope(_uri(peer, 'snapshot'), token);
    if (remote != null) {
      await _applyMerged(SyncMerger.merge(before, remote.backup));
      merges++;
    }

    final after = await _capture();
    await _post(
      _uri(peer, 'snapshot'),
      token,
      _envelope(device, after, sentAt),
    );

    final inbox = await _getEnvelope(
      _uri(localBaseUrl, 'inbox'),
      localCapability,
    );
    if (inbox != null) {
      final current = await _capture();
      await _applyMerged(SyncMerger.merge(current, inbox.backup));
      merges++;
    }

    final at = DateTime.now();
    await _prefs.setLastSyncAt(at.millisecondsSinceEpoch);
    return SyncResult(
      pulled: remote != null || inbox != null,
      pushed: true,
      merges: merges,
      at: at,
    );
  }

  static SyncEnvelope _envelope(
    SyncDevice device,
    LibraryBackup backup,
    int sentAt,
  ) => SyncEnvelope(device: device, sentAt: sentAt, backup: backup);

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

  Future<void> _post(
    Uri uri,
    String capability,
    SyncEnvelope envelope,
  ) async {
    final response = await _send(
      () => _client.post(
        uri,
        headers: _headers(capability),
        body: envelope.encode(),
      ),
    );
    _ensureOk(response);
  }

  Future<SyncEnvelope?> _getEnvelope(Uri uri, String capability) async {
    final response = await _send(
      () => _client.get(uri, headers: _headers(capability)),
    );
    if (response.statusCode == 304) return null;
    _ensureOk(response);
    final raw = jsonDecode(utf8.decode(response.bodyBytes));
    if (raw is! Map) throw const SyncException('对端返回的数据格式有误');
    final envelope = raw['envelope'];
    if (envelope == null) return null;
    if (envelope is! Map) throw const SyncException('对端返回的数据格式有误');
    return SyncEnvelope.fromJson(Map<String, dynamic>.from(envelope));
  }

  void _ensureOk(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) return;
    if (status == 401) {
      throw const SyncException('会话密钥不正确，或对方未开启局域网共享');
    }
    if (status == 404) {
      throw const SyncException('对方版本不支持局域网同步，请先升级');
    }
    throw SyncException('对端返回 HTTP $status');
  }

  Future<http.Response> _send(
    Future<http.Response> Function() send,
  ) async {
    try {
      return await send().timeout(requestTimeout);
    } on SyncException {
      rethrow;
    } catch (error) {
      throw SyncException('无法连接对端，请检查地址、同一 Wi-Fi 与前台状态：$error');
    }
  }

  static Future<void> _defaultApplyMerged(LibraryBackup merged) async {
    final groupStore = ShelfGroupStore.instance;
    // Groups go first so assignments know their capacity, exactly as a backup
    // restore does. Both are "fill the gaps" merges; the timestamp decision
    // has already been made by SyncMerger.
    if (merged.groups.isNotEmpty && groupStore.isReady) {
      await groupStore.mergeBackup(merged.groups);
    }
    await ShelfStore.instance.mergeBackup(merged.shelf);
    await LibraryStore.instance.mergeSync(
      history: merged.history,
      watched: merged.watched,
    );
  }
}
