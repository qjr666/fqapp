import 'package:flutter/widgets.dart';

import 'desktop_platform.dart';
import 'ios_platform.dart';

/// 播放器画面的统一渲染入口。
///
/// `NativePlayer.create()` 在三个平台都返回一个 int，但含义不同：
/// - Android：ExoPlayer 真正的 Flutter texture id，用 [Texture] 渲染；
/// - Windows：media_kit 的 playerId，由 `DesktopPlatform.videoSurface` 找回
///   `VideoController`；
/// - iOS：同样是 media_kit 的 playerId，由 `IosPlatform.videoSurface` 找回
///   `VideoController`。
///
/// 之前渲染处写的是 `isWindowsDesktop ? DesktopPlatform... : Texture(...)`，
/// iOS 加进来会误走 Texture 分支并渲染一个不存在的纹理。抽成这个函数后，
/// 新增平台只需在这里加一个分支。
Widget platformVideoSurface(int id, {Key? key}) {
  if (isWindowsDesktop) {
    return DesktopPlatform.instance.videoSurface(id, key: key);
  }
  if (isIOSPlatform) {
    return IosPlatform.instance.videoSurface(id, key: key);
  }
  return Texture(key: key, textureId: id);
}
