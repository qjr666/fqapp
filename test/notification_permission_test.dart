import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/notification_permission.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fqapp/native_player');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  /// 模拟原生侧：status 返回 [status]，request 返回 [requestResult]。
  void mockNative({
    required String status,
    String requestResult = 'granted',
  }) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'notificationPermissionStatus':
          return status;
        case 'requestNotificationPermission':
          return requestResult;
        case 'openNotificationSettings':
          return true;
      }
      return null;
    });
  }

  setUp(() {
    calls.clear();
    mockNative(status: 'unknown');
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('the native status maps onto the permission states', () async {
    mockNative(status: 'granted');
    expect(
      await NotificationPermission.instance.refresh(),
      NotificationPermissionState.granted,
    );

    mockNative(status: 'denied');
    expect(
      await NotificationPermission.instance.refresh(),
      NotificationPermissionState.denied,
    );

    // iOS 的 notDetermined：系统还没问过用户，与「问过且被拒」不同 ——
    // 前者还能弹系统授权框，后者只能引导去系统设置。
    mockNative(status: 'notDetermined');
    expect(
      await NotificationPermission.instance.refresh(),
      NotificationPermissionState.notDetermined,
    );

    mockNative(status: 'whatever');
    expect(
      await NotificationPermission.instance.refresh(),
      NotificationPermissionState.unknown,
    );
  });

  test('requesting only happens while the system has not asked yet', () async {
    mockNative(status: 'notDetermined', requestResult: 'granted');
    final state = await NotificationPermission.instance.requestIfUndetermined();
    expect(state, NotificationPermissionState.granted);
    expect(calls, contains('requestNotificationPermission'));

    calls.clear();
    mockNative(status: 'denied');
    final denied = await NotificationPermission.instance.requestIfUndetermined();
    expect(denied, NotificationPermissionState.denied);
    // 已经问过用户：系统不会再弹框，不该再去申请一次。
    expect(calls, isNot(contains('requestNotificationPermission')));

    calls.clear();
    mockNative(status: 'granted');
    final granted = await NotificationPermission.instance.requestIfUndetermined();
    expect(granted, NotificationPermissionState.granted);
    expect(calls, isNot(contains('requestNotificationPermission')));
  });

  test('the settings shortcut opens the system settings page', () async {
    mockNative(status: 'denied');
    expect(await NotificationPermission.instance.openSettings(), isTrue);
    expect(calls, contains('openNotificationSettings'));
  });
}
