import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'audio_preferences.dart';
import 'platform_channel.dart';

bool get isIOSPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// iOS 的进程内平台通道适配器。
///
/// 沿用仓库 Windows 端已有的做法：注入 `PlatformChannels.invoke/events`，
/// 让 `native_player.dart` 与 `system_tts.dart` 的 Android 通道契约原封不动
/// 复用 —— 不需要写 Swift 插件，也不需要改这两个文件。
///
/// 视频走 media_kit（iOS 原生库由 `media_kit_libs_ios_video` 提供）。iOS 没有
/// 端上 CENC 解密能力，所以取流侧（`episode_source_cache.dart` 的
/// `videoContentMode`）在 iOS 上不带 `mode=stream`：Rust 先缓存整集，再由
/// 回环服务把 `/_session/<cap>/src/*` 按 Range 解密成明文交给播放器。
///
/// 朗读走 `flutter_tts`（AVSpeechSynthesizer）。iOS 必须显式激活音频会话并
/// 设为 playback，否则侧边静音键一开就完全无声；同时要按 FIFO 管理预排的
/// 两句 utterance，否则 done 事件的 id 会错位、朗读状态机卡死。
class IosPlatform {
  IosPlatform._();
  static final instance = IosPlatform._();

  /// iOS 的系统媒体元数据通道：锁屏、控制中心、灵动岛上的播放器卡片。
  ///
  /// 与通知权限通道一样走**真实** MethodChannel —— 不能走 [invoke] 本身
  /// （那会递归回自己），也不能靠 `PlatformChannels.callbacks`：那个方向是
  /// Dart 主动调原生，这里要接的是原生 → Dart 的回推。
  static const _nowPlayingChannel = MethodChannel('fqapp/ios_now_playing');

  final _events = <String, StreamController<dynamic>>{};
  final _players = <int, _IosPlayer>{};
  final _tts = FlutterTts();

  /// 最近一次下发给系统媒体元数据的内容：朗读进度每次变化都会调过来，
  /// 内容没变就别再走一次 IPC。
  Map<String, dynamic>? _nowPlayingPayload;

  /// `SystemTtsPlayback` 一次预排两句，而 AVSpeechSynthesizer 会把 utterance
  /// 入队。done / start / range 必须按先进先出还给正确的 id。
  ///
  /// AVSpeechSynthesizer 的回调**不带 utterance id**，只有 range 回调带上
  /// 了这一句的文本（flutter_tts 的 iOS 实现把 `utterance.speechString` 放在
  /// 第一个参数里）。所以这里同时记下每句的文本：range 事件按文本精确对回
  /// 它所属的句子，对不上才退回「队首」这种猜测。
  ///
  /// 只靠「队首」猜会踩一个坑：句切换的那一瞬间，引擎已经开始念下一句，
  /// 而上一句的「读完」回调还没到 Dart —— 队首这时仍指上一句，猜错就会让
  /// 系统朗读侧把 range 当成「不是当前正在读的那句」丢掉，从此每一个 range
  /// 都被丢弃，高亮与跟翻再也不推进。
  final _utteranceQueue = <String>[];
  final _utteranceTexts = <String, String>{};
  int _nextId = 1000000;
  bool _initialized = false;
  bool _mediaKitReady = false;

  Stream<dynamic> events(String name) =>
      (_events[name] ??= StreamController<dynamic>.broadcast()).stream;

  void _emit(String name, dynamic event) => _events[name]?.add(event);

  void _ttsEvent(String type, {int? rangeStart, String? text}) {
    if (type == 'cancelled') {
      // 引擎把队列清空了：AVSpeechSynthesizer 停止时，队列里剩下的 utterance
      // 既不读完也不取消，它们的回调永远不来。Dart 侧必须知道这件事，
      // 否则朗读状态机与高亮就此脱节。
      _utteranceQueue.clear();
      _utteranceTexts.clear();
      _emit('fqapp/system_tts_events', <String, dynamic>{'type': 'cancelled'});
      return;
    }
    if (_utteranceQueue.isEmpty) return;
    final id = type == 'done'
        ? _utteranceQueue.removeAt(0)
        : _idForEvent(text);
    if (id == null) return;
    if (type == 'done') _utteranceTexts.remove(id);
    _emit('fqapp/system_tts_events', <String, dynamic>{
      'type': type,
      'id': id,
      'start': ?rangeStart,
    });
  }

