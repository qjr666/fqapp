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
    final reason = _cacheFailureReason(message);
    return reason == null
        ? '这个声音暂时无法在 iPhone 上播放，请换一个声音，或改用系统朗读'
        : '这个声音暂时无法在 iPhone 上播放（$reason）';
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
  // 兜底：上游或解析层给出的具体原因要透出来。「播放出错，请稍后重试」
  // 让真机反馈完全无法定位是哪一步失败。
  return _errorDetail(error);
}

/// 核心把缓存失败的原因跟在业务码后面：`IOS_AUDIO_CACHE_FAILED: <原因>`。
/// 原因里可能带签名地址，显示前必须脱敏。
String? _cacheFailureReason(String message) {
  const marker = 'IOS_AUDIO_CACHE_FAILED:';
  final index = message.indexOf(marker);
  if (index < 0) return null;
  final raw = message.substring(index + marker.length).trim();
  if (raw.isEmpty) return null;
  final cleaned = raw.replaceAll(RegExp(r'https?://\S+'), '地址').trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length > 120 ? '${cleaned.substring(0, 120)}…' : cleaned;
}

/// 上游业务错误 / 解析失败的具体原因。没有原因的失败才回落通用文案。
String? _errorDetail(Object error) {
  final raw = error is FormatException
      ? error.message.toString()
      : (error is ApiException ? error.message : '');
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (text.startsWith('HTTP ')) return '音频服务返回异常（$text）';
  // 上游偶尔回一个零字节的 200，核心只能报「解析失败」。说清楚是上游
  // 没给内容，用户重试一次通常就好了。
  if (text.startsWith('parse upstream json: EOF')) {
    return '上游这次没有返回音频内容，请重试';
  }
  if (text.contains('未获取到音频地址')) {
    return '没有取到这一章的音频地址，可换一章或改用系统朗读';
  }
  if (text.length <= 40 && RegExp(r'^[\u4e00-\u9fa5：，。！？、（）0-9]+$').hasMatch(text)) {
    return text;
  }
  return null;
}
