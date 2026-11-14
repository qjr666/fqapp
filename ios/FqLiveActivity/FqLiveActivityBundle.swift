import ActivityKit
import SwiftUI
import WidgetKit

/// 锁屏 / 灵动岛上的最小入口：一个小图标加一行书名，不承载任何播放控制。
/// 播放控制全部由系统 Now Playing 卡片提供；这里只把点击绑定到只属于本
/// App 的 fqapp:// scheme，保证点一下就能回到 App。
struct FqListeningLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: FqListeningAttributes.self) { context in
      FqLockScreenView(context: context)
        .widgetURL(FqLiveActivityURL.open)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.center) {
          Link(destination: FqLiveActivityURL.open) {
            Text(context.state.title)
              .font(.caption2)
              .lineLimit(1)
          }
        }
      } compactLeading: {
        Link(destination: FqLiveActivityURL.open) {
          Image(systemName: "headphones")
            .font(.caption2)
        }
      } compactTrailing: {
        EmptyView()
      } minimal: {
        Link(destination: FqLiveActivityURL.open) {
          Image(systemName: "headphones")
            .font(.caption2)
        }
      }
    }
  }
}

private struct FqLockScreenView: View {
  let context: ActivityViewContext<FqListeningAttributes>

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "headphones")
        .font(.caption)
      VStack(alignment: .leading, spacing: 0) {
        Text(context.state.title)
          .font(.caption)
          .lineLimit(1)
        Text(context.state.episode)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
  }
}

@main
struct FqLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    FqListeningLiveActivity()
  }
}
