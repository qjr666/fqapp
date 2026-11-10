// LAN sync console (design §M5, pairing in §M2). Follows the archive
// vocabulary used by `library_backup_page.dart`: ArchiveFeaturePage shell,
// ArchiveSection headers, ContentPanel rows and GlassTextButton actions.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/backend_service.dart';
import '../services/lan_discovery_service.dart';
import '../services/lan_sync_pairing.dart';
import '../services/lan_sync_preferences.dart';
import '../services/sync_agent.dart';
import '../widgets/wenku/wenku_ui.dart';

class LanSyncPage extends StatefulWidget {
  const LanSyncPage({super.key});

  @override
  State<LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends State<LanSyncPage> {
  final _prefs = LanSyncPreferences.instance;
  final _pairing = LanSyncPairing.instance;
  final _address = TextEditingController();
  final _capability = TextEditingController();
  final _name = TextEditingController();
  final _pairAddress = TextEditingController();
  final _pairCode = TextEditingController();

  SyncAgent? _agent;
  final _discovery = LanDiscoveryService();
  StreamSubscription<List<DiscoveredDevice>>? _discoverySub;
  List<DiscoveredDevice> _discovered = const [];
  bool _discovering = false;
  /// 发现通道没起来（套接字绑不上）：iOS 上最常见的原因是系统没给
  /// 「本地网络」权限 —— 广播与连接都会被拦下，发现整条链路都不通。
  bool _discoveryUnavailable = false;

  /// iOS 特有：本地网络权限被拒时，UDP 广播与 TCP 连接都会被系统拦下，
  /// 界面上必须说清楚这件事，否则用户只会看到「尚未发现设备」。
  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  List<String> _addresses = const [];
  int _port = 0;
  int _lastSyncAt = 0;
  bool _busy = false;
  bool _error = false;
  String? _message;

  PairCode? _issuedCode;
  List<PairedDevice> _hosts = const [];
  PairedPeer? _paired;
  int _codeRemaining = 0;
  Timer? _codeTimer;
  bool _pairBusy = false;
  bool _pairError = false;
  String? _pairMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _codeTimer?.cancel();
    _discoverySub?.cancel();
    _discovery.dispose();
    _agent?.close();
    _address.dispose();
    _capability.dispose();
    _name.dispose();
    _pairAddress.dispose();
    _pairCode.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _prefs.load();
    final addresses = await _detectLanAddresses();
    final port = Uri.tryParse(BackendService.instance.baseUrl)?.port ?? 0;
    final paired = await _pairing.loadPaired();
    // The local service may not be up yet; an empty device list is fine.
    final hosts = await _safeHosts();
    // Listen before starting: the first probe can be answered immediately.
    _discoverySub ??= _discovery.devices.listen((devices) {
      if (mounted) setState(() => _discovered = devices);
    });
    if (mounted) setState(() => _discovering = true);
    final started = await _discovery.start();
    if (mounted) setState(() => _discovering = false);
    if (!mounted) return;
    setState(() {
      _addresses = addresses;
      _port = port;
      _lastSyncAt = _prefs.lastSyncAt;
      _address.text = _prefs.peerAddress;
      _capability.text = _prefs.peerCapability;
      _name.text = _prefs.deviceName;
      _paired = paired;
      _hosts = hosts;
      _pairAddress.text = paired?.address ?? _prefs.peerAddress;
      _discoveryUnavailable = !started;
    });
  }

  Future<List<PairedDevice>> _safeHosts() async {
    try {
      return await _pairing.hosts();
    } catch (_) {
      return const <PairedDevice>[];
    }
  }

  Future<void> _search() async {
    if (!mounted) return;
    setState(() => _discovering = true);
    _discovery.reset();
    await _discovery.probe();
    if (mounted) setState(() => _discovering = false);
  }

