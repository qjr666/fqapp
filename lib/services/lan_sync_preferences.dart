import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted identity and peer settings for LAN sync.
///
/// The device id is generated once and kept across restarts, so a peer can
/// tell two devices apart. The peer address/capability are the manual-entry
/// form from design §M1; pairing replaces them in P4.
class LanSyncPreferences {
  LanSyncPreferences._();

  static final LanSyncPreferences instance = LanSyncPreferences._();

  static const deviceIdKey = 'lan_sync_device_id';
  static const deviceNameKey = 'lan_sync_device_name';
  static const peerAddressKey = 'lan_sync_peer_address';
  static const peerCapabilityKey = 'lan_sync_peer_capability';
  static const lastSyncAtKey = 'lan_sync_last_at';

  String _deviceId = '';
  String _deviceName = '';
  String _peerAddress = '';
  String _peerCapability = '';
  int _lastSyncAt = 0;
  bool _loaded = false;

  String get deviceId => _deviceId;
  String get deviceName => _deviceName.isEmpty ? defaultDeviceName : _deviceName;
  String get peerAddress => _peerAddress;
  String get peerCapability => _peerCapability;
  int get lastSyncAt => _lastSyncAt;

  static String get defaultDeviceName => switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'iPhone',
    TargetPlatform.android => 'Android 手机',
    TargetPlatform.windows => 'Windows',
    _ => '设备',
  };

  static String get platformName => switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.android => 'android',
    TargetPlatform.windows => 'windows',
    _ => 'other',
  };

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      _deviceId = sp.getString(deviceIdKey) ?? '';
      _deviceName = sp.getString(deviceNameKey) ?? '';
      _peerAddress = sp.getString(peerAddressKey) ?? '';
      _peerCapability = sp.getString(peerCapabilityKey) ?? '';
      _lastSyncAt = sp.getInt(lastSyncAtKey) ?? 0;
      if (_deviceId.isEmpty) {
        _deviceId = _newDeviceId();
        await sp.setString(deviceIdKey, _deviceId);
      }
    } catch (_) {
      // A broken preference store must not stop a foreground sync; the id is
      // then session-only and the peer still recognises this run.
      if (_deviceId.isEmpty) _deviceId = _newDeviceId();
    }
  }

  static String _newDeviceId() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  Future<void> setDeviceName(String value) async {
    _deviceName = value.trim();
    await _write((sp) async {
      await sp.setString(deviceNameKey, _deviceName);
    });
  }

  Future<void> setPeer(String address, String capability) async {
    _peerAddress = address.trim();
    _peerCapability = capability.trim();
    await _write((sp) async {
      await sp.setString(peerAddressKey, _peerAddress);
      await sp.setString(peerCapabilityKey, _peerCapability);
    });
  }

  Future<void> setLastSyncAt(int milliseconds) async {
    _lastSyncAt = milliseconds;
    await _write((sp) async {
      await sp.setInt(lastSyncAtKey, _lastSyncAt);
    });
  }

  Future<void> _write(Future<void> Function(SharedPreferences sp) action) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await action(sp);
    } catch (_) {
      // Keep the in-session value: the sync has already happened.
    }
  }

  /// Only for tests: forget the one-shot load guard.
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    _deviceId = '';
    _deviceName = '';
    _peerAddress = '';
    _peerCapability = '';
    _lastSyncAt = 0;
  }
}