  /// range 事件按句子文本精确对回它的 id；对不上（正文替换改写过文本等）
  /// 才退回队首。
  String? _idForEvent(String? text) {
    if (text != null && text.isNotEmpty) {
      for (final id in _utteranceQueue) {
        if (_utteranceTexts[id] == text) return id;
      }
    }
    return _utteranceQueue.first;
  }

  Future<void> initialize() async {
    if (_initialized || !isIOSPlatform) return;
    // 先接管通道：即使 media_kit 的 iOS 原生库没装好，系统朗读仍能用。
    PlatformChannels.invoke = invoke;
    PlatformChannels.events = events;

    // 原生 → Dart 的回推：控制中心 / 灵动岛上的播放、暂停、切章按钮。
    _nowPlayingChannel.setMethodCallHandler(_handleNowPlayingCall);

    // iOS 默认音频会话是 ambient，静音键会直接把朗读静音。必须激活共享
    // 会话、设为 playback，并阻止每句念完自动 deactivate（第二句就哑了）。
    //
    // 混播策略在这里一并落地：默认独占（playback 不带 mixWithOthers，会打断
    // 别的 App）；用户打开「允许同时播放」后换成 mixWithOthers。
    try {
      // 先激活再定类别：激活时用的还是默认的 ambient 类别，不会一开应用就
      // 打断别的 App；类别改完之后，下一次播放激活（AVPlayer / AVSpeech
      // 自己会激活）才按新类别生效。
      await _tts.setSharedInstance(true);
      await _applyAudioCategory();
      await _tts.autoStopSharedSession(false);
    } catch (error) {
      debugPrint('[ios-tts] audio session setup failed: $error');
    }

    _tts.setStartHandler(() => _ttsEvent('start'));
    _tts.setCompletionHandler(() => _ttsEvent('done'));
    // willSpeakRangeOfSpeechString：恢复精确到字的高亮（可选增强，缺了
    // SystemTtsPlayback 会退化为整句高亮）。第一个参数是这一句的**文本**
    // —— AVSpeechSynthesizer 不回传 utterance id，靠它把 range 精确对回
    // 正确的句子。
    _tts.setProgressHandler((String text, int start, int _, String _) {
      _ttsEvent('range', rangeStart: start, text: text);
    });
    // 引擎队列被清空（停止朗读）：剩下的句子永远不会再有回调，通知 Dart
    // 侧把状态机重建一遍。
    _tts.setCancelHandler(() => _ttsEvent('cancelled'));
    _tts.setErrorHandler((dynamic _) {
      if (_utteranceQueue.isEmpty) return;
      final id = _utteranceQueue.removeAt(0);
      _utteranceTexts.remove(id);
      _emit('fqapp/system_tts_events', {'type': 'error', 'id': id});
    });

    try {
      MediaKit.ensureInitialized();
      _mediaKitReady = true;
    } catch (error) {
      // 不再静默吞掉：真机上原生库缺失时 create 会给出可诊断的错误码。
      _mediaKitReady = false;
      debugPrint('[ios-player] MediaKit init failed: $error');
    }
    _initialized = true;
  }

