import 'package:flutter/foundation.dart';

import 'desktop_platform.dart';
import 'ios_platform.dart';

/// 视频播放是否可用。
///
/// 三个平台都实现同一份 `fqapp/native_player` 通道契约：
/// Android 走 ExoPlayer 原生插件，Windows 与 iOS 走进程内 media_kit 适配器
/// （见 `desktop_platform.dart` / `ios_platform.dart`）。`NativePlayer.create()`
/// 返回的 int 含义因平台而异，由 `video_surface.dart` 统一分派渲染。
bool get supportsVideoPlayback =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        isWindowsDesktop ||
        isIOSPlatform);
