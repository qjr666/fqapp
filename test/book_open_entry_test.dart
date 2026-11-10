import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/services/book_open_preferences.dart';

/// `openBookDetail` 的入口分流（issue #103）：书架入口读书架那条偏好，发现入口
/// 读发现那条。DetailPage 自身「进不进阅读器」的行为由 detail_page_test 覆盖，
/// 这里只断言统一入口把哪条偏好交给了它。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BookOpenPreferences.instance.resetForTest();
  });

  testWidgets('书架入口与发现入口各读各自的开关', (tester) async {
    // 「点书先看详情页」默认开着，会盖掉书架那条直达阅读器偏好；这里先
    // 关掉它，单独验证两条「直达阅读」开关各管各的。
    await BookOpenPreferences.instance.setOpenDetailFirst(false);
    await BookOpenPreferences.instance.setShelfDirectReader(true);
    await BookOpenPreferences.instance.setDiscoverDirectReader(false);

    expect(await _autoOpenReaderOf(tester, BookOpenEntry.shelf), isTrue);
    expect(await _autoOpenReaderOf(tester, BookOpenEntry.discover), isFalse);
  });

  testWidgets('「先看详情页」打开时书架入口不再直达阅读器', (tester) async {
    await BookOpenPreferences.instance.setOpenDetailFirst(true);
    await BookOpenPreferences.instance.setShelfDirectReader(true);

    expect(await _autoOpenReaderOf(tester, BookOpenEntry.shelf), isFalse);
    // 发现入口不受「先看详情页」影响。
    expect(await _autoOpenReaderOf(tester, BookOpenEntry.discover), isFalse);
  });

  testWidgets('反过来设置时同样按来源取', (tester) async {
    await BookOpenPreferences.instance.setShelfDirectReader(false);
    await BookOpenPreferences.instance.setDiscoverDirectReader(true);

    expect(await _autoOpenReaderOf(tester, BookOpenEntry.shelf), isFalse);
    expect(await _autoOpenReaderOf(tester, BookOpenEntry.discover), isTrue);
  });
}

Future<bool> _autoOpenReaderOf(WidgetTester tester, BookOpenEntry entry) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => openBookDetail(context, _book, entry: entry),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  // openBookDetail 先等偏好加载完再 push，两个 pump 才保证路由已建好。
  await tester.pump();
  await tester.pump();
  final detail = tester.widget<DetailPage>(find.byType(DetailPage));
  final autoOpenReader = detail.autoOpenReader;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  return autoOpenReader;
}

final _book = MediaItem(
  id: 'book',
  title: '测试书',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
);