  /// 应用当前的混播策略到 iOS 音频会话。
  ///
  /// 独占（默认）：`playback` 不带 `mixWithOthers` —— 起播会打断别的 App。
  /// 混播：加 `mixWithOthers`，别的 App 照常出声，我们叠在上面。
  ///
  /// 之前这里恒开 `duckOthers`，而 `duckOthers` 隐含 `mixWithOthers`，
  /// 于是听书永远和其它 App 混播，用户抱怨「后台播放会跟别的音频一起响」。
  ///
  /// [reactivate] 为 true 时改完类别再激活一次：AVAudioSession 在激活状态下
  /// 改类别，**新选项要重新激活才生效**。不这么做的话，用户在播放中切换
  /// 开关要等到下一次起播才看得出变化。
  Future<void> _applyAudioCategory({
    bool? mixWithOthers,
    bool reactivate = false,
  }) async {
    final mix =
        mixWithOthers ?? AudioPreferences.instance.mixWithOthers.value;
    final options = <IosTextToSpeechAudioCategoryOptions>[
      IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
      if (mix) IosTextToSpeechAudioCategoryOptions.mixWithOthers,
    ];
    try {
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        options,
      );
      if (reactivate) {
        // flutter_tts 的 setSharedInstance(true) 就是 setActive(true)。
        await _tts.setSharedInstance(true);
      }
    } catch (error) {
      debugPrint('[ios-tts] 设置音频会话类别失败：$error');
    }
  }

  /// `NativePlayer.create()` 返回的是 `created` 事件里的 value，Windows 端
  /// 把它当作 playerId 用（而不是真正的 Flutter texture id）。iOS 沿用同一
  /// 约定，渲染时按 id 找回对应的 VideoController。
  Widget videoSurface(int id, {Key? key}) {
    final host = _players[id];
    return host == null
        ? const SizedBox.expand()
        : Video(
            key: key,
            controller: host.video,
            controls: NoVideoControls,
            fit: BoxFit.fill,
            pauseUponEnteringBackgroundMode: false,
            resumeUponEnteringForegroundMode: false,
          );
  }

  Future<dynamic> invoke(
    String channel,
    String method,
    dynamic arguments,
  ) async {
    final args = arguments is Map ? arguments : const <dynamic, dynamic>{};
    switch (channel) {
      case 'fqapp/native_player':
        return _player(method, args);
      case 'fqapp/system_tts':
        return _speech(method, args);
      case 'fqapp/audio_mix':
        // 混播策略：直接改 iOS 音频会话的类别选项。
        if (method == 'setPolicy') {
          await _applyAudioCategory(
            mixWithOthers: args['mixWithOthers'] == true,
            reactivate: args['reactivate'] == true,
          );
          return null;
        }
        throw MissingPluginException(method);
      // iOS 没有这些原生桥：返回安全默认值，别让页面抛异常。
      case 'fqapp/player_system_ui':
      case 'fqapp/volume-key':
      case 'fqapp/fair_memory':
        return null;
      case 'fqapp/eink-refresh':
        return false;
    }
    // 其余自定义通道（分享、书签导入等）照旧走真实 MethodChannel，
    // 保留仓库原有的 MissingPluginException 降级行为。
    return MethodChannel(channel).invokeMethod<dynamic>(method, arguments);
  }

  /// 转发到 Swift 的通知权限通道（`fqapp/ios_notification`）。
  ///
  /// 走真实的 MethodChannel —— 不能走 [invoke] 本身，那会递归回自己。
  Future<dynamic> _notificationPermission(String method) async {
    try {
      return await const MethodChannel(
        'fqapp/ios_notification',
      ).invokeMethod<dynamic>(method);
    } catch (error) {
      debugPrint('[ios-notification] $method failed: $error');
      return method == 'openSettings' ? false : 'unknown';
    }
  }

  /// 把系统媒体控制中心的动作转成 `native_player` 的远控契约。
  ///
  /// 动作名与 Android 的媒体通知保持一致（`playPause` / `prev` / `next` /
  /// `stop`）；iOS 额外的 `play` / `pause` 是分开的两枚按钮，语义不是切换，
  /// 消费方按「恢复播放 / 暂停播放」处理。
  Future<dynamic> _handleNowPlayingCall(MethodCall call) async {
    if (call.method != 'onRemoteAction') return null;
    final raw = call.arguments;
    final action = raw is Map
        ? raw['action'] as String?
        : raw is String
        ? raw
        : null;
    if (action == null || action.isEmpty) return null;
    await PlatformChannels.notify(
      'fqapp/native_player',
      'onNotificationAction',
      {'action': action},
    );
    return null;
  }

  /// 把当前在读/在听的内容发布成系统媒体元数据。
  ///
  /// 参数与 Android 的 `startListenForeground` 完全一致，iOS 这边只透传，
  /// 由 Swift 侧的 `MPNowPlayingInfoCenter` 消费。
  Future<void> _updateNowPlaying(Map args) async {
    final payload = <String, dynamic>{
      'title': args['title'] as String? ?? '',
      'episode': args['episode'] as String? ?? '',
      'coverUrl': args['coverUrl'] as String? ?? '',
      'playing': args['playing'] == true,
      'hasPrev': args['hasPrev'] == true,
      'hasNext': args['hasNext'] == true,
      'positionMs': (args['positionMs'] as num?)?.toInt() ?? 0,
      'durationMs': (args['durationMs'] as num?)?.toInt() ?? 0,
      'speed': (args['speed'] as num?)?.toDouble() ?? 1,
    };
    final previous = _nowPlayingPayload;
    if (previous != null && _sameNowPlaying(previous, payload)) return;
    _nowPlayingPayload = payload;
    try {
      await _nowPlayingChannel.invokeMethod<void>('update', payload);
    } catch (error) {
      debugPrint('[ios-now-playing] update failed: $error');
    }
  }

  /// 停止播放后清掉系统媒体卡片：留着上一本书的卡片，系统会一直显示
  /// 「暂停」按钮，用户按下去什么也不会发生。
  Future<void> _clearNowPlaying() async {
    if (_nowPlayingPayload == null) return;
    _nowPlayingPayload = null;
    try {
      await _nowPlayingChannel.invokeMethod<void>('clear');
    } catch (error) {
      debugPrint('[ios-now-playing] clear failed: $error');
    }
  }

  /// Map 的 `==` 是引用相等，比内容要自己逐项比。
  static bool _sameNowPlaying(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<dynamic> _player(String method, Map args) async {
    switch (method) {
      case 'create':
        final id = _nextId++;
        final host = _IosPlayer(
          id,
          (event) => _emit('fqapp/native_player/events', event),
        );
        _players[id] = host;
        unawaited(
          host.open(
            args['cdnUrl'] as String,
            args['keyHex'] as String,
            (args['startPositionMs'] as num?)?.toInt() ?? 0,
            _mediaKitReady,
          ),
        );
        return {'playerId': id};
      case 'dispose':
        final id = (args['id'] as num?)?.toInt();
        final host = _players.remove(id);
        await host?.dispose();
        return null;
      // 通知（通知栏）权限：iOS 上对应 UNUserNotificationCenter。应用必须
      // **主动**调 requestAuthorization 才会弹系统授权框 —— 从前这里直接回
      // 'granted'，于是 iOS 版从来没有申请过通知权限，通知栏里也不会出现
      // 任何本应用的通知。真正的实现走 Swift 通道 `fqapp/ios_notification`。
      case 'notificationPermissionStatus':
        return _notificationPermission('status');
      case 'requestNotificationPermission':
        return _notificationPermission('request');
      case 'openNotificationSettings':
        return _notificationPermission('openSettings');
      // iOS 没有悬浮窗 / 常亮原生实现。这些调用都带 catch 或是可选
      // 增强，返回中性值即可，不伪装成「成功开启」。
      case 'setKeepScreenOn':
      case 'startFloating':
      case 'showFloating':
      case 'updateFloating':
      case 'stopFloating':
      case 'swapFloatingPlayer':
        return null;
      // 锁屏 / 控制中心 / 灵动岛上的播放器：iOS 用系统媒体元数据实现，
      // 之前这里直接返回 null，于是灵动岛和控制中心一个播放器都没有。
      case 'startListenForeground':
        return _updateNowPlaying(args);
      case 'stopListenForeground':
        return _clearNowPlaying();
      case 'canDrawOverlays':
      case 'requestOverlayPermission':
        return false;
      case 'allocateFloatingOwner':
        return 0;
      // 亮度/音量手势交给 PlaybackGestureLevels 的 MissingPluginException
      // 降级分支：明确「没有这个能力」，而不是给一个假的档位。
      case 'gestureLevels':
      case 'setScreenBrightness':
      case 'resetScreenBrightness':
      case 'setMediaVolume':
        throw MissingPluginException(method);
    }
    final id = (args['id'] as num?)?.toInt();
    final host = _players[id];
    if (host == null) {
      throw PlatformException(code: 'player_closed', message: '播放器已关闭');
    }
    await host.command(method, args);
    return null;
  }

  Future<dynamic> _speech(String method, Map args) async {
    switch (method) {
      case 'engines':
        final voices = await _tts.getVoices;
        return {
          'defaultEngine': 'ios',
          'engines': [
            {'package': 'ios', 'label': '系统默认语音'},
            if (voices is List)
              for (final voice in voices)
                if (voice is Map && voice['name'] is String)
                  {
                    'package': jsonEncode({
                      'name': voice['name'],
                      'locale': voice['locale'],
                    }),
                    'label': '${voice['name']} (${voice['locale']})',
                  },
          ],
        };
      case 'initialize':
        // 先清队列再 stop：stop 有可能触发 completion 回调，顺序反了会把
        // 上一句的 done 误发给新一句。
        _utteranceQueue.clear();
        _utteranceTexts.clear();
        await _tts.stop();
        final engine = args['engine'];
        if (engine is String && engine.startsWith('{')) {
          final voice = (jsonDecode(engine) as Map).cast<String, String>();
          await _tts.setVoice(voice);
        } else {
          final available = await _tts.isLanguageAvailable('zh-CN');
          if (available != true) {
            // 少数设备没预装中文语音；不抛错（入口会变成「不支持朗读」），
            // 只留日志，让系统用默认 voice 尽力读。
            debugPrint('[ios-tts] zh-CN voice unavailable: $available');
          }
          await _tts.setLanguage('zh-CN');
        }
        // AVSpeechUtterance.rate 的取值是 0..1，默认 0.5；Windows SAPI 那边
        // 是另一套偏移，所以这里不能照抄 desktop_platform.dart 的 rate - .5。
        // app 侧 1.0× 对应 iOS 0.5，2.0× 对应 1.0。
        final rate = (args['rate'] as num?)?.toDouble() ?? 1;
        await _tts.setSpeechRate((rate * .5).clamp(0.0, 1.0));
        return 300;
      case 'speak':
        // Android 的 QUEUE_FLUSH / QUEUE_ADD：flutter_tts 的 setQueueMode 是
        // Android only，iOS 用「首句先 stop，后续交给 AVSpeechSynthesizer
        // 自身入队」来模拟。忽略 queue 会让两句的 done 全部记到后一句上。
        if (args['queue'] != true) {
          _utteranceQueue.clear();
          await _tts.stop();
        }
        final id = args['id'] as String;
        _utteranceQueue.add(id);
        _utteranceTexts[id] = args['text'] as String;
        final result = await _tts.speak(args['text'] as String);
        if (result == 0) {
          _utteranceQueue.remove(id);
          throw PlatformException(
            code: 'tts_failed',
            message: 'iOS 语音不可用，请在系统设置里安装中文语音',
          );
        }
        return null;
      case 'stop':
      case 'pause':
      case 'shutdown':
        // iOS 没有 Android 那套音频焦点机制，pause 与 stop 等价：停引擎但
        // 不动 session，SystemTtsPlayback.resume() 会重新起播同一句。
        _utteranceQueue.clear();
        _utteranceTexts.clear();
        await _tts.stop();
        return null;
      case 'settings':
        // iOS 没有可跳转的系统 TTS 设置页；静默返回，别弹错误 toast。
        return null;
    }
    throw MissingPluginException(method);
  }
}

