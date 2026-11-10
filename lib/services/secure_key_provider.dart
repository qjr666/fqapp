import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';

/// Minimal read/write surface over the platform secure store, kept as an
/// interface so tests can substitute an in-memory fake instead of driving a
/// MethodChannel.
abstract interface class SecureKeyStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production backend: `flutter_secure_storage` (Android Keystore /
/// EncryptedSharedPreferences, iOS Keychain, Windows DPAPI). The raw key bytes
/// never touch SharedPreferences or any other plaintext store.
class FlutterSecureKeyStorage implements SecureKeyStorage {
  const FlutterSecureKeyStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory fake for tests and for environments without a platform channel.
class InMemorySecureKeyStorage implements SecureKeyStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

/// Owns the random 256-bit keys that encrypt local data at rest.
///
/// One key per purpose, all base64-encoded in secure storage:
/// - [hiveBoxKeyName]: the Hive `HiveAesCipher` key for every encrypted box
///   (see `EncryptedHive`);
/// - [devicePoolKeyName]: the Rust device-pool file key, handed to the core
///   via the `set_device_pool_key` FRB call at startup (P1-2). Sharing the
///   infrastructure but not the key material: compromising one store must not
///   open the other.
///
/// A missing entry is created once (random 256-bit via
/// `Hive.generateSecureKey`) and persisted; a present-but-malformed entry is
/// treated as a lost key and replaced, which makes the boxes encrypted under
/// the old key unreadable — `EncryptedHive` then treats those boxes as empty
/// rather than falling back to plaintext. When secure storage itself throws
/// (no platform channel, Keystore failure), `null` is returned and callers
/// degrade per their own policy instead of failing startup.
class SecureKeyProvider {
  SecureKeyProvider({
    SecureKeyStorage? storage,
    this.storageTimeout = const Duration(seconds: 10),
  }) : _storage = storage ?? const FlutterSecureKeyStorage(),
       // 显式传入的存储一律可用（测试的内存实现、调用方自己的后端）；
       // 只有走平台默认实现时才看这台机器有没有安全存储。判定放在调用时做，
       // 不在构造时定死 —— 构造时可能正好有一处平台覆盖还没撤掉。
       _usesPlatformStorage = storage == null;

  /// Whether this host has a secure-storage backend the app can use.
  ///
  /// The app ships for Android / iOS / Windows. `flutter_secure_storage`'s
  /// **Linux** backend talks to libsecret over D-Bus, and that read never
  /// completes inside a widget test: real I/O does not run in the fake-async
  /// zone, so only the storage timeout ends the wait — and that timeout is a
  /// fake timer that outlives the test and leaves an in-flight future behind
  /// that every later caller waits on forever. Linux only ever shows up here
  /// as the CI host (there is no `linux/` target), so treat it as "no secure
  /// storage": callers degrade exactly as they do when the keystore is broken.
  static bool get _platformHasSecureStorage => switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    TargetPlatform.linux || TargetPlatform.fuchsia => false,
  };

  static final SecureKeyProvider instance = SecureKeyProvider();

  /// Hive box encryption key (base64 of 32 random bytes).
  static const hiveBoxKeyName = 'fqapp_hive_encryption_key_v1';

  /// Rust device-pool file encryption key (base64 of 32 random bytes).
  static const devicePoolKeyName = 'fqapp_device_pool_key_v1';

  /// How long a single secure-storage read/write may take before it is
  /// treated as unavailable. The platform channel normally answers in
  /// milliseconds; without a bound, a wedged Keystore — or, in widget tests,
  /// an unmocked channel whose Future never resolves — would hang startup
  /// forever instead of letting callers degrade.
  final Duration storageTimeout;

  /// Cooldown after a failed key load: lookups within one startup return the
  /// cached failure instead of each waiting out the full storage timeout.
  /// A later retry (e.g. the bootstrap retry button after the cooldown)
  /// attempts the platform channel again.
  static const _failureCooldown = Duration(seconds: 30);

  final SecureKeyStorage _storage;

  /// Whether [_storage] is the platform default (and therefore subject to the
  /// platform probe) rather than a storage the caller supplied itself.
  final bool _usesPlatformStorage;

  final Map<String, Uint8List> _cache = {};
  final Map<String, Future<Uint8List?>> _pending = {};
  final Map<String, DateTime> _failedAt = {};

  Future<Uint8List?> getOrCreateKey({String name = hiveBoxKeyName}) {
    final cached = _cache[name];
    if (cached != null) return Future.value(cached);
    final failedAt = _failedAt[name];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _failureCooldown) {
      return Future.value(null);
    }
    return _pending[name] ??= _loadOrCreate(name).then((key) {
      _pending.remove(name);
      return key;
    });
  }

  Future<Uint8List?> _loadOrCreate(String name) async {
    try {
      // 这台机器没有可用的安全存储就直接放弃：不建超时定时器，也不去等一个
      // 永远不会回来的读。等超时是唯一出口时，那个定时器会留在调用方的生命
      // 周期之外（widget 测试里就是「还有定时器没清」），而且这次没结束的
      // 读取会被 _pending 缓存下来，把后面每一个调用方一起拖死。
      if (_usesPlatformStorage && !_platformHasSecureStorage) {
        _failedAt[name] = DateTime.now();
        return null;
      }
      final stored = await _storage.read(name).timeout(storageTimeout);
      if (stored != null) {
        try {
          final decoded = base64Decode(stored);
          if (decoded.length == 32) {
            final bytes = Uint8List.fromList(decoded);
            _cache[name] = bytes;
            return bytes;
          }
        } catch (_) {
          // Malformed entry: fall through and replace it (key lost).
        }
      }
      final fresh = Uint8List.fromList(Hive.generateSecureKey());
      await _storage.write(name, base64Encode(fresh)).timeout(storageTimeout);
      _cache[name] = fresh;
      return fresh;
    } catch (_) {
      // Secure storage unavailable (or wedged past the timeout): record the
      // failure so the rest of this startup degrades immediately instead of
      // each caller waiting out another timeout. Callers decide how to
      // degrade. The generated-but-unpersisted key is deliberately NOT
      // returned: persisting it is what makes it usable next launch.
      _failedAt[name] = DateTime.now();
      return null;
    }
  }

  /// Device-pool file key for the P1-2 FRB handoff. Same infrastructure as
  /// the Hive key, separate key material.
  Future<Uint8List?> devicePoolKey() => getOrCreateKey(name: devicePoolKeyName);

  @visibleForTesting
  void resetForTest() {
    _cache.clear();
    _pending.clear();
    _failedAt.clear();
  }
}
