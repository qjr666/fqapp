import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/wenku/wenku_segments.dart';

import 'support/fakes.dart';
import 'support/reader_settings_nav.dart';

/// 「听书跟随翻页」总闸：开关必须真的管住跟随。
///
/// 两个方向都验：
/// - 关掉 → 跟随不许再被任何路径打开（原先 15 秒闩锁到期会把跟随接回来）；
/// - 打开 → 跟随必须**真的启动**（原先只会改一个字段，会话闩锁还是 false，
///   页面照旧不跟随，看着就是开关无效）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ListeningSession.instance.clear();
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('the follow switch arms and disarms the listening follow', (
    tester,
  ) async {
    await _mountReader(tester);
    _startSession();
    await tester.pumpAndSettle();
    // 起播即跟随。
    expect(ListeningSession.instance.followArmed, isTrue);

    await _setFollowSwitch(tester, on: false);
    expect(
      ListeningSession.instance.followArmed,
      isFalse,
      reason: '关掉「跟随翻页」后跟随必须真的停掉',
    );

    await _setFollowSwitch(tester, on: true);
    expect(
      ListeningSession.instance.followArmed,
      isTrue,
      reason: '打开「跟随翻页」后跟随必须真的开始',
    );
  });

  testWidgets('a manual page turn is undone by turning the switch back on', (
    tester,
  ) async {
    await _mountReader(tester);
    _startSession();
    await tester.pumpAndSettle();

    // 用户手动翻页 → 接管跟随：会话闩锁被清掉。
    final surface = find.byKey(const ValueKey('reader-page-surface'));
    final rect = tester.getRect(surface);
    await tester.tapAt(Offset(rect.right - 16, rect.center.dy));
    await tester.pumpAndSettle();
    expect(
      ListeningSession.instance.followArmed,
      isFalse,
      reason: '手动翻页要退出跟随',
    );

    // 这正是「开关无效」的现场：会话闩锁是 false，只放开偏好并不会让跟随
    // 回来。开关必须把它重新 arm 起来。
    await _setFollowSwitch(tester, on: true);
    expect(
      ListeningSession.instance.followArmed,
      isTrue,
      reason: '打开总闸要把被手动操作清掉的跟随重新打开',
    );
  });

  testWidgets('the follow switch is persisted when the sheet closes', (
    tester,
  ) async {
    await _mountReader(tester);
    await _setFollowSwitch(tester, on: false);
    await closeReaderSettingsSheet(tester);
    await tester.pumpAndSettle();
    final stored = await ReaderPreferences.load();
    expect(stored.listeningFollow, isFalse);
  });
}

/// 多页正文：右侧点按才真的换页而不是换章。
final String _multiPageChapter = List.generate(
  40,
  (i) => '第${i + 1}段，山风从窗边吹进来，把桌上的纸页翻得沙沙作响。',
).join('\n');

const String _bookId = 'follow-toggle-test';

void _startSession() {
  ListeningSession.instance.update(
    bookId: _bookId,
    chapterId: 'c1',
    chapterTitle: '第一章',
    position: Duration.zero,
    duration: const Duration(minutes: 2),
    playing: true,
  );
}

/// 打开阅读设置 → 听书分类 → 拨动「跟随翻页」开关。
Future<void> _setFollowSwitch(WidgetTester tester, {required bool on}) async {
  // 打开阅读菜单（点正文中心）。
  await tester.tapAt(
    tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('reader-settings')));
  await tester.pumpAndSettle();
  await openReaderSettingsCategory(tester, 'listening');

  final row = find
      .ancestor(of: find.text('跟随翻页'), matching: find.byType(Row))
      .first;
  final toggle = find.descendant(
    of: row,
    matching: find.byType(AppGlassSwitch),
  );
  await tester.ensureVisible(toggle);
  final current = tester.widget<AppGlassSwitch>(toggle).value;
  if (current != on) {
    await tester.tap(toggle);
    // 面板的改动合并后 120ms 才交给阅读页。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }
  expect(
    tester.widget<AppGlassSwitch>(toggle).value,
    on,
    reason: '开关本身要显示新的状态',
  );
}

Future<void> _mountReader(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderPage(
        bookId: _bookId,
        title: '跟随开关测试',
        chapters: [
          Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
          Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
        ],
        startIndex: 0,
        localOnly: true,
        readerDevice: _Device(),
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        chapterLoader: (_) async => _multiPageChapter,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Device extends ReaderDevice {
  final _events = StreamController<ReaderDeviceStatus>.broadcast(sync: true);

  _Device() {
    addTearDown(_events.close);
  }

  @override
  Stream<ReaderDeviceStatus> get changes => _events.stream;

  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(
    time: DateTime(2026, 10, 30, 9),
    battery: 80,
    systemBrightness: 0.45,
  );

  @override
  Future<bool> setBrightness({
    required bool followSystem,
    required double brightness,
  }) async => true;
}