class _IosPlayer {
  _IosPlayer(this.id, this.emit) {
    video = VideoController(player);
    void event(String type, dynamic value) {
      if (!disposed) emit({'playerId': id, 'type': type, 'value': value});
    }

    subscriptions.addAll([
      player.stream.position.listen((v) => event('position', v.inMilliseconds)),
      player.stream.duration.listen((v) => event('duration', v.inMilliseconds)),
      player.stream.playing.listen((v) => event('playing', v)),
      player.stream.buffering.listen((v) => event('buffering', v)),
      player.stream.completed.listen((v) => event('completed', v)),
      player.stream.width.listen((_) => _size()),
      player.stream.height.listen((_) => _size()),
      player.stream.error.listen((_) => event('error', _errorPayload())),
    ]);
    unawaited(
      video.waitUntilFirstFrameRendered.then((_) => event('firstFrame', true)),
    );
  }

  final int id;
  final void Function(Map<String, dynamic>) emit;
  final player = Player();
  late final VideoController video;
  final subscriptions = <StreamSubscription<dynamic>>[];
  final ready = Completer<void>();
  bool disposed = false;

  /// 上一次 open 用的密钥与来源形态。播放失败时要靠它们区分「媒体坏了」
  /// 和「这是加密直连片源，iPhone 解不开」——两者的处置完全不同。
  String _sourceKey = '';
  bool _serverDecrypted = false;

