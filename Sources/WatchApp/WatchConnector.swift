import Foundation
import WatchConnectivity

@MainActor
final class WatchConnector: NSObject, ObservableObject {
    enum Command: String, Sendable {
        case start
        case stop
        case bookmark
    }

    @Published private(set) var isCapturing = false
    @Published private(set) var startPending = false
    @Published private(set) var statusText = "等待 iPhone"
    private var capturedStateReducer = CaptureAppCaptureStateReducer()
    private let chunkedTransferObserverBuffer = WatchChunkedTransferObserverBuffer()

    init(completionObserver: WatchChunkedTransferCompletionObserver? = nil) {
        super.init()
        chunkedTransferObserverBuffer.register(completionObserver)
        guard WCSession.isSupported() else {
            statusText = "WatchConnectivity 不可用"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ command: Command) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            statusText = "iPhone 不可达，未开始"
            if command == .start { isCapturing = false }
            return
        }

        if command == .start && (isCapturing || startPending) {
            statusText = isCapturing ? "正在捕捉" : "发送中..."
            return
        }

        if command == .start {
            startPending = true
        }

        statusText = "发送中..."
        WCSession.default.sendMessage(["command": command.rawValue], replyHandler: { @Sendable [weak self] reply in
            let ok = reply["ok"] as? Bool ?? false
            let message = reply["message"] as? String
            Task { @MainActor [weak self] in
                guard let self else { return }
                if command == .start {
                    self.startPending = false
                }
                switch command {
                case .start:
                    self.isCapturing = ok
                    self.statusText = ok ? "正在捕捉" : (message ?? "未开始")
                case .stop:
                    self.isCapturing = false
                    self.statusText = "已请求停止"
                case .bookmark:
                    self.statusText = ok ? "已打标" : (message ?? "打标失败")
                }
            }
        }, errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if command == .start {
                    self.startPending = false
                    self.isCapturing = false
                }
                self.statusText = "iPhone 不可达，未开始"
            }
        })
    }

    @MainActor
    func sendStartIfCapturingUnavailable() {
        send(.start)
    }

    func registerChunkedTransferCompletionObserver(_ observer: WatchChunkedTransferCompletionObserver?) {
        chunkedTransferObserverBuffer.register(observer)
    }
}

extension WatchConnector: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let metadataDictionary = fileTransfer.file.metadata as? NSDictionary,
              let metadataDictionaryCasted = metadataDictionary as? [String: Any],
              let metadata = WatchRecordingProbeMetadata(dictionary: metadataDictionaryCasted) else {
            return
        }
        let wasSuccessful = (error == nil)
        Task { @MainActor [weak self, metadata] in
            self?.chunkedTransferObserverBuffer.receiveTransferCompletion(
                metadata: metadata,
                wasSuccessful: wasSuccessful
            )
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let ack = WatchChunkApplicationAck(dictionary: userInfo) else {
            return
        }
        Task { @MainActor [weak self, ack] in
            self?.chunkedTransferObserverBuffer.receiveApplicationAck(ack)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = CaptureAppCaptureStateSnapshot(applicationContext: applicationContext) else {
            return
        }
        Task { @MainActor [weak self] in
            self?.applyCaptureStateApplicationContext(snapshot)
        }
    }
}

private extension WatchConnector {
    func applyCaptureStateApplicationContext(_ context: CaptureAppCaptureStateSnapshot) {
        guard capturedStateReducer.apply(context) else {
            return
        }
        isCapturing = capturedStateReducer.isCapturing
        statusText = capturedStateReducer.statusText
    }

    #if DEBUG
    func debugHandleApplicationContext(_ context: [String: Any]) {
        guard let snapshot = CaptureAppCaptureStateSnapshot(applicationContext: context) else {
            return
        }
        applyCaptureStateApplicationContext(snapshot)
    }
    #endif
}
