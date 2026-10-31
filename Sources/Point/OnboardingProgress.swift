import Foundation

/// Stored navigation is not evidence of permission. Every process verifies access again.
final class OnboardingProgress {
    enum Step: String {
        case welcome, screenAccess, ready, complete
    }

    private let defaults: UserDefaults
    private let key = "onboardingStepV1"

    private(set) var step: Step {
        didSet { defaults.set(step.rawValue, forKey: key) }
    }

    var isComplete: Bool { step == .complete }

    init(defaults: UserDefaults = .standard, hasCaptureAccess: Bool) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: key).flatMap(Step.init(rawValue:)) {
            step = saved
        } else {
            // Existing installations with working permission don't need the first-run tour.
            step = hasCaptureAccess ? .complete : .welcome
        }
        if !hasCaptureAccess, step == .ready || step == .complete {
            step = .screenAccess
        }
        defaults.set(step.rawValue, forKey: key)
    }

    func advance(to step: Step) {
        self.step = step
    }
}