  /// 播放器报错的载荷。
  ///
  /// 以前是「有密钥且不是服务端解密流就直接拒绝播放」，那等于提前判死：
  /// 上游给音频打的「加密」标记很多时候是失效的，文件其实是明文的，
  /// iPhone 完全能直接播。改成先播、播不了再报错，并且把原因说清楚。
  Map<String, dynamic> _errorPayload() {
    if (_sourceKey.isNotEmpty && !_serverDecrypted) {
      return {
        'message': '该加密片源需要端上解密，iPhone 上无法播放',
        'errorCode': 4901,
        'httpStatusCode': null,
      };
    }
    return {
      'message': '媒体播放失败，请重试或切换清晰度',
      'errorCode': 4902,
      'httpStatusCode': null,
    };
  }

  void _fail(int code, String message) {
    if (!ready.isCompleted) ready.completeError(StateError(message));
    if (!disposed) {
      emit({
        'playerId': id,
        'type': 'error',
        'value': {
          'message': message,
          // playback_issue.dart 用私有错误码映射成安全、可操作的文案，
          // 原始 message 永不上屏（可能含签名地址）。
          'errorCode': code,
          'httpStatusCode': null,
        },
      });
    }
  }

  Future<void> open(
    String url,
    String key,
    int startMs,
    bool mediaKitReady,
  ) async {
    ready.future.ignore();
    try {
      if (!mediaKitReady) {
        _fail(4902, 'iOS 播放组件未加载');
        return;
      }
      // 主路径：Rust 回环服务已按 Range 解密成明文（URL 同时带
      // /_session/ 与 /src/）。其它形态 —— 上游直连地址、file://
      // 离线缓存 —— media_kit 只能按原样交给系统解码器。
      //
      // 这里**不再**因为「带了密钥」就提前拒绝：上游给音频打的「加密」
      // 标记很多时候是失效的，文件其实是明文的，iPhone 直接播就能出声。
      // 提前拒绝等于把一条能播的路堵死；真解不开时，播放器会报错，
      // 那时再按「加密直连片源」报 4901。
      _sourceKey = key;
      _serverDecrypted =
          url.contains('/_session/') && url.contains('/src/');
      if (disposed) return;
      await player.open(Media(url), play: false);
      if (startMs > 0) {
        await player.seek(Duration(milliseconds: startMs));
      }
      if (disposed) return;
      ready.complete();
      // created 的 value 会被 native_player.dart 当成 textureId 返回，
      // 这里用 playerId 顶替，渲染侧再按它找回 VideoController。
      emit({'playerId': id, 'type': 'created', 'value': id});
      _size();
    } catch (error) {
      if (!disposed) _fail(4902, '媒体加载失败，请检查网络或重试');
    }
  }

  void _size() {
    if (!disposed) {
      emit({
        'playerId': id,
        'type': 'videoSize',
        'width': player.state.width ?? 0,
        'height': player.state.height ?? 0,
        'rotationCorrection': 0,
      });
    }
  }

  Future<void> command(String method, Map args) async {
    await ready.future;
    if (disposed) return;
    switch (method) {
      case 'play':
        await player.play();
        emit({'playerId': id, 'type': 'playWhenReady', 'value': true});
      case 'pause':
        await player.pause();
        emit({'playerId': id, 'type': 'playWhenReady', 'value': false});
      case 'seek':
        await player.seek(
          Duration(milliseconds: (args['positionMs'] as num).toInt()),
        );
      case 'setRate':
        await player.setRate((args['rate'] as num).toDouble());
      case 'setVolume':
        await player.setVolume(
          (args['volume'] as num).toDouble().clamp(0, 1) * 100,
        );
      default:
        throw MissingPluginException(method);
    }
  }

  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
  }
}
