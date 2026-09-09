import AVFoundation

enum WatchRecordingAudioSessionPolicy {
    @MainActor
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setAllowHapticsAndSystemSoundsDuringRecording(false)
        try session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try session.setActive(true)
    }

    @MainActor
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
