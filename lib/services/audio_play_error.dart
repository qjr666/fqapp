import 'api_client.dart';
import 'native_player.dart';

/// 听书播放失败时，官方给出的那两句「有原因」的提示。
///
/// 反编译取证：
/// * `ug` = 「本章该音色已下架」
/// * `uj` = 「本章正在审核中，请先看其他章节」
///
/// 上游只保证 `NO_THIS_TONE` 这个码；「审核中」的具体码没有取证到，因此这里
/// 按消息里的关键字识别，识别不到就返回 null，由调用方回落到通用文案——
/// 宁可给通用提示，也不要把裸错误码甩给用户。
String? audioPlayErrorMessage(Object error, {bool switchedTone = false}) {
  final message = error is ApiException ? error.message : error.toString();
  if (message.contains('NO_THIS_TONE')) {
    return switchedTone ? '本章该音色已下架，已为你换用其它音色' : '本章该音色已下架';
  }
  const reviewMarkers = <String>['审核', 'UNDER_REVIEW', 'AUDITING', 'REVIEWING'];
  for (final marker in reviewMarkers) {
    if (message.contains(marker)) return '本章正在审核中，请先看其他章节';
  }
  // iOS 没有端上 CENC 解密能力：服务端缓存失败时不能再把加密直连地址
  // 塞给播放器，核心会返回这个业务码。给出可操作的提示，也便于真机
  // 反馈时一眼区分「服务端没解出来」和「播放器没加载出来」。
  if (message.contains('IOS_AUDIO_CACHE_FAILED')) {
    return '这个声音暂时无法在 iPhone 上播放，请换一个声音，或改用系统朗读';
  }
  // iOS 适配器的私有错误码此前被官方通用文案吞掉，屏幕上只剩
  // 「播放出错，请稍后重试」，无法判断是哪一步失败。
  if (error is NativePlaybackException) {
    if (error.errorCode == 4901) {
      return '这个声音需要解码，iPhone 上暂无法播放，请换一个声音或改用系统朗读';
    }
    if (error.errorCode == 4902) {
      return '音频加载失败，请重试；仍不行可换一个声音或改用系统朗读';
    }
  }
  return null;
}