  void _useDevice(DiscoveredDevice device) {
    setState(() {
      _pairAddress.text = device.baseUrl;
      _address.text = device.baseUrl;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已填入 ${device.name} 的地址，可继续配对或手动同步')),
    );
  }

  static Future<List<String>> _detectLanAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final result = <String>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback || address.address.startsWith('169.254.')) {
            continue;
          }
          if (!result.contains(address.address)) result.add(address.address);
        }
      }
      return result;
    } catch (_) {
      return const <String>[];
    }
  }

  Future<void> _copy(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  void _startCountdown(int seconds) {
    _codeTimer?.cancel();
    _codeRemaining = seconds;
    _codeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _codeRemaining--;
        if (_codeRemaining <= 0) {
          _issuedCode = null;
          timer.cancel();
        }
      });
    });
  }

  void _setPairMessage(String? message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _pairMessage = message;
      _pairError = error;
    });
  }

  Future<void> _runPairAction(Future<void> Function() action) async {
    if (_pairBusy) return;
    setState(() {
      _pairBusy = true;
      _pairMessage = null;
      _pairError = false;
    });
    try {
      await action();
    } on SyncException catch (error) {
      _setPairMessage(error.message, error: true);
    } catch (error) {
      _setPairMessage('操作失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _pairBusy = false);
    }
  }

  Future<void> _issueCode() => _runPairAction(() async {
    final code = await _pairing.issueCode();
    if (!mounted) return;
    _startCountdown(code.ttlSeconds);
    setState(() => _issuedCode = code);
    _setPairMessage('配对码已生成，请在另一台设备输入这 6 位数字。');
  });

  Future<void> _pair() => _runPairAction(() async {
    final peer = await _pairing.pairWithPeer(
      peerBaseUrl: _pairAddress.text,
      code: _pairCode.text,
    );
    if (!mounted) return;
    setState(() {
      _paired = peer;
      _address.text = peer.address;
      _pairCode.clear();
    });
    _setPairMessage('配对成功。之后点「立即同步」会自动使用这把密钥。');
  });

  Future<void> _unpair() => _runPairAction(() async {
    await _pairing.clearPaired();
    if (!mounted) return;
    setState(() => _paired = null);
    _setPairMessage('已取消配对，可改用下面的手动输入。');
  });

  Future<void> _revoke(String deviceId) => _runPairAction(() async {
    await _pairing.revoke(deviceId);
    final hosts = await _safeHosts();
    if (!mounted) return;
    setState(() => _hosts = hosts);
    _setPairMessage('已移除该设备，它以前的密钥立即失效。');
  });

  Future<void> _sync() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      // A pairing secret wins over manual entry, but manual entry stays as the
      // fallback when pairing is unavailable (design §10).
      final paired = _paired ?? await _pairing.loadPaired();
      final peerAddress = paired?.address ?? _address.text;
      final peerSecret = paired?.secret ?? _capability.text;
      await _prefs.setPeer(_address.text, _capability.text);
      await _prefs.setDeviceName(_name.text);
      final result = await (_agent ??= SyncAgent()).syncOnce(
        peerBaseUrl: peerAddress,
        peerCapability: peerSecret,
      );
      if (!mounted) return;
      setState(() {
        _lastSyncAt = result.at.millisecondsSinceEpoch;
        _message = result.pulled
            ? '同步完成：已拉取对端进度并按最新时间合并（${result.merges} 次合并），'
                '本机快照也已推送到对方。'
            : '本机快照已推送到对方；对方还没有可拉取的快照，'
                '请在另一台设备也点一次「立即同步」。';
      });
    } on SyncException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _message = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _message = '同步失败：$error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(
      fontSize: 13,
      height: 1.7,
      color: scheme.onSurfaceVariant,
    );
    final localCapability = BackendService.instance.transport.capability;
    final lastSync = _lastSyncAt == 0
        ? '尚未同步'
        : DateTime.fromMillisecondsSinceEpoch(_lastSyncAt)
            .toLocal()
            .toString()
            .split('.')
            .first;
    return ArchiveFeaturePage(
      title: '局域网同步',
      code: 'LAN / SYNC',
      child: ListView(
        key: const ValueKey('lan-sync-scroll'),
        padding: featurePadding(context),
        children: [
          const AppText(
            '两台设备，一份进度',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          AppText(
            '推荐先在两台设备间配对一次：其中一台生成 6 位配对码，另一台输入即可。'
            '之后不用再复制会话密钥。也可以继续使用下面的手动输入。'
            '进度按时间取新，书架与已看记录取并集。',
            style: muted,
          ),
          const SizedBox(height: 24),
          const ArchiveSection(title: '本机', code: 'LAN / HOST'),
          const SizedBox(height: 14),
          ContentPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppText('本机地址（点按复制）', style: muted),
                const SizedBox(height: 8),
                if (_addresses.isEmpty)
                  AppText(
                    '未检测到局域网地址，请确认已连接 Wi-Fi 并开启「局域网共享」。',
                    style: muted,
                  )
                else
                  for (final address in _addresses)
                    InkWell(
                      key: ValueKey('lan-sync-address-$address'),
                      onTap: () => _copy('http://$address:$_port', '本机地址'),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: AppText('http://$address:$_port'),
                      ),
                    ),
                const SizedBox(height: 14),
                InkWell(
                  key: const ValueKey('lan-sync-capability'),
                  onTap: () => _copy(localCapability, '会话密钥'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: AppText(
                      localCapability.isEmpty
                          ? '会话密钥尚未就绪，请稍后重进本页'
                          : '会话密钥：${_mask(localCapability)}（点按复制）',
                      style: muted,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                AppText('上次同步：$lastSync', style: muted),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const ArchiveSection(title: '附近设备', code: 'LAN / DISCOVER'),
          const SizedBox(height: 14),
          ContentPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppText(
                  '同一 Wi-Fi 下自动搜索，点设备即可把地址填入下面的配对或手动输入。'
                  '部分路由器会隔离设备间的广播，此时仍可手动填写。',
                  style: muted,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: AppText(
                        _discovering
                            ? '正在搜索…'
                            : '已发现 ${_discovered.length} 台设备',
                        style: muted,
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('lan-sync-discover'),
                      onPressed: _discovering ? null : _search,
                      child: const Text('重新搜索'),
                    ),
                  ],
                ),
                if (_discovering) const LinearProgressIndicator(minHeight: 2),
                if (_discovered.isEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: AppText('尚未发现设备', style: muted),
                  ),
                  if (_discoveryUnavailable)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: AppText(
                        '本机的局域网通道没有启动。'
                        '${_isIOS ? '请在系统设置 → 什锦铺 → 本地网络 中允许访问，' : ''}'
                        '并确认对方已开启「局域网共享」。',
                        style: muted,
                      ),
                    ),
                ] else
                  for (final device in _discovered)
                    InkWell(
                      key: ValueKey('lan-sync-device-${device.id}'),
                      onTap: () => _useDevice(device),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: AppText(
                          '${device.name} · ${device.platform} · ${device.baseUrl}',
                          style: muted,
                        ),
                      ),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const ArchiveSection(title: '配对', code: 'LAN / PAIR'),
          const SizedBox(height: 14),
          ContentPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppText(
                  '① 让另一台设备连我：生成配对码，把 6 位数字填到对方设备。',
                  style: muted,
                ),
                const SizedBox(height: 10),
                if (_issuedCode != null) ...[
                  AppText(
                    _issuedCode!.code,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 6,
                    ),
                  ),
                  AppText('剩余 $_codeRemaining 秒', style: muted),
                  const SizedBox(height: 8),
                ],
                GlassTextButton(
                  key: const ValueKey('lan-sync-issue-code'),
                  onPressed: _pairBusy ? null : _issueCode,
                  child: AppText(_issuedCode == null ? '生成配对码' : '重新生成'),
                ),
                const SizedBox(height: 16),
                AppText('已允许读取本机的设备（${_hosts.length}）', style: muted),
                if (_hosts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: AppText('暂无', style: muted),
                  )
                else
                  for (final host in _hosts)
                    Row(
                      children: [
                        Expanded(
                          child: AppText(
                            '${host.name} · ${host.platform}',
                            style: muted,
                          ),
                        ),
                        TextButton(
                          key: ValueKey('lan-sync-revoke-${host.id}'),
                          onPressed: _pairBusy ? null : () => _revoke(host.id),
                          child: const Text('移除'),
                        ),
                      ],
                    ),
                const Divider(height: 28),
                AppText(
                  '② 我要连另一台设备：填对方地址，输入它显示的配对码。',
                  style: muted,
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('lan-sync-pair-address'),
                  controller: _pairAddress,
                  enabled: !_pairBusy,
                  decoration: const InputDecoration(
                    labelText: '对端地址（http://手机IP:端口）',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('lan-sync-pair-code'),
                  controller: _pairCode,
                  enabled: !_pairBusy,
                  decoration: const InputDecoration(
                    labelText: '对方显示的 6 位配对码',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                ),
                GlassTextButton(
                  key: const ValueKey('lan-sync-pair'),
                  onPressed: _pairBusy ? null : _pair,
                  child: const AppText('配对'),
                ),
                if (_paired != null) ...[
                  const SizedBox(height: 12),
                  AppText(
                    '已配对：${_paired!.address}\n同步时自动使用配对密钥，无需再填会话密钥。',
                    style: muted,
                  ),
                  TextButton(
                    key: const ValueKey('lan-sync-unpair'),
                    onPressed: _pairBusy ? null : _unpair,
                    child: const Text('取消配对，改用手动输入'),
                  ),
                ],
                if (_pairBusy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(minHeight: 2),
                ],
                if (_pairMessage case final message?) ...[
                  const SizedBox(height: 12),
                  _pairError
                      ? FeatureError(message)
                      : ContentPanel(child: AppText(message, style: muted)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          const ArchiveSection(title: '对端设备（手动）', code: 'LAN / PEER'),
          const SizedBox(height: 14),
          ContentPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppText(
                  '配对不可用时可手动填写。会话密钥每次重启服务都会变化，配对密钥不会。',
                  style: muted,
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('lan-sync-peer-address'),
                  controller: _address,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: '对端地址（http://手机IP:端口）',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey('lan-sync-peer-capability'),
                  controller: _capability,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: '对端会话密钥',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey('lan-sync-device-name'),
                  controller: _name,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: '本机显示名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                GlassTextButton(
                  key: const ValueKey('lan-sync-start'),
                  onPressed: _busy ? null : _sync,
                  child: AppText(_busy ? '正在同步…' : '立即同步'),
                ),
              ],
            ),
          ),
          if (_busy) ...[
            const SizedBox(height: 20),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (_message case final message?) ...[
            const SizedBox(height: 20),
            _error
                ? FeatureError(message)
                : ContentPanel(child: AppText(message, style: muted)),
          ],
          const SizedBox(height: 24),
          AppText(
            '使用前：两台设备都要在「设置 → 服务 → 本地接口服务台」开启局域网共享，'
            '并连到同一个 Wi-Fi。iPhone 切到后台后系统可能断开连接，'
            '请保持在同步页面直到提示完成。',
            style: muted,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static String _mask(String value) => value.length <= 8
      ? value
      : '${value.substring(0, 4)}…${value.substring(value.length - 4)}';
}
