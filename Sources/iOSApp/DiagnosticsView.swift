import SwiftUI

/// Read-only diagnostics: where files land, whether iCloud is active, the current
/// session folder, the last write error, and Watch connectivity. Handoff item #4.
struct DiagnosticsView: View {
    @EnvironmentObject private var capture: CaptureController

    @State private var storageMode = "—"
    @State private var rootPath = "—"
    @State private var currentSession = "无"
    @State private var reachable = false
    @State private var paired = false

    var body: some View {
        List {
            Section("存储") {
                row("存储模式", storageMode)
                row("AIWatching 根路径", rootPath, mono: true)
                row("当前会话", currentSession)
            }
            Section("Watch") {
                row("已配对", paired ? "是" : "否")
                row("可达", reachable ? "是" : "否")
            }
            Section("最近写入错误") {
                Text(capture.lastWriteError ?? "无")
                    .font(.footnote)
                    .foregroundStyle(capture.lastWriteError == nil ? Color.secondary : Color.red)
            }
        }
        .navigationTitle("诊断")
        .onAppear(perform: refresh)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新", action: refresh)
            }
        }
    }

    private func refresh() {
        storageMode = capture.storageMode
        rootPath = capture.iCloudRootPath
        currentSession = capture.currentSessionFolder ?? "无"
        reachable = PhoneConnectivityController.shared.isWatchReachable
        paired = PhoneConnectivityController.shared.isWatchPaired
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .font(mono ? .footnote.monospaced() : .footnote)
                .textSelection(.enabled)
        }
    }
}
