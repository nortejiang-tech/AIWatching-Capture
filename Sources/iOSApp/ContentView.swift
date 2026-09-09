import SwiftUI
import UniformTypeIdentifiers

private enum MainTab: String, CaseIterable, Hashable {
    case capture = "capture"
    case settings = "settings"

    var title: String {
        switch self {
        case .capture:
            "捕捉"
        case .settings:
            "设置"
        }
    }

    var icon: String {
        switch self {
        case .capture:
            "mic.circle.fill"
        case .settings:
            "gearshape"
        }
    }
}

struct ContentView: View {
    @State private var selectedTab: MainTab = .capture

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CaptureTabView()
            }
            .tag(MainTab.capture)
            .tabItem {
                Label(MainTab.capture.title, systemImage: MainTab.capture.icon)
            }

            NavigationStack {
                SettingsTabView()
            }
            .tag(MainTab.settings)
            .tabItem {
                Label(MainTab.settings.title, systemImage: MainTab.settings.icon)
            }
        }
    }
}

private struct CaptureTabView: View {
    @EnvironmentObject private var capture: CaptureController
    @AppStorage("showInAppRecordingIndicator") private var showInAppRecordingIndicator = true
    @ScaledMetric(relativeTo: .largeTitle) private var timerFontSize: CGFloat = 54
    @State private var confirmStopCapture = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                PrivacyChip(level: .localOnly)

                VStack(spacing: 12) {
                    Text("捕捉时长")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AIWatchingColor.muted)
                        .textCase(.uppercase)
                        .accessibilityHidden(true)

                    Text(capture.elapsedText)
                        .font(.system(size: min(timerFontSize, 72), weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(capture.isRecording ? AIWatchingColor.recording : AIWatchingColor.ink)
                        .accessibilityLabel("捕捉时长")
                        .accessibilityValue(capture.elapsedText)

                    HStack(spacing: 8) {
                        Image(systemName: capture.isRecording ? "dot.radiowaves.left.and.right" : "pause.circle")
                        Text(capture.isRecording ? "状态：正在捕捉" : "状态：准备就绪")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(capture.isRecording ? AIWatchingColor.recording : AIWatchingColor.ink)
                    .accessibilityElement(children: .combine)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AIWatchingColor.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(AIWatchingColor.muted.opacity(0.25), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 12)

                if showInAppRecordingIndicator, capture.isRecording {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle.fill")
                        Text("App 内录音提示已开启")
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AIWatchingColor.recording)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AIWatchingColor.card)
                    )
                    .padding(.horizontal, 12)
                }

                RecordButton(isRecording: capture.isRecording) {
                    if capture.isRecording {
                        confirmStopCapture = true
                    } else {
                        Task { await capture.startCapture() }
                    }
                }

                if capture.isRecording {
                    Button {
                        Task { await capture.addBookmark(note: nil, source: "iphone") }
                    } label: {
                        Label("打标", systemImage: "bookmark.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(AIWatchingColor.brand)
                    .controlSize(.regular)
                    .accessibilityLabel("时间戳打标")
                    .accessibilityHint("仅在录制中可用")
                }

                if let message = capture.message {
                    MessageBanner(
                        kind: captureMessageKind(message),
                        message: message
                    )
                }
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(AIWatchingColor.paper.ignoresSafeArea())
        .navigationTitle("AIWatching")
        .navigationBarTitleDisplayMode(.inline)
        .alert("结束本次捕捉？", isPresented: $confirmStopCapture) {
            Button("继续捕捉", role: .cancel) {
                confirmStopCapture = false
            }

            Button("结束捕捉", role: .destructive) {
                Task { await capture.stopCapture() }
            }
        }
        message: {
            Text("请确认是否结束本次捕捉。")
        }
    }

    private func captureMessageKind(_ message: String) -> MessageBannerKind {
        let lowercase = message.lowercased()

        if lowercase.contains("部分成功") {
            return .warning
        }
        if lowercase.contains("中断已恢复") && lowercase.contains("继续捕捉") {
            return .success
        }

        let failureTerms = ["失败", "错误", "中断", "暂停", "无法", "未能", "拒绝", "不可用", "error", "fail"]
        if failureTerms.contains(where: { lowercase.contains($0) }) {
            return .error
        }

        let successTerms = ["成功", "已开始", "已完成", "已打标", "已导出", "已删除"]
        if successTerms.contains(where: { lowercase.contains($0) }) {
            return .success
        }
        return .info
    }
}

private struct SettingsTabView: View {
    @AppStorage("showInAppRecordingIndicator") private var showInAppRecordingIndicator = true

