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
/// 视频走 media_kit（iOS 原生库由 `media_kit_libs_ios_video` 提供），播放源
/// 是 Rust 回环服务的 `/_session/<cap>/src/*`：服务端已按 Range 解密成明文，
/// 播放器发普通 GET 即可。朗读走 `flutter_tts`（AVSpeechSynthesizer），
/// 其 iOS pod 早已在 `ios/Podfile.lock` 里，无需新增原生代码。
class IosPlatform {
  IosPlatform._();
  static final instance = IosPlatform._();

  final _events = <String, StreamController<dynamic>>{};
  final _players = <int, _IosPlayer>{};
  final _tts = FlutterTts();
  String? _utterance;
  int _nextId = 1000000;
  bool _initialized = false;

  Stream<dynamic> events(String name) =>
      (_events[name] ??= StreamController<dynamic>.broadcast()).stream;

  void _emit(String name, dynamic event) => _events[name]?.add(event);

  Future<void> initialize() async {
    if (_initialized || !isIOSPlatform) return;
    // 先接管通道：即使 media_kit 的 iOS 原生库没装好，系统朗读仍能用。
    PlatformChannels.invoke = invoke;
    PlatformChannels.events = events;
    // 与 Windows 适配器保持同一套事件协议：只发 done / error。
    // SystemTtsPlayback 的定时泵会在 _begin 里自行调度，done 事件负责推进
    // 下一句高亮与自动下一章，因此不发 start 也能完整工作。
    _tts.setCompletionHandler(() {
      final id = _utterance;
      if (id != null) {
        _utterance = null;
        _emit('fqapp/system_tts_events', {'type': 'done', 'id': id});
      }
    });
    _tts.setErrorHandler((dynamic _) {
      final id = _utterance;
      _utterance = null;
      _emit('fqapp/system_tts_events', {'type': 'error', 'id': id});
    });
    try {
      MediaKit.ensureInitialized();
    } catch (_) {
      // 视频原生库不可用不该让整个启动装配失败：此时 native_player 的
      // create 会抛错并按 error 事件降级，阅读与朗读保持可用。
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
        await _tts.stop();
        _utterance = null;
        final engine = args['engine'];
        if (engine is String && engine.startsWith('{')) {
          final voice = (jsonDecode(engine) as Map).cast<String, String>();
          await _tts.setVoice(voice);
        } else {
          await _tts.setLanguage('zh-CN');
        }
        // AVSpeechUtterance.rate 的取值是 0..1，默认 0.5；Windows SAPI 那边
        // 是另一套偏移，所以这里不能照抄 desktop_platform.dart 的 rate - .5。
        // app 侧 1.0× 对应 iOS 0.5，2.0× 对应 1.0。
        final rate = (args['rate'] as num?)?.toDouble() ?? 1;
        await _tts.setSpeechRate((rate * .5).clamp(0.0, 1.0));
        return 300;
      case 'speak':
        _utterance = args['id'] as String;
        final result = await _tts.speak(args['text'] as String);
        if (result == 0) {
          _utterance = null;
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
        _utterance = null;
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
      player.stream.error.listen(
        (_) => event('error', {'message': '媒体播放失败，请重试或切换清晰度'}),
      ),
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

  Future<void> open(String url, String key, int startMs) async {
    ready.future.ignore();
    try {
      // Rust 的 /_session/<cap>/src/* 回环服务是按 Range 在服务端解密的，
      // 交给播放器的是明文流。响应里始终带 key_hex（见 video.rs:182），
      // 但这条路径**必须忽略它**，否则会去找一个 iOS 上不存在的解密后端。
      final serverDecrypted =
          url.contains('/_session/') && url.contains('/src/');
      if (key.isNotEmpty && !serverDecrypted) {
        // 上游直连加密源与 file:// 离线缓存都需要端上 CENC 解密。Rust 的
        // desktop_media / desktop_fetch 被 #[cfg(target_os = "windows")] 门住，
        // 且依赖只在 Windows 启用的 reqwest/blocking，iOS 静态库里没有
        // fq_desktop_media_open 符号。明确提示，不要静默播出一堆乱码。
        throw StateError('该加密片源在 iOS 上暂不支持，请切换清晰度或稍后重试');
      }
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
      if (!ready.isCompleted) ready.completeError(StateError('无法打开媒体'));
      if (!disposed) {
        emit({
          'playerId': id,
          'type': 'error',
          'value': {
            'message': error is StateError
                ? error.message
                : '媒体加载失败，请检查网络或重试',
            'errorCode': null,
            'httpStatusCode': null,
          },
        });
      }
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
