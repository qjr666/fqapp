import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/book_open_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final prefs = BookOpenPreferences.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs.resetForTest();
    // 这组用例只关心两条「直达阅读器」偏好本身。「点书先看详情页」默认
    // 开着，会把书架那条盖掉，所以这里显式关掉它。
    await prefs.setOpenDetailFirst(false);
  });

  test('「先看详情页」默认开着，书架入口默认不再直达阅读器', () async {
    SharedPreferences.setMockInitialValues({});
    prefs.resetForTest();
    await prefs.load();
    expect(prefs.openDetailFirst.value, isTrue);
    expect(prefs.opensDetailFirst(BookOpenEntry.shelf), isTrue);
    expect(prefs.directReaderFor(BookOpenEntry.shelf), isFalse);
    // 发现入口不受它影响。
    expect(prefs.opensDetailFirst(BookOpenEntry.discover), isFalse);
    expect(prefs.directReaderFor(BookOpenEntry.discover), isFalse);
  });

  test('关掉「先看详情页」后书架入口回到直达阅读器', () async {
    await prefs.setOpenDetailFirst(false);
    await prefs.setShelfDirectReader(true);
    prefs.resetForTest();
    await prefs.load();
    expect(prefs.opensDetailFirst(BookOpenEntry.shelf), isFalse);
    expect(prefs.directReaderFor(BookOpenEntry.shelf), isTrue);
  });

  test('「先看详情页」自己也会持久化', () async {
    await prefs.setOpenDetailFirst(false);
    prefs.resetForTest();
    await prefs.load();
    expect(prefs.openDetailFirst.value, isFalse);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool(BookOpenPreferences.detailFirstKey), isFalse);
  });

  test('书架默认直达阅读器，发现入口默认先看详情页', () async {
    await prefs.load();
    expect(prefs.directReaderFor(BookOpenEntry.shelf), isTrue);
    expect(prefs.directReaderFor(BookOpenEntry.discover), isFalse);
  });

  test('the two entries persist independently', () async {
    await prefs.setShelfDirectReader(false);
    await prefs.setDiscoverDirectReader(true);
    prefs.resetForTest();
    await prefs.load();
    expect(prefs.directReaderFor(BookOpenEntry.shelf), isFalse);
    expect(prefs.directReaderFor(BookOpenEntry.discover), isTrue);

    await prefs.setShelfDirectReader(true);
    prefs.resetForTest();
    await prefs.load();
    expect(prefs.directReaderFor(BookOpenEntry.shelf), isTrue);
    expect(prefs.directReaderFor(BookOpenEntry.discover), isTrue);
  });

  test('the legacy single switch migrates to both entries', () async {
    SharedPreferences.setMockInitialValues({
      BookOpenPreferences.legacyKey: false,
    });
    await prefs.load();
    // 旧值优先于新默认值：升级前关着单开关的用户不会被突然改成直达。
    expect(prefs.directReaderFor(BookOpenEntry.shelf), isFalse);
    expect(prefs.directReaderFor(BookOpenEntry.discover), isFalse);
    // 迁移把旧值写回两条新键，之后改一条不会带着另一条一起变。
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool(BookOpenPreferences.shelfKey), isFalse);
    expect(sp.getBool(BookOpenPreferences.discoverKey), isFalse);
    await prefs.setShelfDirectReader(true);
    expect(sp.getBool(BookOpenPreferences.shelfKey), isTrue);
    expect(sp.getBool(BookOpenPreferences.discoverKey), isFalse);
  });

  test('the legacy switch set to on keeps both entries on', () async {
    SharedPreferences.setMockInitialValues({
      BookOpenPreferences.legacyKey: true,
      // 「点书先看详情页」默认开着，会盖掉书架那条的直达行为。这条用例验的
      // 是 legacy 开关本身的迁移，所以显式把它关掉。
      BookOpenPreferences.detailFirstKey: false,
    });
    await prefs.load();
    expect(prefs.directReaderFor(BookOpenEntry.shelf), isTrue);
    expect(prefs.directReaderFor(BookOpenEntry.discover), isTrue);
  });

  test('an explicit new value wins over the legacy switch', () async {
    SharedPreferences.setMockInitialValues({
      BookOpenPreferences.legacyKey: false,
      BookOpenPreferences.discoverKey: true,
      BookOpenPreferences.detailFirstKey: false,
    });
    await prefs.load();
    // 书架那条没显式写过，沿用旧值；发现入口那条显式写过，以它为准。
    expect(prefs.directReaderFor(BookOpenEntry.shelf), isFalse);
    expect(prefs.directReaderFor(BookOpenEntry.discover), isTrue);
  });

  test('a wrong-typed stored value falls back to each default', () async {
    SharedPreferences.setMockInitialValues({
      BookOpenPreferences.shelfKey: 'yes',
      BookOpenPreferences.discoverKey: 'yes',
    });
    await prefs.load();
    expect(prefs.directReaderFor(BookOpenEntry.shelf), isTrue);
    expect(prefs.directReaderFor(BookOpenEntry.discover), isFalse);
  });
}
