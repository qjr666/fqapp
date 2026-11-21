import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'cloud_sync_transport.dart';
import 'quark_open_api.dart';
import 'sync_folder_name.dart';
import 'sync_transport.dart';

/// 夸克网盘：官方 agent open API 的纯 Dart 实现。
///
/// Android 侧原本是 `QuarkCloudDrive.java`（WebView 登录 + 原生 HTTP）。iOS
/// 没有对应的原生实现，也不具备抓 Cookie 的 WebView 插件，所以这里把协议
/// 整体搬到 Dart：授权页交给系统浏览器，App 只轮询 `page_code`，不需要
/// 回跳、不需要 WebView、不需要新增原生代码。
///
/// 凭据沿用原生那套 JSON（`access_token` / `refresh_token` / `device_id` /
/// `client_device_id` / `access_token_expires_at`），因此同一账号在 Android
/// 与 iOS 之间可以直接互通，旧凭据无需重新授权。
class QuarkSyncTransport implements SyncTransport {
  QuarkSyncTransport(this.config, this.save);

  final Map<String, String> config;
  final SaveSyncCredentials save;
  final http = CloudHttp();

  /// 签名调用统一走这一层，和授权页复用同一份签名实现。
  final open = QuarkOpenApi();

  /// 官方 Skill 里公开的分发参数，不是用户密钥。
  static const client = 'third_party_agent';
  static const agent = 'fqapp';
  static const deviceName = '什锦铺 iOS';

  static const _credentialPattern = r'^[A-Za-z0-9_.\-]{16,4096}$';
  static const maxSnapshotBytes = 32 * 1024 * 1024;

  /// 已解析的同步目录 fid；空表示还没 [prepare]。
  String directory = '';

  /// 正在轮换令牌：并发请求只让一个去换，其余的等它写完再读。
  Future<void>? _rotating;

  Map<String, dynamic> get credentials {
    final text = (config['password'] ?? '').trim();
    if (text.isEmpty) throw const SyncFailure('请先完成夸克网盘授权');
    try {
      final parsed = jsonDecode(text);
      if (parsed is Map) return Map<String, dynamic>.from(parsed);
    } on FormatException {
      // 早期版本允许直接粘贴 access_token，保持兼容。
    }
    if (RegExp(_credentialPattern).hasMatch(text)) return {'access_token': text};
    throw const SyncFailure('夸克网盘授权信息已损坏，请重新授权');
  }

  String get _accessToken =>
      (credentials['access_token'] as String? ?? '').trim();

  String get _deviceId => (credentials['device_id'] as String? ?? '').trim();

