import ActivityKit
import SwiftUI
import WidgetKit

/// 灵动岛 / 锁屏上的听书卡片。
///
/// 与系统 Now Playing 卡片分开：后者只负责控制中心 / 锁屏的播放控制与
/// ⏮ / ⏭，点主体是否唤起本 App 由系统决定；这一张由 App 自己提供视图，
/// 每个可点区域都指向 fqapp:// 深链，点击结果由 App 自己掌控。
struct FqListeningLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: FqListeningAttributes.self) { context in
      FqLockScreenView(context: context)
        .widgetURL(FqLiveActivityURL.open)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Link(destination: FqLiveActivityURL.open) {
            Image(systemName: "headphones.circle.fill")
              .font(.title3)
          }
        }
        DynamicIslandExpandedRegion(.center) {
          Link(destination: FqLiveActivityURL.open) {
            VStack(spacing: 2) {
              Text(context.state.title)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
              Text(context.state.episode)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          Link(destination: FqLiveActivityURL.open) {
            Image(systemName: context.state.playing ? "waveform" : "pause.circle")
              .font(.title3)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          Link(destination: FqLiveActivityURL.open) {
            Text("正在听书 · 点此返回")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      } compactLeading: {
        Link(destination: FqLiveActivityURL.open) {
          Image(systemName: "headphones")
        }
      } compactTrailing: {
        Link(destination: FqLiveActivityURL.open) {
          Text(context.state.playing ? "▶" : "❚❚")
            .font(.caption2)
        }
      } minimal: {
        Link(destination: FqLiveActivityURL.open) {
          Image(systemName: "headphones")
        }
      }
    }
  }
}

private struct FqLockScreenView: View {
  let context: ActivityViewContext<FqListeningAttributes>

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "headphones.circle.fill")
        .font(.title2)
      VStack(alignment: .leading, spacing: 2) {
        Text(context.state.title)
          .font(.headline)
          .lineLimit(1)
        Text(context.state.episode)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Image(systemName: context.state.playing ? "waveform" : "pause.circle")
        .font(.title3)
        .foregroundStyle(.secondary)
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
