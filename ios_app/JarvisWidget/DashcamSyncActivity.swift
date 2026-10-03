import ActivityKit
import SwiftUI
import WidgetKit

/// The dashcam syncing, outside the app: what is coming off the camera and what is going to the cloud.
struct DashcamSyncActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DashcamSyncAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.cameraName, systemImage: "car.rear")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Syncing").font(.system(size: 13, weight: .medium)).foregroundStyle(JcAccent.color)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    bars(context.state).padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: icon(context.state)).foregroundStyle(JcAccent.color)
            } compactTrailing: {
                Text(percent(context.state)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(JcAccent.color)
            } minimal: {
                Image(systemName: icon(context.state)).foregroundStyle(JcAccent.color)
            }
            .keylineTint(JcAccent.color)
        }
    }

    private func lockScreen(_ context: ActivityViewContext<DashcamSyncAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(context.attributes.cameraName, systemImage: "car.rear")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Text("Dashcam sync").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            bars(context.state)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder private func bars(_ s: DashcamSyncAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !s.downloadName.isEmpty {
                bar(icon: "arrow.down.circle.fill", title: "Downloading \(s.downloadName)",
                    trailing: s.toDownload > 1 ? "\(s.toDownload - 1) more" : "", fraction: s.downloadFraction)
            }
            if s.uploading {
                bar(icon: "icloud.and.arrow.up.fill", title: "Uploading to the cloud",
                    trailing: s.toUpload > 1 ? "\(s.toUpload - 1) waiting" : "", fraction: s.uploadFraction)
            }
        }
    }

    private func bar(icon: String, title: String, trailing: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(JcAccent.color)
                Text(title).lineLimit(1).truncationMode(.middle).foregroundStyle(.white)
                Spacer(minLength: 4)
                Text(trailing.isEmpty ? "\(Int(fraction * 100))%" : "\(Int(fraction * 100))% · \(trailing)")
                    .monospacedDigit().foregroundStyle(.white.opacity(0.7))
            }
            .font(.system(size: 12.5, weight: .medium))
            ProgressView(value: min(1, max(0, fraction))).tint(JcAccent.color)
        }
    }

    private func icon(_ s: DashcamSyncAttributes.ContentState) -> String {
        !s.downloadName.isEmpty && s.uploading ? "arrow.up.arrow.down.circle.fill"
            : s.uploading ? "icloud.and.arrow.up.fill" : "arrow.down.circle.fill"
    }

    private func percent(_ s: DashcamSyncAttributes.ContentState) -> String {
        "\(Int((s.downloadName.isEmpty ? s.uploadFraction : s.downloadFraction) * 100))%"
    }
}
