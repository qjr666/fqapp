import 'dart:convert';
import 'dart:typed_data';

import 'library_backup.dart';

/// Wire envelope for LAN sync (`docs/lan-sync-design.md` §5.1).
///
/// The `backup` field is the exact JSON produced by `LibraryBackup.encode()`:
/// export/import and LAN sync therefore share one decoder and one validator.
/// The core only checks the shape of the envelope; this class is the only
/// place that knows the field names.
class SyncDevice {
  final String id;
  final String name;
  final String platform;

  const SyncDevice({
    required this.id,
    required this.name,
    required this.platform,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
  };

  factory SyncDevice.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final platform = json['platform'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        name is! String ||
        name.length > 128 ||
        platform is! String ||
        platform.isEmpty ||
        platform.length > 128) {
      throw const FormatException('同步设备信息无效');
    }
    return SyncDevice(id: id, name: name, platform: platform);
  }
}

class SyncEnvelope {
  static const format = 'fqapp.sync-envelope';
  static const version = 1;
  static const maxBytes = LibraryBackup.maxBytes;

  final SyncDevice device;
  final int sentAt;
  final LibraryBackup backup;

  const SyncEnvelope({
    required this.device,
    required this.sentAt,
    required this.backup,
  });

  Map<String, dynamic> toJson() => {
    'format': format,
    'version': version,
    'device': device.toJson(),
    'sentAt': sentAt,
    'backup': jsonDecode(utf8.decode(backup.encode())),
  };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  factory SyncEnvelope.decode(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('同步数据超过 16 MB');
    }
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map) throw const FormatException('同步数据格式有误');
    return SyncEnvelope.fromJson(Map<String, dynamic>.from(raw));
  }

  factory SyncEnvelope.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format || json['version'] != version) {
      throw const FormatException('不支持的同步数据版本');
    }
    final sentAt = json['sentAt'];
    if (sentAt is! int || sentAt <= 0 || sentAt > 9000000000000000) {
      throw const FormatException('同步时间无效');
    }
    final device = json['device'];
    if (device is! Map) throw const FormatException('同步设备信息无效');
    final backup = json['backup'];
    if (backup is! Map) throw const FormatException('同步数据缺少备份');
    return SyncEnvelope(
      device: SyncDevice.fromJson(Map<String, dynamic>.from(device)),
      sentAt: sentAt,
      backup: LibraryBackup.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(backup))),
      ),
    );
  }
}
