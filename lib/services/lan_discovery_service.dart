import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'backend_service.dart';
import 'lan_sync_preferences.dart';

/// A device found on the same Wi-Fi. It carries only presentation data —
/// no capability and no pairing secret ever travel in a discovery packet.
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
  });

  final String id;
  final String name;
  final String platform;
  final String address;
  final int port;

  String get baseUrl => 'http://$address:$port';
}

/// The tiny JSON datagram used by the zero-dependency discovery path
/// (`docs/lan-sync-design.md` §M1, the "UDP broadcast probe" row).
///
/// A device broadcasts a `probe`; every other device answers with a unicast
/// `reply` carrying its HTTP service port. No multicast group and no platform
/// plugin are involved, so this works with only `dart:io` and the INTERNET
/// permission the app already has.
class DiscoveryMessage {
  const DiscoveryMessage({
    required this.kind,
    required this.id,
    required this.name,
    required this.platform,
    required this.port,
  });

  static const format = 'fqapp.lan-discovery';
  static const version = 1;
  static const probe = 'probe';
  static const reply = 'reply';
  static const maxBytes = 2048;

  final String kind;
  final String id;
  final String name;
  final String platform;
  final int port;

  Map<String, dynamic> toJson() => {
    'format': format,
    'version': version,
    'kind': kind,
    'device': {'id': id, 'name': name, 'platform': platform},
    'port': port,
  };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static DiscoveryMessage? decode(List<int> bytes) {
    if (bytes.length > maxBytes) return null;
    try {
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map) return null;
      if (raw['format'] != format || raw['version'] != version) return null;
      final kind = raw['kind'];
      if (kind != probe && kind != reply) return null;
      final device = raw['device'];
      if (device is! Map) return null;
      final id = device['id'];
      final name = device['name'];
      final platform = device['platform'];
      final port = raw['port'];
      if (id is! String ||
          id.isEmpty ||
          name is! String ||
          platform is! String ||
          port is! int ||
          port <= 0 ||
          port > 65535) {
        return null;
      }
      return DiscoveryMessage(
        kind: kind,
        id: id,
        name: name,
        platform: platform,
        port: port,
      );
    } catch (_) {
      // A stray datagram on this port is not a discovery packet.
      return null;
    }
  }
}

/// Finds peers on the local network by UDP broadcast, and answers probes so
/// this device can be found too. Manual IP entry remains the fallback required
/// by design §10 (some routers isolate wireless clients from broadcast).
class LanDiscoveryService {
  LanDiscoveryService({
    this.port = defaultPort,
    LanSyncPreferences? preferences,
    this.httpPortOverride,
    this.deviceIdOverride,
    this.deviceNameOverride,
    this.platformOverride,
    this.broadcastAddressesOverride,
    this.sendOverride,
  }) : _prefs = preferences ?? LanSyncPreferences.instance;

  static const defaultPort = 45678;
  static const probeInterval = Duration(seconds: 3);

  /// Test seam: intercept every outgoing datagram instead of using a socket.
  final void Function(List<int> data, InternetAddress address, int port)?
  sendOverride;

  final List<String>? broadcastAddressesOverride;
  final int port;
  final int? httpPortOverride;
  final String? deviceIdOverride;
  final String? deviceNameOverride;
  final String? platformOverride;
  final LanSyncPreferences _prefs;

  final _controller = StreamController<List<DiscoveredDevice>>.broadcast();
  final Map<String, DiscoveredDevice> _found = {};
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _probeTimer;

  Stream<List<DiscoveredDevice>> get devices => _controller.stream;
  List<DiscoveredDevice> get current => List.unmodifiable(_found.values);

  int get _httpPort =>
      httpPortOverride ??
      Uri.tryParse(BackendService.instance.baseUrl)?.port ??
      0;

  String get _deviceId => deviceIdOverride ?? _prefs.deviceId;

  DiscoveryMessage _message(String kind) => DiscoveryMessage(
    kind: kind,
    id: _deviceId,
    name: deviceNameOverride ?? _prefs.deviceName,
    platform: platformOverride ?? LanSyncPreferences.platformName,
    port: _httpPort,
  );

  /// Binds the UDP socket and starts probing. Returns false when the socket
  /// cannot be bound (another instance, no network) — callers then simply
  /// keep the manual entry path.
  Future<bool> start() async {
    if (_socket != null) return true;
    await _prefs.load();
    if (sendOverride == null) {
      try {
        final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
        socket.broadcastEnabled = true;
        _socket = socket;
        _subscription = socket.listen(
          (event) {
            if (event != RawSocketEvent.read) return;
            // One read event may deliver several datagrams.
            while (true) {
              final datagram = socket.receive();
              if (datagram == null) break;
              final message = DiscoveryMessage.decode(datagram.data);
              if (message != null) {
                handleMessage(message, datagram.address);
              }
            }
          },
          onError: (Object _) {},
        );
      } catch (_) {
        return false;
      }
    }
    await probe();
    _probeTimer = Timer.periodic(probeInterval, (_) => probe());
    return true;
  }

  Future<void> probe() async {
    final request = _message(DiscoveryMessage.probe);
    for (final target in await _broadcastAddresses()) {
      _send(request.encode(), InternetAddress(target));
    }
  }

  Future<List<String>> _broadcastAddresses() async {
    final override = broadcastAddressesOverride;
    if (override != null) return override;
    final result = <String>{'255.255.255.255'};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final ip = address.address;
          if (ip.startsWith('169.254.')) continue;
          final parts = ip.split('.');
          if (parts.length != 4) continue;
          // /24 covers virtually every home Wi-Fi; the global broadcast is
          // kept for networks that answer only to 255.255.255.255.
          result.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
    } catch (_) {
      // Keep the global broadcast at least.
    }
    return result.toList();
  }

  void _send(List<int> bytes, InternetAddress target) {
    final override = sendOverride;
    if (override != null) {
      override(bytes, target, port);
      return;
    }
    try {
      _socket?.send(bytes, target, port);
    } catch (_) {
      // A broadcast target may be unreachable; other targets still get it.
    }
  }

  @visibleForTesting
  void handleMessage(DiscoveryMessage message, InternetAddress from) {
    if (message.id == _deviceId) return; // our own broadcast came back
    if (message.kind == DiscoveryMessage.probe) {
      _send(_message(DiscoveryMessage.reply).encode(), from);
      return;
    }
    _found[message.id] = DiscoveredDevice(
      id: message.id,
      name: message.name,
      platform: message.platform,
      address: from.address,
      port: message.port,
    );
    _emit();
  }

  void reset() {
    _found.clear();
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(List.unmodifiable(_found.values));
    }
  }

  void stop() {
    _probeTimer?.cancel();
    _probeTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
