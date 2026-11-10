import 'package:flutter/foundation.dart';

import 'platform_channel.dart';

/// 跨端的「是否允许与其他应用同时播放」策略。
///
/// 关闭（默认）= **独占**：听书会打断 / 暂停其它 App 的音频，这是听书类
/// 应用的常规行为（用户按了播放就是要听这个）。
/// 开启 = **混播**：与其它 App 的音频同时响，不抢音频焦点。
///
/// 修复前的现状（2026-11）两个平台都恒为混播：
///  * iOS：`flutter_tts` 把音频会话设成 `playback + duckOthers`，而
///    `duckOthers` 隐含 `mixWithOthers`；
///  * Android：ExoPlayer 建好后没有 `setAudioAttributes(attrs, handleAudioFocus)`，
///    Media3 因此完全不参与音频焦点管理，别的 App 照常出声。
///
/// 现在两边都按这个开关走：iOS 由 [IosPlatform] 改音频会话类别选项，
/// Android 由 `AudioMixPolicy`（Kotlin）控制 Media3 的 handleAudioFocus
/// 与系统 TTS 的音频焦点申请。
class AudioMixPolicy {
  AudioMixPolicy._();

  /// 与原生约定的通道名。Android 在 MainActivity 注册，iOS 由
  /// [IosPlatform] 在进程内拦截。
  static const _channel = AppMethodChannel('fqapp/audio_mix');

  /// 把策略推给原生。
  ///
  /// [reactivate] 表示「现在就重新激活音频会话」：iOS 的会话在激活状态下
  /// 改类别，新选项要重新激活一次才生效。只有在**正在出声**的时候才需要
  /// 这么做 —— 暂停时重新激活会白白打断别的 App。
  ///
  /// 平台不支持时静默忽略：混播策略只是体验偏好，不该让听书起不来。
  static Future<void> apply(
    bool allowMixWithOthers, {
    bool reactivate = false,
  }) async {
    try {
      await _channel.invokeMethod<void>('setPolicy', {
        'mixWithOthers': allowMixWithOthers,
        'reactivate': reactivate,
      });
    } catch (error) {
      debugPrint('[audio-mix] 应用混播策略失败：$error');
    }
  }
}