    var body: some View {
        Form {
            Section("隐私与数据") {
                PrivacyChip(level: .localOnly)
                Text("录音保留在本机，并自动保存到你选择的 iCloud 目录，供后续工具处理。")
                    .foregroundStyle(AIWatchingColor.ink)
                    .font(.footnote)
                    .accessibilityLabel("录音保留在本机，并自动保存到你选择的 iCloud 目录，供后续工具处理。")
            }

            Section("录音") {
                Toggle("显示 App 内录音提示", isOn: $showInAppRecordingIndicator)
            }

            Section("保存目录") {
                NavigationLink {
                    ExportSettingsView()
                } label: {
                    Label("保存目录设置", systemImage: "folder.badge.gearshape")
                }
            }

            Section("诊断") {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("诊断工具", systemImage: "stethoscope")
                        .font(.body)
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ExportSettingsView: View {
    @EnvironmentObject private var sessionExport: SessionExportRuntime

    @State private var isSelectingDestination = false
    @State private var pickerError: String?

    var body: some View {
        Form {
            Section("保存目录") {
                HStack(alignment: .top) {
                    Text("当前目录")
                    Spacer()
                    Text(destinationSummary)
                        .foregroundStyle(AIWatchingColor.ink.opacity(0.75))
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Button("选择/重新选择目录") {
                        isSelectingDestination = true
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button("清除目录", role: .destructive) {
                        Task { await clearDestination() }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }

            Section("说明") {
                Text("录音保留在本机，并自动复制到你选择的 iCloud 目录（如「手表录音」），供后续工具处理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("保存状态") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("待保存会话：\(sessionExport.pendingSessionIDs.count)")
                    if let error = sessionExport.lastError {
                        Text("上次错误：\(error.localizedDescription)")
                            .foregroundStyle(AIWatchingColor.danger)
                            .font(.footnote)
                    } else {
                        Text("上次错误：无")
                            .foregroundStyle(.secondary)
                    }
                }

                if sessionExport.lastOutcomes.isEmpty {
                    Text("最近结果：无")
                        .foregroundStyle(.secondary)
                } else {
                    Text("最近结果：")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(0..<sessionExport.lastOutcomes.count, id: \.self) { index in
                        Text(formatOutcome(sessionExport.lastOutcomes[index]))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("手动重试保存") {
                    Task { await retryPending() }
                }
                .buttonStyle(.bordered)
            }

            if let error = pickerError {
                Section("选择目录错误") {
                    Text(error)
                        .foregroundStyle(AIWatchingColor.danger)
                }
            }
        }
        .navigationTitle("保存目录")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isSelectingDestination,
            allowedContentTypes: [UTType.folder],
            allowsMultipleSelection: false
        ) { result in
            pickerError = nil
            if case let .success(urls) = result, let selected = urls.first {
                Task {
                    let destination = SessionExportDestination(
                        rootURL: selected,
                        displayName: selected.lastPathComponent
                    )
                    await sessionExport.selectDestination(destination)
                    await sessionExport.retryPending()
                }
            } else if case let .failure(error) = result {
                if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                    pickerError = nil
                } else {
                    pickerError = error.localizedDescription
                }
            }
        }
    }

    private var destinationSummary: String {
        switch sessionExport.destinationState {
        case .missing:
            return "未选择"
        case .stale(let displayName):
            return "书签失效需重选（\(displayName)）"
        case .available(let destination):
            return "已选择（\(destination.displayName)）"
        }
    }

    private func clearDestination() async {
        await sessionExport.clearDestination()
    }

    private func retryPending() async {
        await sessionExport.retryPending()
    }

    private func formatOutcome(_ outcome: SessionExportOutcome) -> String {
        switch outcome {
        case .exported(let sessionId):
            return "保存完成：\(sessionId)"
        case .alreadyExported(let sessionId):
            return "已保存：\(sessionId)"
        case .deferred(let sessionId, let reason):
            return "等待目录：\(sessionId)（\(reasonText(reason))）"
        case .failed(let sessionId, let failure):
            return "失败：\(sessionId)（\(failureText(failure))）"
        }
    }

    private func reasonText(_ reason: SessionExportDestinationIssue) -> String {
        switch reason {
        case .destinationMissing:
            return "目录未找到"
        case .destinationStale:
            return "目录书签失效"
        }
    }

    private func failureText(_ failure: SessionExportFailure) -> String {
        switch failure {
        case .permissionDenied:
            return "无权限"
        case .copyInterrupted:
            return "复制中断"
        case .identityConflict:
            return "会话冲突"
        }
    }
}