  /// 服务端既可能给秒也可能给毫秒，原生实现两种都认。
  DateTime? get _expiresAt {
    final raw = credentials['access_token_expires_at'];
    final value = raw is num ? raw.toInt() : int.tryParse('$raw');
    if (value == null || value <= 0) return null;
    final millis = value < 100000000000 ? value * 1000 : value;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> _storeCredentials(Map<String, dynamic> updates) async {
    final merged = {...credentials, ...updates};
    final text = jsonEncode(merged);
    config['password'] = text;
    await save({'password': text});
  }

  /// 令牌到期前 2 分钟主动轮换，避免同步走到一半被踢成 401。
  Future<void> authenticate({bool force = false}) async {
    if (_accessToken.isEmpty) throw const SyncFailure('请先完成夸克网盘授权');
    final expires = _expiresAt;
    final stale = force ||
        (expires != null &&
            expires.isBefore(DateTime.now().add(const Duration(minutes: 2))));
    if (!stale) return;
    final pending = _rotating;
    if (pending != null) {
      await pending;
      return;
    }
    final refresh = (credentials['refresh_token'] as String? ?? '').trim();
    if (refresh.isEmpty || _deviceId.isEmpty) {
      throw const SyncFailure('夸克网盘授权已过期，请重新授权');
    }
    final task = _rotate(refresh);
    _rotating = task;
    try {
      await task;
    } finally {
      if (identical(_rotating, task)) _rotating = null;
    }
  }

  Future<void> _rotate(String refresh) async {
    final data = await open.call(
      'POST',
      '/agent/v1/oauth/access_token/rotate',
      body: {'refresh_token': refresh, 'device_id': _deviceId},
      authenticated: true,
    );
    final token = (data['access_token'] as String? ?? '').trim();
    if (token.isEmpty) {
      throw const SyncFailure('夸克网盘刷新授权失败，请重新授权');
    }
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 7200;
    await _storeCredentials({
      ...data,
      'access_token_expires_at': DateTime.now()
          .add(Duration(seconds: expiresIn))
          .millisecondsSinceEpoch,
    });
  }

  /// 带凭据的调用：授权参数走 query，业务参数走 body（与原生实现一致）。
  Future<Map<String, dynamic>> _authorized(
    String path, {
    Map<String, dynamic> body = const {},
  }) async {
    await authenticate();
    return open.call(
      'POST',
      path,
      query: {
        'access_token': _accessToken,
        'device_id': _deviceId,
        'platform': 'android',
      },
      body: body,
      authenticated: true,
    );
  }

  @override
  Future<void> prepare() async {
    if (directory.isNotEmpty) return;
    final selected = (config['folderId'] ?? '').trim();
    // `0` 是网盘根：快照不能散在根目录里，仍按默认目录名建一个子目录。
    if (selected.isNotEmpty && selected != '0') {
      directory = selected;
      return;
    }
    directory = await ensureFolder(_folderName(config));
  }

  /// 浏览用：列 [parentFid] 下的全部条目（文件 + 目录）。
  Future<List<Map<String, dynamic>>> entries(String parentFid) async {
    final all = <Map<String, dynamic>>[];
    final visited = <String>{};
    Object? cursor;
    for (var page = 0; page < 50; page++) {
      final data = await _authorized(
        '/open/v1/file/list',
        body: {
          'parent_fid': parentFid,
          'size': 100,
          'sort': 'file_name:asc',
          if (cursor != null) 'query_cursor': '$cursor',
        },
      );
      for (final raw in data['file_list'] as List? ?? const []) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        // fid 有时是数字，filename 有时在 file_name 里，统一转字符串。
        final name = (item['filename'] ?? item['file_name'] ?? '')
            .toString()
            .trim();
        final id = (item['fid'] ?? '').toString().trim();
        if (name.isEmpty || id.isEmpty) {
          throw const SyncFailure('夸克返回了无效的文件列表');
        }
        all.add({'name': name, 'id': id, 'dir': isFolderEntry(item)});
      }
      if (all.length > 5000) {
        throw const SyncFailure('夸克目录项目过多，请选择专用同步目录');
      }
      final next = data['next_query_cursor'] ?? data['next_cursor'];
      final done = data['last_page'] == true;
      if (done || next == null || '$next'.isEmpty) return all;
      if (!visited.add('$next')) {
        throw const SyncFailure('夸克分页游标重复，已停止同步');
      }
      cursor = next;
    }
    throw const SyncFailure('夸克目录分页超出限制，请选择专用同步目录');
  }

  /// `file_type` 为 1 是目录；旧接口只给 `dir` 布尔。
  static bool isFolderEntry(Map<String, dynamic> item) {
    final type = item['file_type'];
    if (type is num) return type.toInt() == 1;
    return item['dir'] == true || item['isdir'] == true;
  }

  /// 找（必要时建）同名目录，返回 fid。
  Future<String> ensureFolder(String name) async {
    validateSyncFolderName(name);
    final root = await entries('0');
    final matches = [
      for (final entry in root)
        if (entry['dir'] == true && entry['name'] == name) entry,
    ];
    if (matches.length > 1) {
      throw const SyncFailure('夸克网盘存在重名同步文件夹，请更换目录名');
    }
    if (matches.isNotEmpty) return matches.single['id'] as String;
    final created = await _authorized(
      '/open/v1/dir',
      body: {'dir_path': name},
    );
    final fid = (created['fid'] as String? ?? '').trim();
    if (fid.isEmpty) throw const SyncFailure('夸克网盘未能创建同步目录');
    return fid;
  }

