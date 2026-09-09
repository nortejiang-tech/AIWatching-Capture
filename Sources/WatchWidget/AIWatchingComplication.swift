import SwiftUI
import WidgetKit

struct CaptureEntry: TimelineEntry {
    let date: Date
}

struct CaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaptureEntry {
        CaptureEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (CaptureEntry) -> Void) {
        completion(CaptureEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureEntry>) -> Void) {
        completion(Timeline(entries: [CaptureEntry(date: Date())], policy: .never))
    }
}

struct CaptureComplicationView: View {
    var entry: CaptureEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "record.circle")
                .font(.title3)
                .widgetAccentable()
        }
        .widgetURL(URL(string: "aiwatching://start"))
    }
}

struct AIWatchingComplication: Widget {
    let kind = "AIWatchingCaptureComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CaptureProvider()) { entry in
            CaptureComplicationView(entry: entry)
        }
        .configurationDisplayName("AIWatching")
        .description("在 Watch 本地录音。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct AIWatchingWidgetBundle: WidgetBundle {
    var body: some Widget {
        AIWatchingComplication()
    }
}
