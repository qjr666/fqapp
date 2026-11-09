import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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

  final _events = <String, StreamController<dynamic>>{};
  final _players = <int, _IosPlayer>{};
  final _tts = FlutterTts();

  /// `SystemTtsPlayback` 一次预排两句，而 AVSpeechSynthesizer 会把 utterance
  /// 入队。done / start / range 必须按先进先出还给正确的 id。
  final _utteranceQueue = <String>[];
  int _nextId = 1000000;
  bool _initialized = false;
  bool _mediaKitReady = false;

  Stream<dynamic> events(String name) =>
      (_events[name] ??= StreamController<dynamic>.broadcast()).stream;

  void _emit(String name, dynamic event) => _events[name]?.add(event);

  void _ttsEvent(String type, {int? rangeStart}) {
    if (_utteranceQueue.isEmpty) return;
    final id = type == 'done'
        ? _utteranceQueue.removeAt(0)
        : _utteranceQueue.first;
    _emit('fqapp/system_tts_events', <String, dynamic>{
      'type': type,
      'id': id,
      'start': ?rangeStart,
    });
  }

  Future<void> initialize() async {
    if (_initialized || !isIOSPlatform) return;
    // 先接管通道：即使 media_kit 的 iOS 原生库没装好，系统朗读仍能用。
    PlatformChannels.invoke = invoke;
    PlatformChannels.events = events;

    // iOS 默认音频会话是 ambient，静音键会直接把朗读静音。必须激活共享
    // 会话、设为 playback，并阻止每句念完自动 deactivate（第二句就哑了）。
    try {
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        <IosTextToSpeechAudioCategoryOptions>[
          IosTextToSpeechAudioCategoryOptions.duckOthers,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        ],
      );
      await _tts.autoStopSharedSession(false);
    } catch (error) {
      debugPrint('[ios-tts] audio session setup failed: $error');
    }

    _tts.setStartHandler(() => _ttsEvent('start'));
    _tts.setCompletionHandler(() => _ttsEvent('done'));
    // willSpeakRangeOfSpeechString：恢复精确到字的高亮（可选增强，缺了
    // SystemTtsPlayback 会退化为整句高亮）。
    _tts.setProgressHandler((String _, int start, int _, String _) {
      _ttsEvent('range', rangeStart: start);
    });
    _tts.setErrorHandler((dynamic _) {
      if (_utteranceQueue.isEmpty) return;
      final id = _utteranceQueue.removeAt(0);
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
      // iOS 没有悬浮窗 / SMTC / 常亮原生实现。这些调用都带 catch 或是可选
      // 增强，返回中性值即可，不伪装成「成功开启」。
      case 'setKeepScreenOn':
      case 'startListenForeground':
      case 'stopListenForeground':
      case 'startFloating':
      case 'showFloating':
      case 'updateFloating':
      case 'stopFloating':
      case 'swapFloatingPlayer':
        return null;
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
