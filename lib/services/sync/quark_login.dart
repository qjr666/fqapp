import 'dart:convert';

import 'quark_open_api.dart';
import 'sync_folder_name.dart';
import 'sync_transport.dart';

/// 夸克网盘的浏览器授权（agent open API）。
///
/// 官方流程只要求「在授权页登录一次」，令牌落在 `page_code` 上，App 蹲着轮询
/// 就能取到 —— 不需要 WebView，也不需要自定义 URL scheme 回跳。所以 iOS /
/// 桌面端都能用同一套：打开系统浏览器 → 用户登录 → 这里轮询 → 拿到凭据。
class QuarkAuthorization {
  QuarkAuthorization._(
    this.pageCode,
    this.url,
    this.deviceId,
    this.clientDeviceId,
    this.open,
  );

  static const agentId = 'fqapp';
  static const deviceName = '什锦铺 iOS';
  static const clientId = QuarkOpenApi.client;

  final String pageCode;
  final Uri url;
  final String deviceId;
  final String clientDeviceId;
  final QuarkOpenApi open;
  bool _closed = false;

  /// 申请授权页。返回的 [url] 由调用方交给浏览器打开。
  static Future<QuarkAuthorization> begin() async {
    final api = QuarkOpenApi();
    try {
      final device = 'fqapp-${QuarkOpenApi.requestId()}';
      final data = await api.call(
        'POST',
        '/agent/v1/get_authorize_page_url',
        body: {
          'client_device_id': device,
          'device_name': deviceName,
          'agent_id': agentId,
          'client_id': clientId,
          'work_dir': defaultSyncFolderName,
          'is_cloud_agent': 'false',
          'is_unsure_agent': 'true',
        },
      );
      final page = (data['page_code'] as String? ?? '').trim();
      final raw = Uri.tryParse(data['authorize_page_url'] as String? ?? '');
      if (page.isEmpty || raw == null) {
        throw const SyncFailure('夸克未返回授权页面，请稍后重试');
      }
      // 授权页指向用户输入密码的地方，必须确认是夸克自己的域名与路径。
      if (raw.scheme != 'https' ||
          raw.host != 'pan.quark.cn' ||
          raw.path != '/open/v1/oauth/agent') {
        throw const SyncFailure('夸克返回了不可信的授权页面');
      }
      final query = <String, String>{
        ...raw.queryParameters,
        'client_id': clientId,
        'scope': 'clouddrive.base clouddrive.netdisk',
        'client_device_id': device,
        'device_name': deviceName,
        'agent_id': agentId,
      };
      final deviceId = (data['device_id'] as String? ?? '').trim();
      if (!query.containsKey('device_id') && deviceId.isNotEmpty) {
        query['device_id'] = deviceId;
      }
      return QuarkAuthorization._(
        page,
        raw.replace(queryParameters: query),
        deviceId,
        device,
        api,
      );
    } catch (_) {
      api.close();
      rethrow;
    }
  }

  /// 查一次授权状态。返回 null 表示用户还没在浏览器里点完「授权」。
  ///
  /// 成功时返回可以直接写进同步配置的凭据 JSON（与 Android 原生格式一致）。
  Future<String?> poll() async {
    if (_closed) return null;
    final state = await open.call(
      'GET',
      '/agent/v1/oauth/get_aac_by_pagecode',
      query: {'page_code': pageCode},
      authenticated: true,
    );
    if (state['status'] != 'success') return null;
    final code = (state['agent_auth_code'] as String? ?? '').trim();
    if (code.isEmpty) return null;
    final token = await open.call(
      'GET',
      '/agent/v1/oauth/agent_auth_code',
      query: {
        'agent_auth_code': code,
        'client_device_id': clientDeviceId,
        'device_name': deviceName,
        'agent_id': agentId,
        'work_dir': defaultSyncFolderName,
      },
      authenticated: true,
    );
    final access = (token['access_token'] as String? ?? '').trim();
    if (access.isEmpty) {
      throw const SyncFailure('夸克授权成功但没有返回令牌，请重新授权');
    }
    final expiresIn = (token['expires_in'] as num?)?.toInt() ?? 7200;
    final credentials = <String, dynamic>{
      ...token,
      'client_device_id': clientDeviceId,
      'device_name': deviceName,
      'agent_id': agentId,
      'access_token_expires_at': DateTime.now()
          .add(Duration(seconds: expiresIn))
          .millisecondsSinceEpoch,
      if ((token['device_id'] as String? ?? '').isEmpty && deviceId.isNotEmpty)
        'device_id': deviceId,
    };
    return jsonEncode(credentials);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    open.close();
  }
}
