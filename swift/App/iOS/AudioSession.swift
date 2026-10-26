import AVFoundation

enum AudioSession {
    /// Playback category so audio continues with the screen locked or the app
    /// in the background (with the `audio` background mode in Info.plist).
    static func configure() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("tvview: audio session: %@", error.localizedDescription)
        }
    }
}
