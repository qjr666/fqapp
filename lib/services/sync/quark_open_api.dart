import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'cloud_sync_transport.dart';
import 'sync_transport.dart';

/// 夸克官方 agent open API 的最小调用层：签名头 + 统一错误处理。
///
/// 授权（未登录）和文件操作（已登录）走的是同一套签名，签名实现只能有一份
/// —— 差一个 `&` 或者大小写就会全线 401，所以抽在这里共用。
class QuarkOpenApi {
  final http = CloudHttp();

  /// 官方 Skill 里公开的分发参数，不是用户密钥。
  static const client = 'third_party_agent';
  static const sign = 'cf134812e2de4032bd1cb7c3727e84b3';
  static const host = 'open-api-drive.quark.cn';

  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    Map<String, String> query = const {},
    Map<String, dynamic>? body,
    bool authenticated = false,
  }) async {
    final time = DateTime.now().millisecondsSinceEpoch.toString();
    final signature = sha256
        .convert(utf8.encode('$method&$path&$time&$sign'))
        .toString();
    final uri = Uri.https(host, path, {'req_id': requestId(), ...query});
    final response = await http.send(
      method,
      uri.toString(),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'x-pan-client-id': client,
        'x-pan-tm': time,
        'x-pan-token': signature,
      },
      bytes: body == null
          ? null
          : Uint8List.fromList(utf8.encode(jsonEncode(body))),
    );
    if (response.status == 401 || response.status == 403) {
      throw SyncFailure(
        authenticated ? '夸克网盘授权已失效，请重新授权' : '夸克网盘拒绝了这次请求',
      );
    }
    if (response.status != 200) {
      throw SyncFailure('夸克接口请求失败（HTTP ${response.status}）');
    }
    final Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(utf8.decode(response.bytes));
      if (parsed is! Map) throw const FormatException();
      decoded = Map<String, dynamic>.from(parsed);
    } on FormatException {
      throw const SyncFailure('夸克返回内容无效');
    }
    final status = (decoded['status'] as num?)?.toInt() ?? -1;
    if (status != 0) {
      final code = decoded['errno'] ?? decoded['code'] ?? status;
      throw SyncFailure('夸克接口拒绝请求（错误码 $code）');
    }
    final payload = decoded['data'];
    return payload is Map ? Map<String, dynamic>.from(payload) : {};
  }

  /// 形如 8-4-4-4-12；服务端只把它当日志关联 id。
  static String requestId() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    final text = buffer.toString();
    return '${text.substring(0, 8)}-${text.substring(8, 12)}-'
        '${text.substring(12, 16)}-${text.substring(16, 20)}-'
        '${text.substring(20, 32)}';
  }

  void close() => http.close();
}
