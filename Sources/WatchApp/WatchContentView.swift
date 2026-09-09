import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var chunkedController: WatchChunkedCaptureController
    private let router = WatchCaptureEntryRouter()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: chunkedController.isRecording ? "record.circle.fill" : "record.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(chunkedController.isRecording ? .red : .primary)

                Text(chunkedController.statusText)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if chunkedController.state == .idle {
                    Button {
                        Task {
                            await router.handle(.primaryButton, controller: chunkedController)
                        }
                    } label: {
                        Label("开始录音", systemImage: "record.circle")
                    }
                    .accessibilityIdentifier("watch-local-capture-start")
                } else {
                    Button(role: .destructive) {
                        chunkedController.stop()
                    } label: {
                        Label("停止录音", systemImage: "stop.circle")
                    }
                    .accessibilityIdentifier("watch-local-capture-stop")
                }

                if chunkedController.pendingTransferCount > 0 {
                    Button {
                        chunkedController.retryPendingTransfers()
                    } label: {
                        Label("补发 \(chunkedController.pendingTransferCount) 个分片", systemImage: "arrow.clockwise")
                    }
                }

                if let chunkedError = chunkedController.lastError {
                    Text(chunkedError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

            }
            .padding()
            .onOpenURL { url in
                Task {
                    await router.handle(.deepLink(url), controller: chunkedController)
                }
            }
        }
    }
}
