import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_mix_policy.dart';

/// 听书入口默认走哪条链路。
///
/// - [smart] 智能朗读：作品音频，服务端合成，音色取自 `tts_tones`；
/// - [system] 系统朗读：手机已装的 TTS 引擎，不联网。
///
/// 只决定「按下听书时开哪个播放器」，播放中在音色面板里选真人讲书 /
/// 智能朗读不受它影响。
enum ListenEngine { smart, system }

/// 听书页自己的外观（与全局主题无关）。
///
/// 听书页的底色来自封面取色，深浅两套是同一色相的两档；全局主题改了它
/// 也会跟着变，但用户往往只想在听书时切深浅（例如夜里听书、书城仍要
/// 浅色），所以这里给听书页单独一档。
enum AudioThemeMode {
  /// 跟随全局外观（默认）。
  system('跟随系统'),

  /// 强制浅色。
  light('浅色'),

  /// 强制深色。
  dark('深色');

  const AudioThemeMode(this.label);

  /// 设置项展示用文案。
  final String label;

  static AudioThemeMode fromName(String? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => AudioThemeMode.system,
  );
}


/// 听书相关配置与持久化偏好设置。
class AudioPreferences {
  AudioPreferences._();

  static final AudioPreferences instance = AudioPreferences._();

  static const _backgroundPlaybackKey = 'audio_background_playback_enabled';
  static const _rateEngineKey = 'audio_rate_engine';

  /// 听书页外观的持久化键。
  static const _themeModeKey = 'audio_theme_mode';

  /// 「允许与其他应用同时播放」的持久化键。
  static const _mixWithOthersKey = 'audio_mix_with_others';

  /// 听书入口的默认引擎（[ListenEngine]）。
  static const _listenEngineKey = 'audio_listen_engine';

  /// 倍速锁定：锁定后点倍速项不再弹面板（官方 `a4g`「已经锁定2x倍速」）。
  static const _rateLockedKey = 'audio_rate_locked';

  /// 睡眠定时选的是「听完本章」而不是分钟档（官方 `cip`）。
  static const _sleepAtChapterEndKey = 'audio_sleep_at_chapter_end';

  /// 跳过片头 / 片尾按书存，单位秒；没有记录就是 0（不跳）。
  static const _skipIntroPrefix = 'audio_skip_intro_';
  static const _skipOutroPrefix = 'audio_skip_outro_';

  /// 是否允许后台播放与前台保活（默认 true）。
  /// 开启：切到后台或锁屏时继续播放，由 Android 前台保活服务常驻通知栏与提供控制卡片；
  /// 关闭：切到后台或锁屏时自动暂停播放并移除前台通知。
  final ValueNotifier<bool> backgroundPlayback = ValueNotifier<bool>(true);

  /// 听书页外观（深色 / 浅色 / 跟随系统）。
  final ValueNotifier<AudioThemeMode> themeMode = ValueNotifier(
    AudioThemeMode.system,
  );

  /// 是否允许听书与其他应用的音频**同时**播放（默认 false = 独占）。
  ///
  /// 独占时听书会打断/暂停其它 App 的音频（iOS 走 playback 类别不带
  /// mixWithOthers；Android 走 AUDIOFOCUS_GAIN），这是听书类应用的常规
  /// 行为。打开后改成混播：别的 App 照常出声，我们的音频叠在上面。
  final ValueNotifier<bool> mixWithOthers = ValueNotifier<bool>(false);

  /// 听书入口的默认引擎，默认智能朗读。
  ///
  /// 不默认系统朗读：它依赖手机已装的 TTS 引擎，部分设备一个都没有，
  /// 拿它当默认会让「点听书没反应」变成常态。
  final ValueNotifier<ListenEngine> listenEngine = ValueNotifier<ListenEngine>(
    ListenEngine.smart,
  );

  /// 听书倍速的变速实现（issue #129 / #170）。
  ///
  /// 默认 [AudioRateEngine.builtIn]（Media3 内建 Sonic），也就是 1.0.121
  /// 及更早版本的行为。1.0.133 把默认改成 [AudioRateEngine.wsola]（移植的
  /// FFmpeg `atempo`）后，部分设备听书一直停在「缓冲中」没有任何声音
  /// （issue #170）；在真机验证 WSOLA 之前先退回内建实现，用户仍可在
  /// 设置 → 听书里手动选 WSOLA 获得更接近官方的听感。
  final ValueNotifier<AudioRateEngine> rateEngine = ValueNotifier(
    AudioRateEngine.builtIn,
  );

  /// 倍速是否已锁定。锁定期间点倍速项只提示、不弹面板。
  bool rateLocked = false;

  /// 睡眠定时是否停在「听完本章」。与分钟档互斥。
  bool sleepAtChapterEnd = false;

