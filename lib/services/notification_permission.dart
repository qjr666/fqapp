import 'package:flutter/foundation.dart';

import 'platform_channel.dart';

/// 通知权限状态。
enum NotificationPermissionState {
  /// 已经授权（或系统本来就不需要运行时权限）。
  granted,

  /// 被拒绝，或从未申请过。
  denied,

  /// 系统**还没问过**用户（iOS 的 UNUserNotificationCenter.notDetermined）。
  ///
  /// 与 [denied] 分开是因为两者的下一步不同：没问过还能弹系统授权框，
  /// 问过且被拒就只能引导去系统设置。
  notDetermined,

  /// 拿不到状态（平台不支持、通道不可用）。
  unknown,
}

/// 通知权限：后台保活的前台服务通知卡片需要它。
///
/// Android 13 起 POST_NOTIFICATIONS 是运行时权限。用户拒绝后前台服务照样能
/// 跑，但通知卡片不可见 —— 厂商系统（MIUI / HyperOS / ColorOS）在这种情形下
/// 更容易把后台进程冻住，听书在后台就断了。所以这里把状态读出来，让界面能
/// 引导用户去系统设置里开启，而不是让用户自己猜「为什么没有通知」。
class NotificationPermission {
  NotificationPermission._();

  static final NotificationPermission instance = NotificationPermission._();

  static const _channel = AppMethodChannel('fqapp/native_player');

  /// 当前状态。启动后与每次回到前台时刷新。
  final ValueNotifier<NotificationPermissionState> state =
      ValueNotifier<NotificationPermissionState>(
    NotificationPermissionState.unknown,
  );

  /// 读取当前状态。
  Future<NotificationPermissionState> refresh() async {
    final next = _parse(await _invoke('notificationPermissionStatus'));
    state.value = next;
    return next;
  }

  /// 弹系统授权框申请。
  ///
  /// Android 在用户拒绝过一次之后不会再弹窗，这时只能去系统设置页开。
  Future<NotificationPermissionState> request() async {
    final next = _parse(await _invoke('requestNotificationPermission'));
    state.value = next;
    return next;
  }

  /// 只在「系统还没问过用户」时弹系统授权框。
  ///
  /// 用户拒绝过一次之后系统不会再弹（iOS 的 UNUserNotificationCenter、
  /// Android 13+ 的 POST_NOTIFICATIONS 都如此），这时只能引导去系统设置。
  /// 所以先读状态，只在 [NotificationPermissionState.notDetermined] 时才申请。
  Future<NotificationPermissionState> requestIfUndetermined() async {
    final current = await refresh();
    if (current != NotificationPermissionState.notDetermined) return current;
    return request();
  }

  /// 跳到系统的「通知」设置页：权限被拒后唯一还能开的入口。
  Future<bool> openSettings() async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'openNotificationSettings',
      );
      return ok ?? false;
    } catch (error) {
      debugPrint('[notification-permission] openSettings failed: $error');
      return false;
    }
  }

  Future<String?> _invoke(String method) async {
    try {
      return await _channel.invokeMethod<String>(method);
    } catch (error) {
      debugPrint('[notification-permission] $method failed: $error');
      return null;
    }
  }

  NotificationPermissionState _parse(String? value) {
    switch (value) {
      case 'granted':
        return NotificationPermissionState.granted;
      case 'denied':
        return NotificationPermissionState.denied;
      case 'notDetermined':
        return NotificationPermissionState.notDetermined;
      default:
        return NotificationPermissionState.unknown;
    }
  }
}
