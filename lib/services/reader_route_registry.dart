import 'package:flutter/widgets.dart';

/// 阅读页在导航栈里的登记簿。
///
/// 听书页的「边听边读」要回到**已经在栈里**的那一份阅读页，而不是再 push
/// 一份新的：从书里点「听书」进听书页，再点「边听边读」时，这本书的阅读页
/// 还在栈里。重新 push 会得到两个阅读页实例——进度、高亮、跟随各走各的，
/// 用户看到的就是「打开了一个新页面」，而不是回到刚才那本书。
///
/// 登记的是**路由对象**而不是页面实例：回退时用它做 `popUntil` 的终止条件，
/// 才能精确停在那一份阅读页上，而不是一路退到根页面。
class ReaderRouteRegistry {
  ReaderRouteRegistry._();

  static final ReaderRouteRegistry instance = ReaderRouteRegistry._();

  final Map<String, ReaderRouteEntry> _entries =
      <String, ReaderRouteEntry>{};

  /// 阅读页登记自己。
  ///
  /// [navigator] 是拥有这条路由的 Navigator：回退时必须用同一个，否则会退到
  /// 别的栈上（听书页与阅读页不在同一个 Navigator 时就不能复用这份阅读页）。
  /// [jumpToChapter] 用来把阅读页定位到指定章节（按章节 id，不是下标）。
  void register(
    String bookId,
    NavigatorState navigator,
    Route<dynamic> route,
    Future<void> Function(String chapterId) jumpToChapter,
  ) {
    if (bookId.isEmpty) return;
    _entries[bookId] = ReaderRouteEntry(
      navigator: navigator,
      route: route,
      jumpToChapter: jumpToChapter,
    );
  }

  /// 页面销毁时注销。只清自己登记的那一条：换章重建时新实例已经接管，
  /// 旧实例的注销不能把新登记的那条抹掉。
  void unregister(String bookId, Route<dynamic> route) {
    final entry = _entries[bookId];
    if (entry != null && identical(entry.route, route)) {
      _entries.remove(bookId);
    }
  }

  /// 找出栈里那一份指定书的阅读页；没有就返回 null。
  ReaderRouteEntry? find(String bookId) => _entries[bookId];

  @visibleForTesting
  void clear() => _entries.clear();
}

/// 一份在栈里的阅读页。
class ReaderRouteEntry {
  ReaderRouteEntry({
    required this.navigator,
    required this.route,
    required this.jumpToChapter,
  });

  /// 拥有这条路由的 Navigator。
  final NavigatorState navigator;

  /// 阅读页自己的路由对象：`popUntil` 用它做终止条件。
  final Route<dynamic> route;

  /// 把阅读页定位到指定章节（按章节 id 匹配，不是下标）。
  ///
  /// 用 id 而不是下标：调用方手里的目录与阅读页自己的目录可能不是同一份
  /// （重新拉过的目录、拼接模式），按下标跳会落到别的章节去。
  final Future<void> Function(String chapterId) jumpToChapter;
}