  final Map<String, int> _skipIntro = <String, int>{};
  final Map<String, int> _skipOutro = <String, int>{};
  final Set<String> _skipLoaded = <String>{};

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      backgroundPlayback.value = sp.getBool(_backgroundPlaybackKey) ?? true;
      rateEngine.value = AudioRateEngine.fromName(sp.getString(_rateEngineKey));
      rateLocked = sp.getBool(_rateLockedKey) ?? false;
      sleepAtChapterEnd = sp.getBool(_sleepAtChapterEndKey) ?? false;
      listenEngine.value = sp.getString(_listenEngineKey) == 'system'
          ? ListenEngine.system
          : ListenEngine.smart;
      themeMode.value = AudioThemeMode.fromName(sp.getString(_themeModeKey));
      mixWithOthers.value = sp.getBool(_mixWithOthersKey) ?? false;
    } catch (_) {
      // 异常时退回默认值（后台播放开、系统变速、未锁定、分钟档）
    }
    // 启动时把混播策略推给原生。iOS 的音频会话在偏好加载之前就已经建好，
    // 这里补一次下发，让它跟用户上次的选择一致（默认独占）。
    await AudioMixPolicy.apply(mixWithOthers.value);
  }

  /// 重置测试状态，让下一次 [load] 重新读取 SharedPreferences。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    backgroundPlayback.value = true;
    rateEngine.value = AudioRateEngine.builtIn;
    rateLocked = false;
    sleepAtChapterEnd = false;
    listenEngine.value = ListenEngine.smart;
    themeMode.value = AudioThemeMode.system;
    mixWithOthers.value = false;
    _skipIntro.clear();
    _skipOutro.clear();
    _skipLoaded.clear();
  }

  /// 把这本书的跳过片头/片尾读进内存（控制器需要在开章时同步读）。
  Future<void> ensureSkipPoints(String bookId) async {
    if (bookId.isEmpty || _skipLoaded.contains(bookId)) return;
    _skipLoaded.add(bookId);
    try {
      final sp = await SharedPreferences.getInstance();
      _skipIntro[bookId] = sp.getInt('$_skipIntroPrefix$bookId') ?? 0;
      _skipOutro[bookId] = sp.getInt('$_skipOutroPrefix$bookId') ?? 0;
    } catch (_) {
      _skipIntro[bookId] = 0;
      _skipOutro[bookId] = 0;
    }
  }

  int skipIntroSeconds(String bookId) => _skipIntro[bookId] ?? 0;

  int skipOutroSeconds(String bookId) => _skipOutro[bookId] ?? 0;

  Future<void> setSkipIntroSeconds(String bookId, int seconds) async {
    final value = seconds < 0 ? 0 : seconds;
    _skipIntro[bookId] = value;
    _skipLoaded.add(bookId);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('$_skipIntroPrefix$bookId', value);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  Future<void> setSkipOutroSeconds(String bookId, int seconds) async {
    final value = seconds < 0 ? 0 : seconds;
    _skipOutro[bookId] = value;
    _skipLoaded.add(bookId);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('$_skipOutroPrefix$bookId', value);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  Future<void> setRateLocked(bool value) async {
    rateLocked = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_rateLockedKey, value);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  Future<void> setSleepAtChapterEnd(bool value) async {
    sleepAtChapterEnd = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_sleepAtChapterEndKey, value);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  Future<void> setBackgroundPlayback(bool value) async {
    backgroundPlayback.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_backgroundPlaybackKey, value);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  /// 听书页外观。改完立刻落盘，下次进入听书页仍是同一档。
  Future<void> setThemeMode(AudioThemeMode mode) async {
    themeMode.value = mode;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_themeModeKey, mode.name);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  /// 「允许与其他应用同时播放」。改完立刻生效并落盘。
  ///
  /// 策略要推给原生（iOS 的音频会话类别 / Android 的音频焦点），所以这里
  /// 除了存盘还调 [AudioMixPolicy.apply]。
  ///
  /// [reactivate] 只在正在出声时传 true：iOS 改了会话类别要重新激活才生效，
  /// 暂停时重新激活会白白打断别的 App。
  Future<void> setMixWithOthers(bool value, {bool reactivate = false}) async {
    mixWithOthers.value = value;
    await AudioMixPolicy.apply(value, reactivate: reactivate);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_mixWithOthersKey, value);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  Future<void> setListenEngine(ListenEngine engine) async {
    listenEngine.value = engine;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_listenEngineKey, engine.name);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  /// 变速引擎在**新建播放器**时生效：Media3 的 audio sink 在 build 时就
  /// 定型了，和「视频解码器」一样需要重新进入听书页。
  Future<void> setRateEngine(AudioRateEngine value) async {
    rateEngine.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_rateEngineKey, value.name);
    } catch (_) {
      // 忽略持久化失败
    }
  }
}

/// 听书变速引擎的进程内缓存。
///
/// `NativePlayer.create` 在起播关键路径上，不能 `await` 读盘（理由见
/// `DecoderPreferenceCache`）。[AudioPreferences.rateEngine] 是同一个值
/// 的唯一来源，这里只是在没有初始化偏好时给 create 一个安全默认值。
class AudioRateEngineCache {
  AudioRateEngineCache._();

  static AudioRateEngine get current =>
      AudioPreferences.instance.rateEngine.value;
}

/// 听书倍速的变速实现。
///
/// `name`（platform / builtIn）就是跨端的协议名：Kotlin 侧 `AudioRateEngine`
/// 用 `wireName` 逐字解析（BUILT_IN 这个常量名不上线），改一处必须同步另一处。
enum AudioRateEngine {
  /// 移植自官方 FFmpeg `af_atempo` 的 WSOLA（可选，1.0.133 起默认开启过，
  /// 因 issue #170 的静音问题暂时退回内建实现）。
  ///
  /// 番茄 7.0.9.32 的听书倍速走的就是这条路：native 层
  /// `avfilter_get_by_name("atempo")`、参数 `tempo=%1.2f`。窗口
  /// `sample_rate/24`、Hann 窗重叠相加、FFT 互相关对齐，听感与官方一致。
  wsola('对齐官方'),

  /// 系统混音器变速（AudioTrack/APM）。不依赖我们的 native 库。
  platform('系统'),

  /// Media3 内建 Sonic 变速。默认项（1.0.121 及更早的行为）。
  builtIn('兼容');

  const AudioRateEngine(this.label);

  /// 设置项展示用文案。
  final String label;

  static AudioRateEngine fromName(String? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => AudioRateEngine.builtIn,
  );
}
