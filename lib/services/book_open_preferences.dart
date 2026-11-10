import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 点书入口的分类，决定用哪一条「点书直达阅读器」偏好（issue #103）。
///
/// 书架里的书是用户已经收下的书，点开八成是想接着读；发现入口（首页、
/// 搜索、榜单、作者页…）的书往往还要先看简介再决定，所以两条偏好分开存，
/// 也让官方「书架续读、发现页进详情」的默认分层在客户端可控。
enum BookOpenEntry {
  /// 书架、阅读历史这类「我的书」入口。
  shelf,

  /// 首页、搜索、榜单、作者页、短剧/系列推荐等发现入口。
  discover,
}

/// 「点书直达阅读器」的持久化偏好（issue #19 第 3 条引入，issue #103 拆成
/// 书架/发现两条）。
///
/// 默认值按入口分开：书架那条**默认开**（书架里的书就是「接着读」，官方书架点书
/// 也直接起阅读器），发现入口那条默认关（先看简介再决定更常见）。打开后点书跳过
/// 详情页，直接按上次进度进阅读器；听书/短剧仍进详情页（它们不是「阅读」），
/// 详情页加载失败时也停留在详情页，让用户看到错误与重试。
///
/// 旧版只有一条全局开关 [legacyKey]，[load] 读到旧值且新键都不存在时把它迁移
/// 成「两条同值」，升级后行为不变；旧键本身保留不删，避免回退版本时丢设置。
class BookOpenPreferences {
  BookOpenPreferences._();

  static final BookOpenPreferences instance = BookOpenPreferences._();

  /// 旧版单开关，只用于一次性迁移。
  static const legacyKey = 'book_open_direct_reader';
  static const shelfKey = 'book_open_direct_reader_shelf';
  static const discoverKey = 'book_open_direct_reader_discover';

  /// 「点书先看详情页」的独立键。
  static const detailFirstKey = 'book_open_open_detail_first';

  /// 书架那条的默认值：开。书架里的书是用户自己收下的，点开就是接着读。
  static const defaultShelfDirectReader = true;

  /// 发现入口那条的默认值：关。先看简介、目录、评分再决定是常态。
  static const defaultDiscoverDirectReader = false;

  /// 「点书先看详情页」的默认值：开。
  ///
  /// 曾经只有「书架点书直达阅读器」一条（默认开），于是书架上点任何一本
  /// 小说都会被抢在详情页前面直接顶进阅读器，简介、目录、评分一个都看不到
  /// —— 用户反馈的正是「书架打开的小说无法进入小说详情页，而推荐页可以」。
  ///
  /// 详情页上本来就有「继续阅读 · 第N章」按钮，续读一步到位，所以默认
  /// 改成先看详情页；想沿用旧行为的用户在设置里把这个开关关掉即可。
  static const defaultOpenDetailFirst = true;

  /// 书架/阅读历史里点书是否直达阅读器。由 [load] 从 SharedPreferences 读入，
  /// 读完之前是 [defaultShelfDirectReader]。
  final ValueNotifier<bool> shelfDirectReader = ValueNotifier<bool>(
    defaultShelfDirectReader,
  );

  /// 发现入口点书是否直达阅读器。读完之前是 [defaultDiscoverDirectReader]。
  final ValueNotifier<bool> discoverDirectReader = ValueNotifier<bool>(
    defaultDiscoverDirectReader,
  );

  /// 「我的书」入口（书架、阅读历史、收藏）点书时是否先打开详情页。
  ///
  /// 只作用于「我的书」入口：发现入口（首页、搜索、榜单、作者页）本来默认
  /// 就是先看详情页，由 [discoverDirectReader] 单独控制，不受这条影响。
  final ValueNotifier<bool> openDetailFirst = ValueNotifier<bool>(
    defaultOpenDetailFirst,
  );

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final legacy = sp.getBool(legacyKey);
      final hasShelf = sp.containsKey(shelfKey);
      final hasDiscover = sp.containsKey(discoverKey);
      final shelf = sp.getBool(shelfKey) ?? legacy ?? defaultShelfDirectReader;
      final discover =
          sp.getBool(discoverKey) ?? legacy ?? defaultDiscoverDirectReader;
      shelfDirectReader.value = shelf;
      discoverDirectReader.value = discover;
      openDetailFirst.value =
          sp.getBool(detailFirstKey) ?? defaultOpenDetailFirst;
      if (legacy != null && !hasShelf && !hasDiscover) {
        await _persist(shelf: shelf, discover: discover);
      }
    } catch (_) {
      // A broken optional preference reads as its default.
    }
  }

  /// 忘掉已加载状态，让下一次 [load] 重新读 SharedPreferences。
  ///
  /// 只为测试存在：`_loaded` 是进程级一次性守卫，`setMockInitialValues`
  /// 换掉的初值不会被已加载过的实例重新读取。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    shelfDirectReader.value = defaultShelfDirectReader;
    discoverDirectReader.value = defaultDiscoverDirectReader;
    openDetailFirst.value = defaultOpenDetailFirst;
  }

  /// 某个入口当前是否直达阅读器。调用前应确保 [load] 已完成。
  ///
  /// [opensDetailFirst] 打开时，「我的书」入口一律先看详情页，直达阅读器
  /// 的那条偏好不生效（设置页里那一条会在描述里说明依赖关系）。
  bool directReaderFor(BookOpenEntry entry) => switch (entry) {
    BookOpenEntry.shelf =>
      opensDetailFirst(entry) ? false : shelfDirectReader.value,
    BookOpenEntry.discover => discoverDirectReader.value,
  };

  /// 某个入口点书时是否先打开详情页。
  ///
  /// 只有「我的书」入口受 [openDetailFirst] 约束；发现入口永远先看详情页，
  /// 直到用户自己打开「首页与搜索点书直接进入阅读」。
  bool opensDetailFirst(BookOpenEntry entry) =>
      entry == BookOpenEntry.shelf && openDetailFirst.value;

  Future<void> setShelfDirectReader(bool value) async {
    shelfDirectReader.value = value;
    await _persist(shelf: value);
  }

  Future<void> setDiscoverDirectReader(bool value) async {
    discoverDirectReader.value = value;
    await _persist(discover: value);
  }

  Future<void> setOpenDetailFirst(bool value) async {
    openDetailFirst.value = value;
    await _persist(detailFirst: value);
  }

  /// 只写传入的键；写失败不影响本次会话内的值。
  Future<void> _persist({
    bool? shelf,
    bool? discover,
    bool? detailFirst,
  }) async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (shelf != null) await sp.setBool(shelfKey, shelf);
      if (discover != null) await sp.setBool(discoverKey, discover);
      if (detailFirst != null) await sp.setBool(detailFirstKey, detailFirst);
    } catch (_) {
      // The in-session value still applies; only persistence failed.
    }
  }
}
