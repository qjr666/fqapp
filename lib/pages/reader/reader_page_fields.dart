part of '../reader_page.dart';

/// State storage for [ReaderPage]: chapter text, paging layout, selection,
/// listening and device state.
mixin _ReaderPageFields on State<ReaderPage> {
  final _joinedKey = GlobalKey<ReaderJoinedScrollState>();
  late int _index;
  final ScrollController _scrollController = ScrollController();
  Timer? _saveTimer;
  // 小米公平运行内存 KILL 广播的刷盘注销函数：dispose 时注销，避免 KILL
  // 到达时调用已 dispose 页面的保存。
  VoidCallback? _unregisterFairMemoryFlush;

  /// 滚动模式下拖过边界的累计量：超过阈值才触发连续阅读跨章，避免轻微
  /// 回弹误触（与分页视图的 32px 边界阈值一致）。带符号：拖过底部为正，
  /// 拖过顶部为负；同一拖拽内反向会抵消累计量。
  double _scrollOverscroll = 0;

  /// In-flight chapter fetches keyed by chapter id: prefetching a neighbour or
  /// refreshing a cached chapter must not cancel the chapter being read.
  final ChapterRequestTracker _chapterRequestHandles = ChapterRequestTracker();

  String _content = '';
  ChapterContent _chapterContent = ChapterContent(blocks: const []);
  TextReplacementResult? _replacement;
  AiChapterView? _aiView;
  int _aiRevision = -1;
  bool _aiChangeRunning = false;
  bool _aiChangeQueued = false;
  bool _aiTemporaryOriginal = false;
  int? _aiPreviewSourceStart;
  int? _aiPreviewSourceEnd;
  String? _aiAutoRequestedKey;
  final _aiPrefetchScheduled = <String>{};
  Timer? _aiRefreshTimer;
  Timer? _aiDeferTimer;
  Timer? _joinedAiRefreshTimer;
  bool _aiDeferredForListening = false;
  TextReplacementCancellation? _replacementCancellation;
  int _replacementGeneration = 0;

  ChapterIdeas _ideas = ChapterIdeas.empty;
  final _ideasCache = <String, ({String version, ChapterIdeas ideas})>{};
  final _underlineCache =
      <
        String,
        ({String version, Set<int> ids, List<ReaderRangeUnderline> ranges})
      >{};

  /// True after entering a chapter backwards. Keeps the chapter end pinned
  /// while late idea/underline data changes the page count.
  bool _keepChapterEndAnchor = false;
  bool _loading = true;
  bool _progressReady = false;
  double _lastPosition = 0;
  double _lastMaxScroll = 0;
  String? _error;
  ReaderPreferences _preferences = const ReaderPreferences();
  ReaderThemePreset _dayTheme = ReaderThemePreset.light;
  final ValueNotifier<bool> _controlsVisibility = ValueNotifier(false);
  bool get _controlsVisible => _controlsVisibility.value;
  late final AnimationController _chrome;
  bool _reduceReaderMotion = false;
  bool _settingsPreviewActive = false;
  int? _settingsPreviewSourceOffset;
  int _settingsPreviewRevision = 0;
  int _readerNavigationGeneration = 0;
  Future<void>? _bookmarkNavigationTask;
  bool _progressPreviewActive = false;
  bool _readerPanelOpen = false;
  double? _pendingChapterPreview;
  bool _chapterPreviewScheduled = false;
  int? _previewLoadGeneration;
  double? _chapterPreviewFraction;
  ReaderTextSelection? _locationHighlight;
  Timer? _locationHighlightTimer;
  ReaderVideoMatch? _videoMatch;
  BackendRequest? _videoMatchRequest;
  BackendRequest? _videoOpenRequest;
  bool get _openingVideo => _videoOpenRequest != null;
  DateTime? _videoMatchAttempt;
  AudioToneSet? _readerTones;
  BackendRequest? _readerTonesRequest;
  DateTime? _readerTonesAttempt;

  /// 自动翻页: a repeating timer flips forward every [ReaderPreferences.autoTurnSeconds]
  /// seconds; any tap or drag stops it. See
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Timer? _autoTurnTimer;

  /// 听书跟随翻页: the audio page is narrating this chapter, so land on the
  /// page holding the estimated playback position. Instant jumps — the
  /// narration keeps moving and an animated chase would always lag.
  ///
  /// 用户接管闩锁：手动翻页后短时间内不跟随。
  ///
  /// 官方对普通翻页的处理见 `AudioSyncReaderController.java:1242-1295`
  /// （`handlePlayWhenPageChange`）：置 `C=true`、暂停播放并亮出「原进度 /
  /// 从本页听」。跟随并不会自己恢复，直到用户点「原进度」（`K()`，:768）。
  /// 这里同样在 [_pauseListenFollow] 里直接关掉跟随；闩锁只是兜住「又在
  /// 15 秒内被重新打开」的路径，恢复播放时由 [_onListeningTick] 清掉。
  DateTime _listenFollowPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 用户**手动接管**过跟随：拖一下页面、翻一页、换一章都会置位。
  ///
  /// 与 [ListeningSession.followArmed] 分开记的原因：`followArmed` 是一次性
  /// 的闩锁，13 处手动操作都会把它清掉，而恢复只有「暂停再播放」「点原进度」
  /// 两条路 —— 用户只是想把页面往前拖一点看看内容，跟随就**永久失效**了，
  /// 界面上也没有任何提示（`followArmed` 在 UI 上完全不可见）。
  ///
  /// 有了这个标记就能区分两种「不跟随」：
  /// - 用户接管过 → 闩锁到期后可以自动恢复（把页面拉回朗读处再继续跟）；
  /// - 从没接管过 → 跟随本来就没开，不该自作主张地打开。
  bool _listenFollowTakeover = false;

  /// 跨章**由跟随触发**中：跟随把页面带到下一章时置位。
  ///
  /// 拼接模式（滚动连章）里，跨章会回调 `_onJoinedPosition`，那里要判断
  /// 「这次跨章是用户滚过去的，还是跟随带过去的」—— 后者不能退出跟随，
  /// 否则跟随自己把自己关掉。
  bool _followChapterJump = false;

  /// 上次提示「正在播放的章节不在本书目录里」的时刻，用于限频。
  DateTime _followChapterMissingAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 朗读句高亮：与跟随翻页独立同步，跟随关闭时高亮仍可显示；切章、关闭
  /// 或未在读本章时清空。暂停保留（官方暂停时朗读标记仍在正文上）。
  ///
  /// 这是**显示态**：受「朗读句高亮」偏好控制，偏好关掉就为 null。
  /// 跟随翻页要用的位置在 [_followAnchor]，两者不能混用一个字段 ——
  /// 混用会让「关掉高亮」连带「关掉跟随」。
  (int, int)? _narrationRange;

  /// 跟随翻页的**导航锚点**：正在朗读的那一句在正文里的字符区间。
  ///
  /// 与 [_narrationRange] 的区别只有一个：不受「朗读句高亮」偏好影响。
  /// 整章没有字幕表时（系统朗读、字幕取不到），跟随只能靠这个锚点寻址；
  /// 之前它和显示态共用一个字段，用户一关高亮，跟随就彻底失去锚点，
  /// 表现为「听书跟随翻页无效」而且没有任何提示。
  ///
  /// 只由 [_narrationLayoutRange] 的结果写入，不做「保留上一拍」的延留：
  /// 导航锚点要的是**当前**正在读的位置，延留会把页面停在上一句。
  (int, int)? _followAnchor;

  /// 双击跳读是否可用：正在听这本书就行，本章或别的章都可以（跨章跳）。
  ///
  /// 单独存一份是因为它得跟着会话变，而高亮没变化时不会触发重建。
  bool _doubleTapArmed = false;

  /// 上一拍这本书是否在播。用来识别「暂停后继续播放」：官方
  /// `AudioSyncReaderController.java:381` `onPlayResume` 会立刻恢复跟随，
  /// 不受手动翻页那 15 秒闩锁影响。
  bool _listenWasPlaying = false;

  /// 「正文字符位置 ↔ 音频时间」对照表，句高亮 / 跟随翻页 / 双击跳读共用。
  ///
  /// 排版（换字号、换分页方式）或字幕轨换了才重建；两者都用 identical 判断，
  /// 日常 tick 不会重建。
  CueIndex _cueIndex = CueIndex.empty;
  Object? _cueIndexLayout;
  SubtitleTrack? _cueIndexTrack;

  /// 非当前播放章的字幕轨，键 = 章节 id。
  ///
  /// 会话里只存在正在播那一章的轨。停在别的章时双击跳读要先有本章字幕，
  /// 所以按章补取一次留着，翻回来不用再请求。
  final _cueTracks = <String, SubtitleTrack>{};

  /// 正在补取的字幕请求，键 = 章节 id。双击连点时不重复发请求。
  final _cueTrackRequests = <String, Future<SubtitleTrack>>{};

  int _loadGeneration = 0;
  // Legado-style reading time: deltas are settled at scroll stops, chapter
  // switches and dispose, so no background timer is needed.
  DateTime _readStart = DateTime.now();
  bool _sessionActive = false;
  bool _appActive = true;
  bool _routeCurrent = false;
  bool _changingChapter = false;

  /// 墨水屏整屏刷新计数器：每翻一页 +1，达到 [_ReaderState._einkRefreshInterval]
  /// 阈值（来自 [_preferences.einkRefreshInterval]）就调用一次海信 EPD 全刷压残影，
  /// 然后归零。仅在全局墨水屏模式开启时累加。
  int _einkPageCounter = 0;

  /// 墨水屏软件白闪显隐：[EinkRefreshService] 在厂商接口不可用时发请求，
  /// 这里盖一张全屏白帧再撤掉，迫使 EPD 控制器做一次全量刷新。
  bool _einkFlashVisible = false;
  Timer? _einkFlashTimer;

  /// 滚动模式下的墨水屏刷新累积：滚动没有“翻页”计数，改按滚动距离累积，
  /// 每滚够约 3 屏刷一次，避免滚动模式残影只增不减。
  double _einkScrollDistance = 0;
  double _einkLastScrollOffset = 0;

  /// 上一次已触发过切章刷新的章节 id：首章打开不闪，只有切章才刷。
  String? _lastEinkRefreshChapterId;

  /// Chapter-boundary transition handed to [ReaderPagedView]; see
  /// [ReaderChapterTurn]. Set by [_next] / [_prev] and cleared once the slide
  /// finishes, or when the chapter fails to load.
  // Note: .agents/notes/implemented/bug-fix/2026-10-15-reader-chapter-turn-animation.md
  ReaderChapterTurn? _chapterTurnRequest;

  /// Set while 从本段听 is waiting on a timeline fetch, so a repeated long-press
  /// cannot stack a second listening page (and a second player) on top.
  bool _openingListening = false;
  final LinkedHashMap<String, String> _chapterCache = LinkedHashMap();
  final Map<String, Future<_LoadedChapter>> _chapterRequests = {};
  final Map<String, int> _chapterCacheRevisions = {};
  final Map<String, Future<void>> _chapterRefreshes = {};
  Future<void>? _catalogFuture;
  late final ReaderHistory _history = ReaderHistory(_readerStore);
  late final ReaderDevice _device = widget.readerDevice ?? ReaderDevice();
  late final Future<void> _preferencesFuture;
  StreamSubscription<ReaderDeviceStatus>? _deviceSubscription;
  ReaderDeviceStatus _deviceStatus = ReaderDeviceStatus(time: DateTime.now());
  bool _deviceAvailable = false;
  bool _preferencesReady = false;
  bool _preferencesDirty = false;
  /// 是否已经下发过方向锁定（`SystemChrome.setPreferredOrientations`）。
  /// 引擎级设置不会随路由释放，离开阅读器时需要显式还原。
  bool _orientationLocked = false;

  /// 上一次下发方向锁定时对应的「允许横屏」取值，用来判断是否需要重发。
  bool _orientationAllowLandscape = false;

  /// 本页在导航栈里的路由对象（登记进 [ReaderRouteRegistry] 时用）。
  Route<dynamic>? _readerRoute;

  /// 是否已经登记进 [ReaderRouteRegistry]。登记只做一次：路由对象不会变。
  bool _readerRouteRegistered = false;
  int _deviceGeneration = 0;
  int _brightnessGeneration = 0;
  int _fontGeneration = 0;
  String? _fontFamily;
  final _viewportKey = GlobalKey();
  final _bottomControlsKey = GlobalKey();
  final _pagedKey = GlobalKey<ReaderPagedViewState>();
  ReaderChapterLayout? _chapterLayout;
  int _layoutDisplayRevision = -1;
  ReaderPageMode? _layoutMode;
  int _layoutRevision = 0;

  /// Bumped whenever [_ideas] changes. Cached layouts remember the revision they
  /// were measured with, so a chapter is re-measured once its paragraph bubbles
  /// arrive even though the text, font and viewport are unchanged.
  int _ideasRevision = 0;
  int _layoutIdeasRevision = -1;

  /// Whether the cached layout was measured with bubbles visible. Toggling
  /// the 段评气泡 switch must re-measure: the bubble placeholders change
  /// the text layout, so the cached layout is not reusable across a toggle.
  bool _layoutBubblesVisible = true;

  /// Paragraph ids of this chapter carrying a locally saved 划线.
  Set<int> _underlines = const {};

  /// Locally saved character-range 划线 of this chapter (the selection-model
  /// records; paragraph ones live in [_underlines]).
  List<ReaderRangeUnderline> _rangeUnderlines = const [];

  /// The live text selection — a whole paragraph right after a long press,
  /// then reshaped character-by-character by dragging a handle. Cleared on an
  /// outside tap, a scroll or a page turn, like the official selection.
  // Note: 选区模型（坐标空间、几何注册表、非模态操作条）—
  // 见 .agents/notes/implemented/feature/2026-09-19-reader-selection-model.md
  ReaderTextSelection? _selection;

  /// Palette plus hit-test registry, rebuilt per layout so stale blocks can
  /// never answer a drag from the previous chapter.
  ReaderSelectionScope? _marksScope;
  ReaderChapterLayout? _marksScopeLayout;
  final _selectionOverlayKey = GlobalKey();

  /// True while the action bar is up in the page overlay. It is non-modal —
  /// the official PopupWindow is too — so the drag handles stay touchable
  /// while it shows, and a tap outside it cancels the selection.
  bool _selectionBarOpen = false;

  /// The anchor (window coordinates) the bar was opened with: the long-press
  /// point or the handle position at drag end, with y re-based onto the
  /// selection's bottom so the bar can never cover the selected lines.
  Offset _selectionBarAnchor = Offset.zero;

  /// The selection's top edge (window coordinates) — the flip reference when
  /// the bar has to move above the selection instead of below it.
  Offset? _selectionBarTopAnchor;

  /// True while a long-press drag is reshaping the selection without the
  /// finger ever having grabbed a handle (官方不抬手拖动).
  bool _longPressDragging = false;

  int _underlineRevision = 0;
  int _layoutUnderlineRevision = -1;
  int _textOffset = 0;
  int _pageIndex = 0;
  Map<String, dynamic>? _savedPosition;
  bool _needsRestore = true;
  bool _requestedStartAtEnd = false;

  ReaderBookmarkStore get _bookmarkStore =>
      widget.bookmarkStore ?? ReaderBookmarkStore.instance;

  ReaderStore get _readerStore => widget.readerStore ?? LibraryStore.instance;

  // Note: Route/lifecycle ownership and SDK 36 compatibility; see
  // .agents/notes/implemented/bug-fix/2026-10-12-reader-system-bars.md.
  // The paragraph-ideas sheet is the reader's own modal (#57): opening it
  // pushes a route, which would otherwise flip [_routeCurrent] off and
  // bring the status bar back. While the sheet is open the viewer is still
  // reading, so immersive stays on; other routes still release it.
  bool _ideasSheetOpen = false;

  DateTime _desktopWheelAt = DateTime.fromMillisecondsSinceEpoch(0);
}