  /// 新建子目录（目录选择页用）。
  Future<String> createFolder(String parentFid, String name) async {
    validateSyncFolderName(name);
    final created = await _authorized(
      '/open/v1/dir',
      body: {'dir_path': name, 'pdir_fid': parentFid},
    );
    final fid = (created['fid'] as String? ?? '').trim();
    if (fid.isEmpty) throw const SyncFailure('夸克网盘未能创建目录');
    return fid;
  }

  @override
  Future<List<String>> list() async {
    await prepare();
    return [
      for (final entry in await entries(directory))
        if (entry['dir'] != true) entry['name'] as String,
    ];
  }

  Future<Map<String, dynamic>?> find(String name) async {
    await prepare();
    Map<String, dynamic>? found;
    for (final entry in await entries(directory)) {
      if (entry['dir'] == true || entry['name'] != name) continue;
      if (found != null) {
        throw const SyncFailure('夸克网盘产生了重名快照，暂停同步以避免覆盖');
      }
      found = entry;
    }
    return found;
  }

  @override
  Future<Uint8List?> read(String name) async {
    checkSlotName(name);
    await prepare();
    final file = await find(name);
    if (file == null) return null;
    final data = await _authorized(
      '/open/v1/file/get_download_url',
      body: {'fid': file['id']},
    );
    final url = Uri.tryParse(data['download_url'] as String? ?? '');
    if (url == null) throw const SyncFailure('夸克未返回下载地址');
    _requireTransferHost(url);
    // 自家 CDN 才带凭据；第三方加速域名不转发 token。
    final sameSite = url.host == 'quark.cn' || url.host.endsWith('.quark.cn');
    final response = await http.send(
      'GET',
      url.toString(),
      headers: sameSite
          ? {
              'Cookie':
                  'x_pan_client_id=$client;x_pan_access_token=$_accessToken',
            }
          : const {},
    );
    if (response.status != 200) {
      throw SyncFailure('夸克快照下载失败（HTTP ${response.status}）');
    }
    if (response.bytes.length > maxSnapshotBytes) {
      throw const SyncFailure('夸克快照超过同步大小限制');
    }
    return response.bytes;
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    checkSlotName(name);
    if (bytes.length > maxSnapshotBytes) {
      throw const SyncFailure('同步快照超过 32 MB，请先精简书库');
    }
    await prepare();
    final prior = await find(name);
    if (prior != null) {
      // SyncExchange 只写非活动分区，旧分区在替换完成前一直可读。夸克只有
      // NoOverwriteUpload，所以先删同名的这一个槽位，再走新建流程。
      await _authorized(
        '/open/v1/file/delete',
        body: {
          'action_type': 1,
          'fid_list': [prior['id']],
        },
      );
      var removed = false;
      for (var attempt = 0; attempt < 10; attempt++) {
        if (await find(name) == null) {
          removed = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (!removed) {
        throw const SyncFailure('夸克旧快照尚未释放，请稍后重试');
      }
    }
    final sha1Text = sha1.convert(bytes).toString();
    final md5Text = md5.convert(bytes).toString();
    final pre = await _authorized(
      '/open/v1/file/upload_pre',
      body: {
        'file_name': name,
        'size': bytes.length,
        'sha1': sha1Text,
        'md5': md5Text,
        'pdir_fid': directory,
        'format_type': 'application/json',
        'parallel_upload': true,
        'hash_update': false,
        'same_path_file_reuse': true,
        'same_path_reuse': true,
        'device_id': _deviceId,
        'device_name': deviceName,
        'agent_id': agent,
      },
    );
    if (pre['finish'] == true) return;
    final task = (pre['task_id'] as String? ?? '').trim();
    if (task.isEmpty) throw const SyncFailure('夸克未返回上传任务');
    final hashed = await _authorized(
      '/open/v1/file/update/hash',
      body: {'task_id': task, 'sha1': sha1Text, 'md5': md5Text},
    );
    if (hashed['finish'] == true) return;
    final urls = await _authorized(
      '/open/v1/file/get_upload_urls',
      body: {
        'task_id': task,
        'part_info_list': [
          {'part_number': 1, 'part_size': bytes.length},
        ],
      },
    );
    final parts = urls['upload_urls'] as List? ?? const [];
    if (parts.length != 1 || parts.first is! Map) {
      throw const SyncFailure('夸克返回了不支持的切片方案');
    }
    final part = Map<String, dynamic>.from(parts.first as Map);
    final uploadUrl = Uri.tryParse(part['upload_url'] as String? ?? '');
    if (uploadUrl == null) throw const SyncFailure('夸克未返回上传地址');
    _requireTransferHost(uploadUrl);
    final signature = part['signature_info'] as Map?;
    final common =
        (urls['common_headers'] as Map?) ?? (pre['common_headers'] as Map?);
    final headers = <String, String>{
      if (common != null)
        for (final entry in common.entries)
          if (entry.value is String) '${entry.key}': entry.value as String,
      if (signature != null && signature['signature'] is String)
        'Authorization': signature['signature'] as String,
    };
    final etag = await _put(uploadUrl, headers, bytes);
    final committed = await _authorized(
      '/open/v1/file/upload_finish',
      body: {
        'task_id': task,
        'part_info_list': [
          {'part_number': 1, 'etag': etag},
        ],
      },
    );
    if (committed['finish'] != true) {
      throw const SyncFailure('夸克上传未提交成功');
    }
    // 上传返回的 id 和列表里的 id 形态可能不同，这里以列表可见为准；
    // 之后 SyncExchange 会逐字节复核，能发现残留旧数据或静默改名。
    for (var attempt = 0; attempt < 8; attempt++) {
      if (await find(name) != null) return;
      if (attempt < 7) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    throw const SyncFailure('夸克上传后找不到快照文件');
  }

  /// 预签名 PUT。必须拿到 ETag 才能提交，所以单独走一次原始请求。
  Future<String> _put(
    Uri url,
    Map<String, String> headers,
    Uint8List bytes,
  ) async {
    try {
      final request = await http.client
          .openUrl('PUT', url)
          .timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(
        const Duration(minutes: 3),
      );
      final status = response.statusCode;
      final etag = response.headers.value(HttpHeaders.etagHeader) ?? '';
      await response.drain<void>();
      if (status < 200 || status >= 300) {
        throw SyncFailure('夸克上传失败（HTTP $status）');
      }
      if (etag.isEmpty) throw const SyncFailure('夸克上传未返回校验值');
      return etag;
    } on SyncFailure {
      rethrow;
    } catch (_) {
      throw const SyncFailure('夸克上传连接中断，请检查网络后重试');
    }
  }

  /// 只允许夸克自家域与阿里云 OSS；下载/上传地址由服务端给出，必须校验。
  static void _requireTransferHost(Uri url) {
    final host = url.host;
    final allowed = host == 'quark.cn' ||
        host.endsWith('.quark.cn') ||
        host.endsWith('.aliyuncs.com');
    if (url.scheme != 'https' || !allowed) {
      throw const SyncFailure('夸克返回了不安全的传输地址');
    }
  }

  static String _folderName(Map<String, String> config) {
    final folder = config['endpoint']?.trim() ?? '';
    final name = folder.isEmpty || folder == '/'
        ? defaultSyncFolderName
        : folder;
    validateSyncFolderName(name);
    return name;
  }

  @override
  void close() {
    http.close();
    open.close();
  }
}
