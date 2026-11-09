// LAN sync console (design §M5). Follows the archive vocabulary used by
// `library_backup_page.dart`: ArchiveFeaturePage shell, ArchiveSection headers,
// ContentPanel rows and GlassTextButton actions.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/backend_service.dart';
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
  final _address = TextEditingController();
  final _capability = TextEditingController();
  final _name = TextEditingController();

  SyncAgent? _agent;
  List<String> _addresses = const [];
  int _port = 0;
  int _lastSyncAt = 0;
  bool _busy = false;
  bool _error = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _agent?.close();
    _address.dispose();
    _capability.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _prefs.load();
    final addresses = await _detectLanAddresses();
    final port = Uri.tryParse(BackendService.instance.baseUrl)?.port ?? 0;
    if (!mounted) return;
    setState(() {
      _addresses = addresses;
      _port = port;
      _lastSyncAt = _prefs.lastSyncAt;
      _address.text = _prefs.peerAddress;
      _capability.text = _prefs.peerCapability;
      _name.text = _prefs.deviceName;
    });
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

  Future<void> _sync() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      await _prefs.setPeer(_address.text, _capability.text);
      await _prefs.setDeviceName(_name.text);
      final result = await (_agent ??= SyncAgent()).syncOnce();
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
            '把下面显示的地址与会话密钥填到另一台设备，两台都点一次「立即同步」。'
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
          const ArchiveSection(title: '对端设备', code: 'LAN / PEER'),
          const SizedBox(height: 14),
          ContentPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
