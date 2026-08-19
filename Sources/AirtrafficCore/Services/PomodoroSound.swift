import Foundation

/// The chime played when a pomodoro phase ends. Cases map to the macOS system
/// sounds in /System/Library/Sounds, so nothing has to be bundled with the app.
public enum PomodoroChime: String, CaseIterable, Codable, Sendable, Identifiable {
    case none
    case glass = "Glass"
    case ping = "Ping"
    case hero = "Hero"
    case submarine = "Submarine"
    case bottle = "Bottle"
    case purr = "Purr"
    case tink = "Tink"
    case funk = "Funk"
    case sosumi = "Sosumi"
    case blow = "Blow"
    case basso = "Basso"
    case frog = "Frog"
    case morse = "Morse"
    case pop = "Pop"

    public var id: String { rawValue }

    /// The name to hand `NSSound(named:)`; nil means "stay silent".
    public var systemSoundName: String? {
        self == .none ? nil : rawValue
    }

    public var displayName: String {
        self == .none ? "なし" : rawValue
    }
}

/// The pomodoro's sound preferences: one chime per phase end, nothing else.
/// Persisted as JSON in UserDefaults.
public struct PomodoroSoundSettings: Codable, Equatable, Sendable {
    public var workEndChime: PomodoroChime
    public var restEndChime: PomodoroChime

    public init(
        workEndChime: PomodoroChime = .glass,
        restEndChime: PomodoroChime = .hero
    ) {
        self.workEndChime = workEndChime
        self.restEndChime = restEndChime
    }

    public static let `default` = PomodoroSoundSettings()

    /// The chime that ends the given phase.
    public func chime(endingPhase phase: PomodoroTimer.Phase) -> PomodoroChime {
        switch phase {
        case .work: workEndChime
        case .rest: restEndChime
        }
    }
}
