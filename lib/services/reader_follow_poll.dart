import 'dart:async';

/// The reader's 10Hz listening-follow poll, started only while it is useful.
///
/// The timer used to be created in `initState` and kept waking the UI isolate
/// ten times a second for the page's whole lifetime — with no listening
/// session at all, or while the app was in the background. Callers re-run
/// [sync] on session and app-lifecycle changes; the timer exists only while
/// [needed] says there is work to do.
///
/// Polling instead of the session's 1Hz notifications is deliberate: those fire
/// at most once a second and only on structural changes, while following needs
/// the playback position ten times a second to address the spoken character.
class ReaderFollowPoll {
  ReaderFollowPoll(this.tick, this.needed);

  static const interval = Duration(milliseconds: 100);

  /// Follow ticks per periodic progress save (10Hz ⇒ 2s). While following, the
  /// page is jumped programmatically on every tick, so the scroll controller's
  /// 500ms save debounce never fires; the poll supplies its own cadence.
  static const saveEvery = 20;

  final void Function() tick;
  final bool Function() needed;

  Timer? _timer;
  int _ticks = 0;
  bool _disposed = false;

  /// Starts or stops the timer to match [needed]. Cheap enough to call on every
  /// structural change.
  void sync() {
    // 页面已经销毁就不再起定时器：dispose 之后若还有一次 sync（例如迟到的
    // 会话通知），定时器会被重新拉起来，而这一次的 dispose 已经过去了 ——
    // 10Hz 的空转定时器永远停不下来。
    if (_disposed) return;
    final wanted = needed();
    if (wanted == (_timer != null)) return;
    if (wanted) {
      _timer = Timer.periodic(interval, (_) => tick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Counts one tick that actually followed; true once every [saveEvery] ticks.
  bool saveDue() {
    if (++_ticks < saveEvery) return false;
    _ticks = 0;
    return true;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
