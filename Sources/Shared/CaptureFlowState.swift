import Foundation

struct CaptureRecorderIdentityGate: Equatable {
    private(set) var activeRecorderIdentity: ObjectIdentifier?

    mutating func arm(_ recorder: AnyObject) {
        activeRecorderIdentity = ObjectIdentifier(recorder)
    }

    func accepts(_ recorder: AnyObject) -> Bool {
        activeRecorderIdentity == ObjectIdentifier(recorder)
    }

    mutating func clearIfCurrent(_ recorder: AnyObject) -> Bool {
        guard accepts(recorder) else { return false }
        activeRecorderIdentity = nil
        return true
    }

    mutating func clear() {
        activeRecorderIdentity = nil
    }
}

struct CaptureInterruptionFlow: Equatable {
    enum State: Equatable {
        case idle
        case recording
        case interrupted
    }

    enum Event: Equatable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case currentChunkFinished
    }

    enum Action: Equatable {
        case none
        case stopCurrentRecorder
        case startNextRecorder
        case completeSession
    }

    private(set) var state: State = .idle
    private var pendingShouldResume: Bool?
    private var currentChunkFinished = false
    private var decisionConsumed = false

    mutating func markRecording() {
        state = .recording
        pendingShouldResume = nil
        currentChunkFinished = false
        decisionConsumed = false
    }

    mutating func handle(_ event: Event) -> Action {
        switch event {
        case .interruptionBegan:
            guard state == .recording else { return .none }
            state = .interrupted
            pendingShouldResume = nil
            currentChunkFinished = false
            decisionConsumed = false
            return .stopCurrentRecorder

        case let .interruptionEnded(shouldResume):
            guard state == .interrupted else { return .none }
            pendingShouldResume = shouldResume
            return resolveIfPossible()

        case .currentChunkFinished:
            guard state == .interrupted else { return .none }
            currentChunkFinished = true
            return resolveIfPossible()
        }
    }

    private mutating func resolveIfPossible() -> Action {
        guard state == .interrupted,
              !decisionConsumed,
              currentChunkFinished,
              let shouldResume = pendingShouldResume
        else {
            return .none
        }

        decisionConsumed = true
        pendingShouldResume = nil
        currentChunkFinished = false
        if shouldResume {
            state = .recording
            return .startNextRecorder
        } else {
            state = .idle
            return .completeSession
        }
    }
}
