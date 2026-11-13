import ActivityKit
import Foundation

/// 听书 Live Activity 的深链常量。
///
/// 系统 Now Playing 卡片（含灵动岛里的媒体区）主体点击由 SpringBoard 决定
/// 唤起哪个进程，App 没有回调入口；Live Activity 的 widgetURL / Link 则指向
/// 只属于本 App 的 URL scheme，点卡片必定把 fqapp 带回前台。
enum FqLiveActivityURL {
  static let open = URL(string: "fqapp://nowplaying/open")!
  static let prev = URL(string: "fqapp://nowplaying/prev")!
  static let next = URL(string: "fqapp://nowplaying/next")!
  static let playPause = URL(string: "fqapp://nowplaying/playPause")!
}

/// 同时编译进 Runner 与 FqLiveActivityExtension；ActivityKit 按类型名把两端的
/// attributes / contentState 对起来，所以这份文件必须是两个 target 共享的。
@available(iOS 16.1, *)
struct FqListeningAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var title: String
    var episode: String
    var playing: Bool
    var hasPrev: Bool
    var hasNext: Bool
    var positionMs: Double
    var durationMs: Double
  }

  var bookTitle: String
}
